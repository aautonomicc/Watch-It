import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../db/app_database.dart';
import '../models/media_list.dart';
import 'datamap_import.dart';
import 'embedded_client.dart';
import 'library_store.dart';
import 'my_watch_api.dart';
import 'user_metadata.dart';
import 'watch_state.dart';

/// Background sync of watch lists and viewpoints (resume points) between
/// My W@tch linked devices, riding the link's CRDT key-value store.
///
/// Each device periodically publishes a *sync document* — its lists
/// (matched across devices by title, the same rule the import merge
/// uses), each entry with the time it was added, removal tombstones, and
/// its watch states — plus the shrunk data map of every entry it holds,
/// so a synced entry is importable and playable on the receiving device
/// (the map expands over the network at import, exactly like a shared
/// `.datamap` file).
///
/// Merging is a last-writer-wins element set per `(list title, address)`:
/// the newest add beats an older remove and vice versa, so deletions
/// propagate without resurrections. Watch states merge newest-`updatedAt`
/// wins per address ([WatchStateStore.mergeAll] — an import never
/// regresses local progress). Tombstones come from a locally persisted
/// membership snapshot: whatever disappeared from the library since the
/// last cycle was removed here, and is stamped now.
///
/// User edits (Edit details) sync too: the doc carries a `meta` section
/// with every `userEdited` metadata row — title/year/description/episode
/// name inline, artwork as a *manifest only* (sha256 + size), because
/// the store's value cap would force downscaling. A device missing the
/// artwork bytes pulls the original file from the owning device over
/// x0x direct messages while that device is online, verifies the hash,
/// and stores it under the normal `user_` poster naming — full quality,
/// byte-identical. Rows merge last-writer-wins by their edit time (the
/// remote stamp is adopted on apply, so comparisons converge).
///
/// The service is quiet unless the device is linked; every cycle checks.
class MyWatchSync {
  MyWatchSync({MyWatchApi? api}) : _api = api ?? MyWatchApi();

  /// Replaceable for tests.
  static MyWatchSync instance = MyWatchSync();

  final MyWatchApi _api;
  Timer? _timer;
  bool _cycling = false;

  /// Bumped after a merge changed the library, so screens showing list
  /// content can refresh without a route pop.
  static final ValueNotifier<int> revision = ValueNotifier(0);

  /// Seconds between sync cycles. A change propagates in at most two
  /// intervals (publish on one device, merge on the other).
  static const periodSecs = 30;

  /// Caps keeping the published document under the store's 64 KiB value
  /// limit: entries beyond these are dropped from the doc (log only —
  /// they stay local, they just do not sync).
  static const maxDocEntries = 400;
  static const maxDocWatchStates = 300;

  /// Byte budget for the whole published doc (the server refuses at
  /// 60 000); meta rows are dropped oldest-first until it fits.
  static const maxDocBytes = 56000;

  /// A synced description is capped here — the doc has to share its
  /// byte budget with the library itself.
  static const maxMetaOverviewChars = 2000;

  /// Artwork files above this never sync (matches the editor's 10 MB
  /// image-pick cap and the native transfer limit).
  static const maxArtBytes = 10 * 1024 * 1024;

  /// Tombstones older than this are garbage-collected — every linked
  /// device that syncs at all will have applied them long before.
  static const tombstoneTtlMs = 90 * 24 * 3600 * 1000;

  /// Failed map imports (offline, network miss) retry no sooner than
  /// this, so a dead map does not hammer the network every cycle.
  static const mapRetryMs = 10 * 60 * 1000;

  final Map<String, int> _mapRetryAt = {};

  /// Failed artwork fetches (owner went offline mid-transfer, …) retry
  /// with the same backoff as maps.
  final Map<String, int> _artRetryAt = {};

  /// sha256/size per poster file path — poster files are never edited
  /// in place (every save gets a fresh name), so entries never go
  /// stale.
  final Map<String, ({String sha256, int size})> _artInfoByPath = {};

  /// Fingerprint of the art index last handed to the embedded client,
  /// so an unchanged set is not re-posted every cycle.
  String? _lastArtIndex;

  /// For tests: pins the persisted sync-state file somewhere writable.
  @visibleForTesting
  static String? statePathOverride;

  /// For tests: pins the posters directory somewhere writable.
  @visibleForTesting
  static Future<Directory> Function()? postersDirOverride;

  /// Start the periodic cycle (called once from main; runs for the whole
  /// app lifetime and no-ops while the device is not linked).
  void start() {
    _timer ??= Timer.periodic(
      const Duration(seconds: periodSecs),
      (_) => _cycle(),
    );
    // First cycle soon after launch, once the link autostart has had a
    // moment to come up.
    Timer(const Duration(seconds: 8), _cycle);
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// One immediate cycle (the screen's Sync now action). Returns a
  /// user-readable summary, or throws [MyWatchApiException].
  Future<String> syncNow() async {
    final result = await _cycle(rethrowErrors: true);
    if (result == null) return 'Nothing to sync.';
    final parts = <String>[
      if (result.entriesAdded > 0) '${result.entriesAdded} added',
      if (result.entriesRemoved > 0) '${result.entriesRemoved} removed',
      if (result.watchStatesApplied > 0)
        '${result.watchStatesApplied} watch position(s) updated',
      if (result.mapsImported > 0) '${result.mapsImported} map(s) fetched',
      if (result.detailsApplied > 0)
        '${result.detailsApplied} detail edit(s) applied',
      if (result.artFetched > 0) '${result.artFetched} artwork file(s) fetched',
    ];
    return parts.isEmpty ? 'Everything is in sync.' : 'Synced: ${parts.join(', ')}.';
  }

  Future<SyncCycleResult?> _cycle({bool rethrowErrors = false}) async {
    if (_cycling) return null;
    _cycling = true;
    try {
      final status = await _api.status();
      if (!status.supported || !status.linked || status.state != 'ready') {
        return null;
      }
      return await _runCycle(status);
    } catch (e) {
      if (rethrowErrors) rethrow;
      debugPrint('mywatch sync cycle failed: $e');
      return null;
    } finally {
      _cycling = false;
    }
  }

  Future<SyncCycleResult> _runCycle(MyWatchStatus status) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final state = await _loadState();
    var lists = await LibraryStore.load();

    // 1. Locally deleted entries since the last cycle become tombstones.
    final current = membershipOf(lists);
    state.tombstones = updatedTombstones(
      previous: state.snapshot,
      current: current,
      tombstones: state.tombstones,
      nowMs: now,
      ttlMs: tombstoneTtlMs,
    );

    // 2. Merge every remote document in.
    final remote = await _api.syncDocs();
    final merge = mergeRemoteDocs(
      lists: lists,
      tombstones: state.tombstones,
      remoteDocs: [for (final d in remote) d.doc],
    );
    var result = SyncCycleResult(
      entriesAdded: merge.entriesAdded,
      entriesRemoved: merge.entriesRemoved,
    );
    if (merge.changed) {
      lists = merge.lists;
      state.tombstones = merge.tombstones;
      await LibraryStore.save(lists);
      revision.value++;
    }

    // 3. Viewpoints: newest-updatedAt-wins per address, never regressing.
    final states = [
      for (final d in remote) ...watchStatesFromDoc(d.doc),
    ];
    if (states.isNotEmpty) {
      result = result.copyWith(
        watchStatesApplied: await WatchStateStore.instance.mergeAll(states),
      );
    }

    // 4. Fetch missing data maps for entries we now hold, so they play.
    result = result.copyWith(
      mapsImported: await _importMissingMaps(lists, remote, now),
    );

    // 5. Detail edits: newest remote row per key, applied when it beats
    // the local state (a TMDB row always loses to a user edit).
    final winners = remoteMetaWinners(remote);
    var detailsApplied = 0;
    for (final w in winners) {
      final local = await metadataRowFor(w.key);
      if (!shouldApplyRemoteRow(
        localExists: local != null,
        localUserEdited: local?.userEdited ?? false,
        localUpdatedMs: local?.fetchedAt ?? 0,
        remoteUpdatedMs: w.updatedMs,
      )) {
        continue;
      }
      await applyRemoteUserDetails(
        lookupKey: w.key,
        title: w.title ?? local?.title ?? w.key,
        year: w.year,
        overview: w.overview,
        episodeLabel: w.episodeLabel,
        updatedMs: w.updatedMs,
        remoteHasArt: w.art != null,
        postersDirProvider: postersDirOverride,
      );
      detailsApplied++;
    }
    result = result.copyWith(detailsApplied: detailsApplied);

    // 6. Artwork: the doc only carries manifests; pull missing bytes
    // from a linked device that is online right now.
    result = result.copyWith(
      artFetched: await _fetchMissingArt(winners, remote, status, now),
    );

    // 7. Publish our (possibly just-merged) state.
    state.snapshot = membershipOf(lists);
    var metaRows = await _localMetaRows();
    final ourWatchStates = await WatchStateStore.instance.all();
    var doc = buildDoc(
      lists: lists,
      tombstones: state.tombstones,
      watchStates: ourWatchStates,
      nowMs: now,
      metaRows: metaRows,
    );
    while (jsonEncode(doc).length > maxDocBytes && metaRows.isNotEmpty) {
      // Newest-first order, so the oldest edit drops first; it syncs
      // again once the doc has room.
      metaRows = metaRows.sublist(0, metaRows.length - 1);
      debugPrint('mywatch sync: doc over budget, dropped a meta row');
      doc = buildDoc(
        lists: lists,
        tombstones: state.tombstones,
        watchStates: ourWatchStates,
        nowMs: now,
        metaRows: metaRows,
      );
    }
    await _publishArtIndex();
    final fingerprint = jsonEncode(doc..remove('updated_ms'));
    if (fingerprint != state.lastPublished) {
      doc['updated_ms'] = now;
      await _api.publishSync(doc);
      state.lastPublished = fingerprint;
      var entries = 0;
      for (final l in lists) {
        entries += l.entries.length;
      }
      try {
        await _api.announce(lists: lists.length, entries: entries);
      } on Exception {
        // Presence counts are cosmetic; the sync itself succeeded.
      }
    }
    await _saveState(state);
    return result;
  }

  /// Import every remote shrunk map for an address our library holds but
  /// the local map store does not. Known maps import offline; child maps
  /// need a one-time network expansion and are retried with backoff.
  Future<int> _importMissingMaps(
    List<MediaList> lists,
    List<RemoteSyncDoc> remote,
    int nowMs,
  ) async {
    final held = <String>{
      for (final l in lists)
        for (final e in l.entries) e.address.toLowerCase(),
    };
    final maps = <String, String>{};
    for (final d in remote) {
      for (final e in d.maps.entries) {
        maps.putIfAbsent(e.key.toLowerCase(), () => e.value);
      }
    }
    var imported = 0;
    for (final entry in maps.entries) {
      final addr = entry.key;
      if (!held.contains(addr)) continue;
      if ((_mapRetryAt[addr] ?? 0) > nowMs) continue;
      if (await _mapStored(addr)) continue;
      try {
        await importDatamapBytes(base64.decode(entry.value));
        imported++;
      } catch (e) {
        _mapRetryAt[addr] = nowMs + mapRetryMs;
        debugPrint('mywatch sync: map import for $addr failed: $e');
      }
    }
    return imported;
  }

  Future<bool> _mapStored(String addr) async {
    final base = EmbeddedClient.baseUrl();
    if (base == null) return true; // cannot check — do not spam imports
    try {
      final res = await HttpClient()
          .getUrl(Uri.parse('$base/resolve/$addr'))
          .then((r) => r.close());
      final stored = res.statusCode == 200;
      await res.drain<void>();
      return stored;
    } catch (_) {
      return true;
    }
  }

  // ---- detail edits + artwork -------------------------------------------

  /// This device's `userEdited` metadata rows as publishable meta rows,
  /// newest edit first (the doc byte budget drops from the tail).
  Future<List<Map<String, dynamic>>> _localMetaRows() async {
    final db = await LibraryStore.database();
    final rows = await (db.select(db.metadataCache)
          ..where((t) => t.userEdited.equals(true)))
        .get();
    rows.sort((a, b) => b.fetchedAt.compareTo(a.fetchedAt));
    final artByFile = <String, ({String sha256, int size})>{};
    for (final r in rows) {
      final poster = r.posterFile;
      if (poster == null || !poster.startsWith('user_')) continue;
      final info = await _posterInfo(poster);
      if (info != null && info.size <= maxArtBytes) artByFile[poster] = info;
    }
    return metaRowsFrom(rows, artByFile);
  }

  /// sha256/size of a poster-dir file, cached — file names are unique
  /// per save, so a cache hit can never be stale.
  Future<({String sha256, int size})?> _posterInfo(String fileName) async {
    final dir = await (postersDirOverride ?? defaultPostersDir)();
    final path = '${dir.path}/$fileName';
    final cached = _artInfoByPath[path];
    if (cached != null) return cached;
    final file = File(path);
    if (!file.existsSync()) return null;
    final bytes = await file.readAsBytes();
    final info =
        (sha256: crypto.sha256.convert(bytes).toString(), size: bytes.length);
    _artInfoByPath[path] = info;
    return info;
  }

  /// Hand the embedded client the current `sha256 → path` set of our
  /// user artwork so it can answer linked peers' requests. Skipped when
  /// unchanged since the last post.
  Future<void> _publishArtIndex() async {
    final dir = await (postersDirOverride ?? defaultPostersDir)();
    final db = await LibraryStore.database();
    final rows = await (db.select(db.metadataCache)
          ..where((t) => t.userEdited.equals(true)))
        .get();
    final files = <({String sha256, String path})>[];
    for (final r in rows) {
      final poster = r.posterFile;
      if (poster == null || !poster.startsWith('user_')) continue;
      final info = await _posterInfo(poster);
      if (info == null || info.size > maxArtBytes) continue;
      files.add((sha256: info.sha256, path: '${dir.path}/$poster'));
    }
    files.sort((a, b) => a.sha256.compareTo(b.sha256));
    final fingerprint = [for (final f in files) '${f.sha256}:${f.path}'].join();
    if (fingerprint == _lastArtIndex) return;
    try {
      await _api.setArtIndex(files);
      _lastArtIndex = fingerprint;
    } catch (e) {
      debugPrint('mywatch sync: art index publish failed: $e');
    }
  }

  /// Pull every wanted-but-missing artwork file whose owner is online.
  /// Any device whose meta row for the key names the same hash can
  /// serve it — once a device has synced the artwork it re-serves it,
  /// so the original editor need not stay online forever.
  Future<int> _fetchMissingArt(
    List<RemoteMetaRow> winners,
    List<RemoteSyncDoc> remote,
    MyWatchStatus status,
    int nowMs,
  ) async {
    final online = {
      for (final d in status.devices)
        if (!d.isSelf && d.online) d.agentId,
    };
    if (online.isEmpty) return 0;
    var fetched = 0;
    for (final w in winners) {
      final art = w.art;
      if (art == null || art.size > maxArtBytes) continue;
      final local = await metadataRowFor(w.key);
      // Only rows we actually adopted want this artwork; a newer local
      // edit wins the LWW round and keeps its own art.
      if (local == null || !local.userEdited) continue;
      if (local.fetchedAt > w.updatedMs) continue;
      final current = local.posterFile;
      if (current != null && current.startsWith('user_')) {
        final info = await _posterInfo(current);
        if (info != null && info.sha256 == art.sha256) continue;
      }
      if ((_artRetryAt[art.sha256] ?? 0) > nowMs) continue;
      final owners = [
        for (final d in remote)
          if (online.contains(d.agentId))
            for (final r in remoteMetaWinners([d]))
              if (r.key == w.key && r.art?.sha256 == art.sha256) d.agentId,
      ];
      if (owners.isEmpty) continue;
      try {
        final path =
            await _api.fetchArt(agentId: owners.first, sha256: art.sha256);
        final file = File(path);
        final bytes = await file.readAsBytes();
        await applyRemotePoster(w.key, bytes,
            postersDirProvider: postersDirOverride);
        try {
          file.deleteSync();
        } catch (_) {}
        fetched++;
      } catch (e) {
        _artRetryAt[art.sha256] = nowMs + mapRetryMs;
        debugPrint('mywatch sync: artwork ${art.sha256} fetch failed: $e');
      }
    }
    return fetched;
  }

  // ---- pure merge/publish logic (unit-tested directly) ------------------

  /// `title(lower) → address(lower) → added_ms` for the whole library.
  /// A pre-column add time of 0/null publishes as 1, so any real
  /// tombstone beats it.
  static Map<String, Map<String, int>> membershipOf(List<MediaList> lists) => {
        for (final l in lists)
          l.title.toLowerCase(): {
            for (final e in l.entries)
              e.address.toLowerCase():
                  (e.addedAt == null || e.addedAt == 0) ? 1 : e.addedAt!,
          },
      };

  /// Roll the tombstone set forward: whatever [previous] held that
  /// [current] no longer does was deleted here since the last cycle
  /// (stamped [nowMs]); an address re-added after its tombstone clears
  /// it; stones older than [ttlMs] fall off.
  static Map<String, Map<String, int>> updatedTombstones({
    required Map<String, Map<String, int>> previous,
    required Map<String, Map<String, int>> current,
    required Map<String, Map<String, int>> tombstones,
    required int nowMs,
    required int ttlMs,
  }) {
    final out = {
      for (final e in tombstones.entries)
        e.key: Map<String, int>.of(e.value),
    };
    for (final listEntry in previous.entries) {
      final title = listEntry.key;
      final have = current[title] ?? const {};
      for (final addr in listEntry.value.keys) {
        if (!have.containsKey(addr)) {
          out.putIfAbsent(title, () => {})[addr] = nowMs;
        }
      }
    }
    for (final listEntry in current.entries) {
      final stones = out[listEntry.key];
      if (stones == null) continue;
      for (final e in listEntry.value.entries) {
        final stone = stones[e.key];
        if (stone != null && e.value > stone) stones.remove(e.key);
      }
    }
    out.removeWhere((_, stones) {
      stones.removeWhere((_, ms) => nowMs - ms > ttlMs);
      return stones.isEmpty;
    });
    return out;
  }

  /// The published document. Lists match across devices by title;
  /// entries carry their add time for the LWW merge; `removed` carries
  /// this device's tombstones so deletions propagate.
  static Map<String, dynamic> buildDoc({
    required List<MediaList> lists,
    required Map<String, Map<String, int>> tombstones,
    required List<WatchState> watchStates,
    required int nowMs,
    List<Map<String, dynamic>> metaRows = const [],
  }) {
    var entryBudget = maxDocEntries;
    final listDocs = <Map<String, dynamic>>[];
    for (final l in lists) {
      final title = l.title.toLowerCase();
      final take = l.entries.take(entryBudget).toList();
      entryBudget -= take.length;
      if (take.length < l.entries.length) {
        debugPrint(
            'mywatch sync: list "${l.title}" truncated in the sync doc '
            '(${l.entries.length - take.length} entries over the cap)');
      }
      listDocs.add({
        'title': l.title,
        'entries': [
          for (final e in take)
            {
              'name': e.name,
              'address': e.address.toLowerCase(),
              'added_ms':
                  (e.addedAt == null || e.addedAt == 0) ? 1 : e.addedAt,
              if (e.sizeBytes != null) 'size': e.sizeBytes,
              if (e.videoInfo != null) 'video': e.videoInfo,
            },
        ],
        if (tombstones[title]?.isNotEmpty ?? false)
          'removed': tombstones[title],
      });
    }
    // Tombstoned lists we no longer hold at all still need their stones
    // published, or the deletion never reaches the other devices.
    final held = {for (final l in lists) l.title.toLowerCase()};
    for (final e in tombstones.entries) {
      if (held.contains(e.key) || e.value.isEmpty) continue;
      listDocs.add({'title': e.key, 'entries': const [], 'removed': e.value});
    }
    return {
      'v': 1,
      'updated_ms': nowMs,
      'lists': listDocs,
      'watch': [
        for (final s in watchStates.take(maxDocWatchStates))
          {
            'address': s.address,
            'pos_ms': s.positionMs,
            'dur_ms': s.durationMs,
            'completed': s.completed,
            'updated_ms': s.updatedAt,
          },
      ],
      if (metaRows.isNotEmpty) 'meta': {'v': 1, 'rows': metaRows},
    };
  }

  /// `userEdited` cache rows as sync-doc meta rows. Text fields ride
  /// inline (descriptions capped); artwork becomes a manifest from
  /// [artByFile] (`posterFile name → sha256/size`) — files not in the
  /// map (missing, oversized, TMDB-owned) publish no manifest.
  static List<Map<String, dynamic>> metaRowsFrom(
    Iterable<MetadataCacheRow> rows,
    Map<String, ({String sha256, int size})> artByFile,
  ) =>
      [
        for (final r in rows)
          if (r.userEdited && r.lookupKey.isNotEmpty)
            {
              'key': r.lookupKey,
              'updated_ms': r.fetchedAt,
              if (r.title != null) 'title': r.title,
              if (r.year != null) 'year': r.year,
              if (r.overview case final o?)
                'overview': o.length > maxMetaOverviewChars
                    ? o.substring(0, maxMetaOverviewChars)
                    : o,
              if (r.episodeLabel != null) 'episode': r.episodeLabel,
              if (r.posterFile case final p? when artByFile.containsKey(p))
                'art': {
                  'sha256': artByFile[p]!.sha256,
                  'size': artByFile[p]!.size,
                },
            },
      ];

  /// The newest remote meta row per lookup key across every device's
  /// document, tagged with the publishing device.
  static List<RemoteMetaRow> remoteMetaWinners(List<RemoteSyncDoc> remote) {
    final best = <String, RemoteMetaRow>{};
    for (final d in remote) {
      final meta = d.doc['meta'];
      final rows = meta is Map<String, dynamic> ? meta['rows'] : null;
      for (final r in rows is List ? rows : const []) {
        if (r is! Map<String, dynamic>) continue;
        final key = r['key'] as String? ?? '';
        final updatedMs = r['updated_ms'] as int? ?? 0;
        if (key.isEmpty || updatedMs <= 0) continue;
        final artMap = r['art'] as Map<String, dynamic>?;
        final artSha = (artMap?['sha256'] as String? ?? '').toLowerCase();
        final row = RemoteMetaRow(
          agentId: d.agentId,
          key: key,
          updatedMs: updatedMs,
          title: r['title'] as String?,
          year: r['year'] as int?,
          overview: r['overview'] as String?,
          episodeLabel: r['episode'] as String?,
          art: artMap == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(artSha)
              ? null
              : (sha256: artSha, size: artMap['size'] as int? ?? 0),
        );
        final cur = best[key];
        if (cur == null || row.updatedMs > cur.updatedMs) best[key] = row;
      }
    }
    return best.values.toList();
  }

  /// Last-writer-wins for one detail row: a remote user edit beats a
  /// missing row and any TMDB match, and beats a local user edit only
  /// when strictly newer (ties keep local, on both devices — stable).
  static bool shouldApplyRemoteRow({
    required bool localExists,
    required bool localUserEdited,
    required int localUpdatedMs,
    required int remoteUpdatedMs,
  }) {
    if (!localExists) return true;
    if (!localUserEdited) return true;
    return remoteUpdatedMs > localUpdatedMs;
  }

  /// The remote document's watch states, ready for
  /// [WatchStateStore.mergeAll].
  static List<WatchState> watchStatesFromDoc(Map<String, dynamic> doc) => [
        for (final w in doc['watch'] as List? ?? const [])
          if (w is Map<String, dynamic> && w['address'] is String)
            WatchState(
              address: (w['address'] as String).toLowerCase(),
              positionMs: w['pos_ms'] as int? ?? 0,
              durationMs: w['dur_ms'] as int? ?? 0,
              completed: w['completed'] as bool? ?? false,
              updatedAt: w['updated_ms'] as int? ?? 0,
            ),
      ];

  /// Merge remote documents into the local library — the LWW element
  /// set. Newest add vs newest remove wins per `(title, address)`; a
  /// list emptied purely by remote tombstones is deleted; remote
  /// tombstones are adopted locally so they keep propagating.
  static SyncMergeResult mergeRemoteDocs({
    required List<MediaList> lists,
    required Map<String, Map<String, int>> tombstones,
    required List<Map<String, dynamic>> remoteDocs,
  }) {
    final out = [for (final l in lists) l];
    final stones = {
      for (final e in tombstones.entries)
        e.key: Map<String, int>.of(e.value),
    };
    var changed = false;
    var added = 0;
    var removed = 0;

    int indexOf(String titleLower) =>
        out.indexWhere((l) => l.title.toLowerCase() == titleLower);

    for (final doc in remoteDocs) {
      for (final rl in doc['lists'] as List? ?? const []) {
        if (rl is! Map<String, dynamic>) continue;
        final title = (rl['title'] as String? ?? '').trim();
        if (title.isEmpty) continue;
        final titleLower = title.toLowerCase();

        // Remote tombstones first: adopt them, then let newer adds win.
        final removedMap = rl['removed'] as Map<String, dynamic>? ?? const {};
        for (final e in removedMap.entries) {
          final addr = e.key.toLowerCase();
          final ms = e.value as int? ?? 0;
          if (ms <= 0) continue;
          final mine = stones[titleLower]?[addr] ?? 0;
          if (ms > mine) {
            stones.putIfAbsent(titleLower, () => {})[addr] = ms;
          }
        }

        for (final re in rl['entries'] as List? ?? const []) {
          if (re is! Map<String, dynamic>) continue;
          final addr = (re['address'] as String? ?? '').toLowerCase();
          if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(addr)) continue;
          final addedMs = re['added_ms'] as int? ?? 1;
          final stone = stones[titleLower]?[addr] ?? 0;
          if (stone >= addedMs) continue; // removed later than added
          final i = indexOf(titleLower);
          final holds = i != -1 &&
              out[i].entries.any((x) => x.address.toLowerCase() == addr);
          if (holds) continue;
          final entry = MediaEntry(
            name: re['name'] as String? ?? addr,
            address: addr,
            addedAt: addedMs,
            sizeBytes: re['size'] as int?,
            videoInfo: re['video'] as String?,
          );
          if (i == -1) {
            out.add(MediaList(
              id: '${DateTime.now().microsecondsSinceEpoch}-$titleLower',
              title: title,
              entries: [entry],
            ));
          } else {
            out[i] = out[i].copyWith(entries: [...out[i].entries, entry]);
          }
          changed = true;
          added++;
        }
      }
    }

    // Apply the (merged) tombstones to what we hold: anything removed
    // more recently than it was added goes.
    for (var i = out.length - 1; i >= 0; i--) {
      final titleLower = out[i].title.toLowerCase();
      final listStones = stones[titleLower];
      if (listStones == null || listStones.isEmpty) continue;
      final hadEntries = out[i].entries.isNotEmpty;
      final kept = [
        for (final e in out[i].entries)
          if ((listStones[e.address.toLowerCase()] ?? 0) <
              ((e.addedAt == null || e.addedAt == 0) ? 1 : e.addedAt!))
            e,
      ];
      if (kept.length != out[i].entries.length) {
        removed += out[i].entries.length - kept.length;
        changed = true;
        if (kept.isEmpty && hadEntries) {
          // Emptied purely by remote deletions — the list is gone.
          out.removeAt(i);
        } else {
          out[i] = out[i].copyWith(entries: kept);
        }
      }
    }

    return SyncMergeResult(
      lists: out,
      tombstones: stones,
      changed: changed,
      entriesAdded: added,
      entriesRemoved: removed,
    );
  }

  // ---- persisted sync state ---------------------------------------------

  Future<File> _stateFile() async {
    final path = statePathOverride ??
        '${(await getApplicationSupportDirectory()).path}/mywatch_sync.json';
    return File(path);
  }

  Future<_SyncState> _loadState() async {
    try {
      final file = await _stateFile();
      if (!await file.exists()) return _SyncState();
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return _SyncState()
        ..snapshot = _nestedIntMap(json['snapshot'])
        ..tombstones = _nestedIntMap(json['tombstones'])
        ..lastPublished = json['last_published'] as String?;
    } catch (_) {
      return _SyncState();
    }
  }

  Future<void> _saveState(_SyncState state) async {
    try {
      final file = await _stateFile();
      await file.writeAsString(jsonEncode({
        'snapshot': state.snapshot,
        'tombstones': state.tombstones,
        'last_published': state.lastPublished,
      }));
    } catch (e) {
      debugPrint('mywatch sync: state save failed: $e');
    }
  }

  static Map<String, Map<String, int>> _nestedIntMap(dynamic value) => {
        for (final e in (value as Map<String, dynamic>? ?? const {}).entries)
          e.key: {
            for (final inner in (e.value as Map<String, dynamic>).entries)
              inner.key: inner.value as int,
          },
      };
}

class _SyncState {
  /// `title(lower) → address → added_ms` as of the last cycle — the diff
  /// base that turns local deletions into tombstones.
  Map<String, Map<String, int>> snapshot = {};

  /// `title(lower) → address → removed_ms`.
  Map<String, Map<String, int>> tombstones = {};

  /// Fingerprint of the last published doc (minus its timestamp), so an
  /// unchanged library publishes nothing.
  String? lastPublished;
}

class SyncMergeResult {
  const SyncMergeResult({
    required this.lists,
    required this.tombstones,
    required this.changed,
    required this.entriesAdded,
    required this.entriesRemoved,
  });

  final List<MediaList> lists;
  final Map<String, Map<String, int>> tombstones;
  final bool changed;
  final int entriesAdded;
  final int entriesRemoved;
}

/// One remote device's user-edit row after the cross-device
/// newest-wins pass, ready to compare against the local cache.
class RemoteMetaRow {
  const RemoteMetaRow({
    required this.agentId,
    required this.key,
    required this.updatedMs,
    this.title,
    this.year,
    this.overview,
    this.episodeLabel,
    this.art,
  });

  final String agentId;
  final String key;
  final int updatedMs;
  final String? title;
  final int? year;
  final String? overview;
  final String? episodeLabel;

  /// Artwork manifest — the bytes travel separately, in full quality.
  final ({String sha256, int size})? art;
}

class SyncCycleResult {
  const SyncCycleResult({
    this.entriesAdded = 0,
    this.entriesRemoved = 0,
    this.watchStatesApplied = 0,
    this.mapsImported = 0,
    this.detailsApplied = 0,
    this.artFetched = 0,
  });

  final int entriesAdded;
  final int entriesRemoved;
  final int watchStatesApplied;
  final int mapsImported;
  final int detailsApplied;
  final int artFetched;

  SyncCycleResult copyWith({
    int? watchStatesApplied,
    int? mapsImported,
    int? detailsApplied,
    int? artFetched,
  }) =>
      SyncCycleResult(
        entriesAdded: entriesAdded,
        entriesRemoved: entriesRemoved,
        watchStatesApplied: watchStatesApplied ?? this.watchStatesApplied,
        mapsImported: mapsImported ?? this.mapsImported,
        detailsApplied: detailsApplied ?? this.detailsApplied,
        artFetched: artFetched ?? this.artFetched,
      );
}
