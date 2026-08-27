import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../db/app_database.dart';
import '../models/media_list.dart';
import 'channel_service.dart';
import 'datamap_import.dart';
import 'embedded_client.dart';
import 'library_store.dart';
import 'metadata.dart';
import 'metadata_service.dart';
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
/// TMDB metadata syncs the same way, so a KEYLESS device gets the full
/// experience (posters, descriptions, ratings, episode stills) from a
/// linked device that has a TMDB key. Each doc carries a compact `have`
/// list (hashes of the library keys whose metadata + artwork this
/// device already holds); a device publishes a `tmdb` section — full
/// cache rows plus per-show/per-season shared texts and a file
/// manifest — only for keys some linked device still lacks, so the
/// section drains to nothing once everyone has everything. Receivers
/// fill only missing rows and cached misses (a user edit or an own
/// TMDB match always wins) and pull the artwork bytes over the same
/// x0x transfer, saved under the original TMDB file names.
///
/// Channels sync as *subscriptions*, never as content: channel lists
/// (the amber read-only mirrors of a channel manifest) stay out of the
/// personal doc, and a `channels` section carries each subscription's
/// `wchn1-` code + subscribe time and unsubscribe tombstones instead.
/// A linked device subscribes by code, so the channel arrives with its
/// badge and auto-updates from the channel's own signed heads; a
/// device's OWN channel is announced the same way, so the user's other
/// devices follow it as subscribers.
///
/// The service is quiet unless the device is linked; every cycle checks.
class MyWatchSync {
  MyWatchSync({MyWatchApi? api}) : _api = api ?? MyWatchApi();

  /// Replaceable for tests.
  static MyWatchSync instance = MyWatchSync();

  final MyWatchApi _api;
  Timer? _timer;
  bool _cycling = false;

  /// Problems collected while the current cycle runs — published into
  /// [status] at the cycle boundary.
  List<String> _problems = [];

  /// Bumped after a merge changed the library, so screens showing list
  /// content can refresh without a route pop.
  static final ValueNotifier<int> revision = ValueNotifier(0);

  /// Live view of the background sync — link state, what the running
  /// cycle is doing, the last cycle's outcome and problems — for the
  /// My W@tch screen's activity card and the home status bar indicator.
  static final ValueNotifier<MyWatchSyncStatus> status =
      ValueNotifier(const MyWatchSyncStatus());

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

  /// Failed artwork fetches retry with a PROGRESSIVE backoff — see
  /// [artRetryDelayMs]. Keyed by manifest sha256; the counter clears on
  /// success.
  final Map<String, int> _artRetryAt = {};
  final Map<String, int> _artFailures = {};

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
    return result == null ? 'Nothing to sync.' : summarize(result);
  }

  /// One-line, user-readable outcome of a finished cycle.
  static String summarize(SyncCycleResult result) {
    final parts = <String>[
      if (result.entriesAdded > 0) '${result.entriesAdded} added',
      if (result.entriesRemoved > 0) '${result.entriesRemoved} removed',
      if (result.watchStatesApplied > 0)
        '${result.watchStatesApplied} watch position(s) updated',
      if (result.mapsImported > 0) '${result.mapsImported} map(s) fetched',
      if (result.detailsApplied > 0)
        '${result.detailsApplied} detail edit(s) applied',
      if (result.tmdbApplied > 0)
        '${result.tmdbApplied} title detail(s) synced',
      if (result.artFetched > 0) '${result.artFetched} artwork file(s) fetched',
      if (result.channelsChanged > 0)
        '${result.channelsChanged} channel subscription(s) updated',
    ];
    return parts.isEmpty ? 'Everything is in sync.' : 'Synced: ${parts.join(', ')}.';
  }

  /// Update the live status mid-cycle: [what] is the stage now running,
  /// null when the cycle is over.
  void _setActivity(String? what) {
    final s = status.value;
    status.value = MyWatchSyncStatus(
      supported: s.supported,
      linked: s.linked,
      agentState: s.agentState,
      lastSyncMs: s.lastSyncMs,
      syncing: what != null,
      activity: what,
      lastCycleAtMs: s.lastCycleAtMs,
      lastSummary: s.lastSummary,
      problems: s.problems,
    );
  }

  Future<SyncCycleResult?> _cycle({bool rethrowErrors = false}) async {
    if (_cycling) return null;
    _cycling = true;
    try {
      final link = await _api.status();
      if (!link.supported || !link.linked || link.state != 'ready') {
        status.value = MyWatchSyncStatus(
          supported: link.supported,
          linked: link.linked,
          agentState: link.state,
          lastSyncMs: link.lastSyncMs,
          lastCycleAtMs: status.value.lastCycleAtMs,
          lastSummary: status.value.lastSummary,
          problems: status.value.problems,
        );
        return null;
      }
      _problems = [];
      status.value = MyWatchSyncStatus(
        supported: true,
        linked: true,
        agentState: link.state,
        lastSyncMs: link.lastSyncMs,
        syncing: true,
        activity: 'Checking your other devices…',
        lastCycleAtMs: status.value.lastCycleAtMs,
        lastSummary: status.value.lastSummary,
        problems: status.value.problems,
      );
      SyncCycleResult? result;
      try {
        result = await _runCycle(link);
        return result;
      } finally {
        status.value = MyWatchSyncStatus(
          supported: true,
          linked: true,
          agentState: link.state,
          lastSyncMs: link.lastSyncMs,
          lastCycleAtMs: DateTime.now().millisecondsSinceEpoch,
          lastSummary: result == null ? null : summarize(result),
          problems: List.unmodifiable(_problems),
        );
      }
    } catch (e) {
      // The mid-cycle finally above has already published the collected
      // problems; re-publish with the failure itself appended.
      final s = status.value;
      status.value = MyWatchSyncStatus(
        supported: s.supported,
        linked: s.linked,
        agentState: s.agentState,
        lastSyncMs: s.lastSyncMs,
        lastCycleAtMs: DateTime.now().millisecondsSinceEpoch,
        lastSummary: s.lastSummary,
        problems: List.unmodifiable(
            [...s.problems.where((p) => !p.startsWith('Sync failed:')),
                'Sync failed: $e']),
      );
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
    _setActivity('Merging changes from your devices…');
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

    // Stages 3–6 each fail on their own: a broken map import or artwork
    // pull must not stop detail edits (or the publish below) — before
    // this, one throw silently killed the rest of the cycle while the
    // already-saved list merge made sync look like it worked.
    // 3. Viewpoints: newest-updatedAt-wins per address, never regressing.
    final states = [
      for (final d in remote) ...watchStatesFromDoc(d.doc),
    ];
    if (states.isNotEmpty) {
      try {
        result = result.copyWith(
          watchStatesApplied: await WatchStateStore.instance.mergeAll(states),
        );
      } catch (e) {
        _problems.add('Applying watch positions failed: $e');
      }
    }

    // 4. Fetch missing data maps for entries we now hold, so they play.
    _setActivity('Fetching data maps…');
    try {
      result = result.copyWith(
        mapsImported: await _importMissingMaps(lists, remote, now),
      );
    } catch (e) {
      _problems.add('Fetching data maps failed: $e');
    }

    // 5. Detail edits: newest remote row per key, applied when it beats
    // the local state (a TMDB row always loses to a user edit).
    _setActivity('Applying detail edits…');
    final winners = remoteMetaWinners(remote);
    var detailsApplied = 0;
    for (final w in winners) {
      try {
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
      } catch (e) {
        _problems.add('Applying an edit for "${w.title ?? w.key}" failed: $e');
      }
    }
    result = result.copyWith(detailsApplied: detailsApplied);

    // 5b. TMDB rows other devices published for keys we lack: the
    // keyless half of full metadata sync. Only missing rows and cached
    // misses are filled — a user edit, an own TMDB match, or a bundled
    // seed row always wins, so this can never overwrite anything.
    var tmdbApplied = 0;
    for (final w in remoteTmdbWinners(remote)) {
      try {
        final local = await metadataRowFor(w.key);
        if (local != null && local.found) continue;
        await applyRemoteTmdbDetails(
          lookupKey: w.key,
          updatedMs: w.updatedMs,
          title: w.title,
          year: w.year,
          overview: w.overview,
          category: w.category,
          episodeLabel: w.episodeLabel,
          mediaType: w.mediaType,
          tmdbId: w.tmdbId,
          rating: w.rating,
          airDate: w.airDate,
          showOverview: w.showOverview,
          seasonOverview: w.seasonOverview,
          posterFile: w.posterFile,
          stillFile: w.stillFile,
          showPosterFile: w.showPosterFile,
        );
        tmdbApplied++;
      } catch (e) {
        _problems.add('Syncing details for "${w.title ?? w.key}" failed: $e');
      }
    }
    result = result.copyWith(tmdbApplied: tmdbApplied);

    // 6. Artwork: the doc only carries manifests; pull missing bytes
    // from a linked device — user posters under fresh `user_` names,
    // TMDB files under their original shared names.
    var artFetched = 0;
    try {
      artFetched += await _fetchMissingArt(winners, remote, status, now);
    } catch (e) {
      _problems.add('Fetching artwork failed: $e');
    }
    try {
      artFetched += await _fetchMissingTmdbArt(remote, status, now);
    } catch (e) {
      _problems.add('Fetching artwork failed: $e');
    }
    result = result.copyWith(artFetched: artFetched);

    // 6b. Channel subscriptions travel between devices too — as
    // subscriptions, so a channel arrives amber-badged and auto-updating
    // instead of as a copy of its content (channel lists themselves stay
    // out of the personal doc entirely).
    ChannelSyncView? channelView;
    try {
      channelView = await ChannelService.instance.syncView();
      if (channelView != null) {
        final actions = channelActions(
          localSubs: channelView.subs,
          localStones: channelView.stones,
          ownPubkey: channelView.ownPubkey,
          remote: remote,
        );
        if (!actions.isEmpty) {
          _setActivity('Syncing channel subscriptions…');
          result = result.copyWith(
              channelsChanged: await _applyChannelActions(actions));
          // Republish what the actions just changed.
          channelView = await ChannelService.instance.syncView();
        }
      }
    } catch (e) {
      _problems.add('Syncing channel subscriptions failed: $e');
    }

    // 7. Publish our (possibly just-merged) state.
    _setActivity("Sending this device's library to your devices…");
    state.snapshot = membershipOf(lists);
    final metaRows = await _localMetaRows();
    final libKeys = libraryLookupKeys(lists);
    final haveHashes = await _localHaveHashes(libKeys);
    final tmdbSection = await _localTmdbSection(libKeys, remote);
    // Newest-first from the store, so a budget trim drops the stalest.
    final ourWatchStates = await WatchStateStore.instance.all();
    final built = buildDocWithinBudget(
      lists: lists,
      tombstones: state.tombstones,
      watchStates: ourWatchStates,
      nowMs: now,
      metaRows: metaRows,
      haveHashes: haveHashes,
      tmdbSection: tmdbSection,
      channelSubs: {
        ...?channelView?.subs,
        ?channelView?.ownPubkey: ChannelSyncSub(
          code: channelView!.ownCode!,
          addedMs: channelView.ownAddedMs,
        ),
      },
      channelStones: channelView?.stones ?? const {},
    );
    final doc = built.doc;
    if (built.metaDropped > 0) {
      _problems.add('${built.metaDropped} detail edit(s) did not fit in the '
          'sync document this cycle');
    }
    if (built.tmdbDropped > 0) {
      // Self-healing: applied rows join the receivers' `have` lists,
      // which shrinks the section until the dropped tail fits.
      debugPrint('mywatch sync: ${built.tmdbDropped} TMDB rows over the doc '
          'budget wait for a later cycle');
    }
    await _publishArtIndex();
    final fingerprint = jsonEncode(doc..remove('updated_ms'));
    if (fingerprint != state.lastPublished) {
      doc['updated_ms'] = now;
      try {
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
      } catch (e) {
        _problems.add('Sending your library to your devices failed: $e');
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

  /// Apply the merged channel-subscription actions through
  /// [ChannelService] (which handles the core, the records, and the
  /// amber lists). Individual failures surface as problems; the rest
  /// still applies.
  Future<int> _applyChannelActions(ChannelSyncActions actions) async {
    final service = ChannelService.instance;
    if (actions.stones.isNotEmpty) {
      await service.adoptSubStones(actions.stones);
    }
    var changed = 0;
    for (final s in actions.subscribe) {
      try {
        await service.subscribe(s.code, addedMs: s.addedMs);
        changed++;
      } catch (e) {
        _problems.add('Subscribing to a synced channel failed: $e');
      }
    }
    for (final e in actions.unsubscribe.entries) {
      try {
        // The tombstone's own time, not "now" — a racing re-subscribe on
        // another device must still beat this stone.
        await service.unsubscribe(e.key, removedMs: e.value);
        changed++;
      } catch (e) {
        _problems.add('Unsubscribing a synced channel failed: $e');
      }
    }
    return changed;
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

  /// Hand the embedded client the current `sha256 → path` set of every
  /// artwork file our metadata rows reference — user posters and TMDB
  /// files alike — so it can answer linked peers' requests. Skipped
  /// when unchanged since the last post.
  Future<void> _publishArtIndex() async {
    final dir = await (postersDirOverride ?? defaultPostersDir)();
    final db = await LibraryStore.database();
    final rows = await (db.select(db.metadataCache)
          ..where((t) => t.found.equals(true)))
        .get();
    final files = <({String sha256, String path})>[];
    final seen = <String>{};
    for (final r in rows) {
      for (final name in [r.posterFile, r.stillFile, r.showPosterFile]) {
        if (name == null || !seen.add(name)) continue;
        final info = await _posterInfo(name);
        if (info == null || info.size > maxArtBytes) continue;
        files.add((sha256: info.sha256, path: '${dir.path}/$name'));
      }
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

  /// Pull every wanted-but-missing artwork file from the devices whose
  /// meta row names the same hash. Any such device can serve it — once
  /// a device has synced the artwork it re-serves it, so the original
  /// editor need not stay online forever. Presence only *orders* the
  /// candidates (online-looking first): x0x presence under-reports on
  /// real networks (a reachable device often shows offline), so it must
  /// never gate the attempt — the transfer's own timeouts and the retry
  /// backoff bound the cost of a dead candidate.
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
          for (final r in remoteMetaWinners([d]))
            if (r.key == w.key && r.art?.sha256 == art.sha256) d.agentId,
      ]..sort((a, b) =>
          (online.contains(b) ? 1 : 0) - (online.contains(a) ? 1 : 0));
      if (owners.isEmpty) continue;
      _setActivity('Fetching artwork…');
      Object? failure;
      // Two candidates bound the worst case — every dead one costs the
      // transfer's full chunk timeouts.
      for (final owner in owners.take(2)) {
        try {
          final path =
              await _api.fetchArt(agentId: owner, sha256: art.sha256);
          final file = File(path);
          final bytes = await file.readAsBytes();
          await applyRemotePoster(w.key, bytes,
              postersDirProvider: postersDirOverride);
          try {
            file.deleteSync();
          } catch (_) {}
          fetched++;
          _artFailures.remove(art.sha256);
          failure = null;
          break;
        } catch (e) {
          failure = e;
        }
      }
      if (failure != null) {
        _artFetchFailed(art.sha256, nowMs);
        _problems.add(
            'Artwork for "${w.title ?? w.key}" could not be fetched: $failure');
        debugPrint('mywatch sync: artwork ${art.sha256} fetch failed: $failure');
      }
    }
    return fetched;
  }

  // ---- TMDB metadata for keyless devices --------------------------------

  /// The compact `have` list for our published doc: hashes of every
  /// library lookup key whose metadata this device holds in full — a
  /// found row with every referenced artwork file on disk, or any user
  /// edit (its artwork travels via the meta-row manifest instead).
  /// Linked devices publish TMDB rows only for keys absent from this
  /// list; a row applied without its art keeps its key OFF the list, so
  /// the file manifests stay published until the bytes finally land.
  Future<List<String>> _localHaveHashes(Set<String> libKeys) async {
    if (libKeys.isEmpty) return const [];
    final db = await LibraryStore.database();
    final rows = await (db.select(db.metadataCache)
          ..where((t) => t.found.equals(true)))
        .get();
    final dir = await (postersDirOverride ?? defaultPostersDir)();
    final out = <String>[];
    for (final r in rows) {
      if (!libKeys.contains(r.lookupKey)) continue;
      if (!r.userEdited) {
        var complete = true;
        for (final name in [r.posterFile, r.stillFile, r.showPosterFile]) {
          if (name != null && !File('${dir.path}/$name').existsSync()) {
            complete = false;
          }
        }
        if (!complete) continue;
      }
      out.add(metaKeyHash(r.lookupKey));
    }
    return out..sort();
  }

  /// The `tmdb` doc section: full TMDB cache rows for the library keys
  /// some linked device reports missing (via its `have` list), newest
  /// match first, with per-show/per-season shared texts published once
  /// and a `sha256/size` manifest for every referenced artwork file.
  /// Null when nobody needs anything — the steady state. Devices whose
  /// docs carry no `have` list (older app versions) are skipped: they
  /// could not apply the rows anyway.
  Future<Map<String, dynamic>?> _localTmdbSection(
    Set<String> libKeys,
    List<RemoteSyncDoc> remote,
  ) async {
    final needed = <String>{};
    for (final d in remote) {
      final have = d.doc['have'];
      if (have is! List) continue;
      final haveSet = have.whereType<String>().toSet();
      for (final k in libKeys) {
        if (!haveSet.contains(metaKeyHash(k))) needed.add(k);
      }
    }
    if (needed.isEmpty) return null;
    final db = await LibraryStore.database();
    final all = await (db.select(db.metadataCache)
          ..where((t) => t.found.equals(true)))
        .get();
    final rows = [
      for (final r in all)
        if (!r.userEdited && needed.contains(r.lookupKey)) r,
    ]..sort((a, b) => b.fetchedAt.compareTo(a.fetchedAt));
    if (rows.isEmpty) return null;

    final out = <Map<String, dynamic>>[];
    final shows = <String, dynamic>{};
    final seasons = <String, dynamic>{};
    final files = <String, dynamic>{};
    String? cap(String? s) => s == null || s.length <= maxMetaOverviewChars
        ? s
        : s.substring(0, maxMetaOverviewChars);
    Future<void> addFile(String? name) async {
      if (name == null || name.startsWith('user_')) return;
      if (files.containsKey(name)) return;
      final info = await _posterInfo(name);
      if (info == null || info.size > maxArtBytes) return;
      files[name] = {'sha256': info.sha256, 'size': info.size};
    }

    for (final r in rows) {
      out.add({
        'key': r.lookupKey,
        'updated_ms': r.fetchedAt,
        if (r.title != null) 'title': r.title,
        if (r.year != null) 'year': r.year,
        if (r.overview case final o?) 'overview': cap(o),
        if (r.category != null) 'category': r.category,
        if (r.episodeLabel != null) 'episode': r.episodeLabel,
        if (r.mediaType != null) 'type': r.mediaType,
        if (r.tmdbId != null) 'tmdb_id': r.tmdbId,
        if (r.rating != null) 'rating': r.rating,
        if (r.airDate != null) 'air_date': r.airDate,
        if (r.posterFile != null) 'poster': r.posterFile,
        if (r.stillFile != null) 'still': r.stillFile,
      });
      await addFile(r.posterFile);
      await addFile(r.stillFile);
      final ep = episodeKeyPattern.firstMatch(r.lookupKey);
      if (ep == null) continue;
      final showKey = ep.group(1)!;
      final seasonKey = '$showKey:s${ep.group(2)}';
      if (!shows.containsKey(showKey) &&
          (r.showOverview != null || r.showPosterFile != null)) {
        shows[showKey] = {
          if (r.showOverview case final o?) 'overview': cap(o),
          if (r.showPosterFile != null) 'poster': r.showPosterFile,
        };
        await addFile(r.showPosterFile);
      }
      if (!seasons.containsKey(seasonKey) && r.seasonOverview != null) {
        seasons[seasonKey] = {'overview': cap(r.seasonOverview)};
      }
    }
    return {
      'v': 1,
      'rows': out,
      if (shows.isNotEmpty) 'shows': shows,
      if (seasons.isNotEmpty) 'seasons': seasons,
      if (files.isNotEmpty) 'files': files,
    };
  }

  /// Pull every TMDB artwork file that remote `tmdb` sections manifest,
  /// a local metadata row references, and the posters dir lacks. Saved
  /// under the original TMDB name — episodes of one season share their
  /// season poster through it — with the same online-first owner
  /// ordering and retry backoff as the user-artwork pull.
  Future<int> _fetchMissingTmdbArt(
    List<RemoteSyncDoc> remote,
    MyWatchStatus status,
    int nowMs,
  ) async {
    final manifest = remoteTmdbFiles(remote);
    if (manifest.isEmpty) return 0;
    final wanted = await _referencedArtFiles();
    final online = {
      for (final d in status.devices)
        if (!d.isSelf && d.online) d.agentId,
    };
    final dir = await (postersDirOverride ?? defaultPostersDir)();
    var fetched = 0;
    for (final f in manifest.values) {
      if (!wanted.contains(f.name) || f.size > maxArtBytes) continue;
      final target = File('${dir.path}/${f.name}');
      if (target.existsSync()) continue;
      if ((_artRetryAt[f.sha256] ?? 0) > nowMs) continue;
      _setActivity('Fetching artwork…');
      final owners = [...f.owners]..sort((a, b) =>
          (online.contains(b) ? 1 : 0) - (online.contains(a) ? 1 : 0));
      Object? failure;
      for (final owner in owners.take(2)) {
        try {
          final path = await _api.fetchArt(agentId: owner, sha256: f.sha256);
          final file = File(path);
          final bytes = await file.readAsBytes();
          dir.createSync(recursive: true);
          target.writeAsBytesSync(bytes, flush: true);
          try {
            file.deleteSync();
          } catch (_) {}
          fetched++;
          _artFailures.remove(f.sha256);
          failure = null;
          break;
        } catch (e) {
          failure = e;
        }
      }
      if (failure != null) {
        _artFetchFailed(f.sha256, nowMs);
        _problems.add('Artwork "${f.name}" could not be fetched: $failure');
        debugPrint('mywatch sync: artwork ${f.sha256} fetch failed: $failure');
      }
    }
    if (fetched > 0) MetadataService.instance.notifyExternalSeed();
    return fetched;
  }

  /// TMDB-named artwork files any found cache row references — the set
  /// worth pulling (user `user_` files ride the meta-row flow instead).
  Future<Set<String>> _referencedArtFiles() async {
    final db = await LibraryStore.database();
    final rows = await (db.select(db.metadataCache)
          ..where((t) => t.found.equals(true)))
        .get();
    return {
      for (final r in rows)
        for (final name in [r.posterFile, r.stillFile, r.showPosterFile])
          if (name != null && !name.startsWith('user_')) name,
    };
  }

  // ---- pure merge/publish logic (unit-tested directly) ------------------

  /// `title(lower) → address(lower) → added_ms` for the whole library.
  /// A pre-column add time of 0/null publishes as 1, so any real
  /// tombstone beats it. Channel lists are not the device's own content
  /// — they mirror a channel manifest and sync as *subscriptions* (the
  /// doc's `channels` section), so they stay out of the personal
  /// membership entirely. (On upgrade, a channel list vanishing from
  /// this snapshot tombstones the badge-less copies older builds synced
  /// — deliberate cleanup.)
  static Map<String, Map<String, int>> membershipOf(List<MediaList> lists) => {
        for (final l in lists)
          if (!l.isChannel)
            l.title.toLowerCase(): {
              for (final e in l.entries)
                e.address.toLowerCase():
                    (e.addedAt == null || e.addedAt == 0) ? 1 : e.addedAt!,
            },
      };

  /// Splits an episode lookup key (`tv:title:year:sN:eM`) into its show
  /// key (group 1) and season number (group 2).
  static final episodeKeyPattern = RegExp(r'^(.+):s(\d+):e\d+$');

  /// The lookup keys the library's entries resolve under — the keys
  /// whose metadata is worth syncing. Channel entries are excluded:
  /// their metadata travels inside the channel manifest itself.
  static Set<String> libraryLookupKeys(List<MediaList> lists) => {
        for (final l in lists)
          if (!l.isChannel)
            for (final e in l.entries) parseMediaName(e.name).lookupKey,
      };

  /// Backoff before retrying a failed artwork fetch: 1 min after the
  /// first failure, doubling to the [mapRetryMs] cap. The first fetch
  /// right after a link comes up routinely fails with "agent not
  /// found" (x0x key material still exchanging) — a flat 10-minute
  /// wait there made first-link artwork look broken.
  static int artRetryDelayMs(int failures) {
    final delay = 60000 * (1 << (failures - 1).clamp(0, 10));
    return delay > mapRetryMs ? mapRetryMs : delay;
  }

  /// Record an artwork fetch failure and stamp the next-allowed retry.
  void _artFetchFailed(String sha256, int nowMs) {
    final n = (_artFailures[sha256] ?? 0) + 1;
    _artFailures[sha256] = n;
    _artRetryAt[sha256] = nowMs + artRetryDelayMs(n);
  }

  /// 8-hex FNV-1a of a lookup key — the compact element of the doc's
  /// `have` list (full keys would cost ~4× the bytes; a 32-bit clash
  /// merely leaves one title's metadata unpublished).
  static String metaKeyHash(String key) {
    var h = 0x811c9dc5;
    for (final c in key.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  /// Only plain file names may be written into the posters dir on a
  /// linked device's say-so — no separators, nothing dot-led.
  static bool safeArtFileName(String name) =>
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,150}$').hasMatch(name) &&
      !name.contains('..');

  /// The newest remote TMDB row per lookup key across every device's
  /// `tmdb` section, with the show/season shared texts resolved back
  /// onto each row and unsafe artwork file names dropped.
  static List<RemoteTmdbRow> remoteTmdbWinners(List<RemoteSyncDoc> remote) {
    final best = <String, RemoteTmdbRow>{};
    for (final d in remote) {
      final tmdb = d.doc['tmdb'];
      if (tmdb is! Map<String, dynamic>) continue;
      final shows = tmdb['shows'] is Map<String, dynamic>
          ? tmdb['shows'] as Map<String, dynamic>
          : const <String, dynamic>{};
      final seasons = tmdb['seasons'] is Map<String, dynamic>
          ? tmdb['seasons'] as Map<String, dynamic>
          : const <String, dynamic>{};
      String? file(dynamic v) => v is String && safeArtFileName(v) ? v : null;
      for (final r in tmdb['rows'] is List ? tmdb['rows'] as List : const []) {
        if (r is! Map<String, dynamic>) continue;
        final key = r['key'] as String? ?? '';
        final updatedMs = r['updated_ms'] as int? ?? 0;
        if (key.isEmpty || updatedMs <= 0) continue;
        Map<String, dynamic>? show;
        Map<String, dynamic>? season;
        final ep = episodeKeyPattern.firstMatch(key);
        if (ep != null) {
          final showKey = ep.group(1)!;
          show = shows[showKey] is Map<String, dynamic>
              ? shows[showKey] as Map<String, dynamic>
              : null;
          final s = seasons['$showKey:s${ep.group(2)}'];
          season = s is Map<String, dynamic> ? s : null;
        }
        final row = RemoteTmdbRow(
          agentId: d.agentId,
          key: key,
          updatedMs: updatedMs,
          title: r['title'] as String?,
          year: r['year'] as int?,
          overview: r['overview'] as String?,
          category: r['category'] as String?,
          episodeLabel: r['episode'] as String?,
          mediaType: r['type'] as String?,
          tmdbId: r['tmdb_id'] as int?,
          rating: (r['rating'] as num?)?.toDouble(),
          airDate: r['air_date'] as String?,
          posterFile: file(r['poster']),
          stillFile: file(r['still']),
          showOverview: show?['overview'] as String?,
          seasonOverview: season?['overview'] as String?,
          showPosterFile: file(show?['poster']),
        );
        final cur = best[key];
        if (cur == null || row.updatedMs > cur.updatedMs) best[key] = row;
      }
    }
    return best.values.toList();
  }

  /// Every artwork file the remote `tmdb` sections manifest, with the
  /// devices that can serve it. The first-seen manifest pins a file's
  /// hash; a device naming the same file with different bytes is not a
  /// valid owner of this one.
  static Map<String, RemoteArtFile> remoteTmdbFiles(
      List<RemoteSyncDoc> remote) {
    final out = <String, RemoteArtFile>{};
    for (final d in remote) {
      final tmdb = d.doc['tmdb'];
      if (tmdb is! Map<String, dynamic>) continue;
      final files = tmdb['files'];
      if (files is! Map<String, dynamic>) continue;
      for (final e in files.entries) {
        final m = e.value;
        if (!safeArtFileName(e.key) || m is! Map<String, dynamic>) continue;
        final sha = (m['sha256'] as String? ?? '').toLowerCase();
        if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) continue;
        final cur = out[e.key];
        if (cur == null) {
          out[e.key] = RemoteArtFile(
            name: e.key,
            sha256: sha,
            size: m['size'] as int? ?? 0,
            owners: [d.agentId],
          );
        } else if (cur.sha256 == sha) {
          cur.owners.add(d.agentId);
        }
      }
    }
    return out;
  }

  /// [tmdb] with the oldest quarter of its rows dropped and the shared
  /// shows/seasons texts and file manifests pruned to what the kept
  /// rows still reference; null once nothing is left. The budget loop's
  /// trim step — dropped rows return in a later cycle, once applied
  /// rows have joined the receivers' `have` lists and shrunk the
  /// section.
  static Map<String, dynamic>? shrunkenTmdbSection(Map<String, dynamic> tmdb) {
    final rows = (tmdb['rows'] as List? ?? const []).cast<Map<String, dynamic>>();
    final keep =
        rows.length - (rows.length / 4).ceil().clamp(1, rows.length);
    if (keep <= 0) return null;
    final kept = rows.sublist(0, keep);
    final srcShows = tmdb['shows'] as Map<String, dynamic>? ?? const {};
    final srcSeasons = tmdb['seasons'] as Map<String, dynamic>? ?? const {};
    final srcFiles = tmdb['files'] as Map<String, dynamic>? ?? const {};
    final shows = <String, dynamic>{};
    final seasons = <String, dynamic>{};
    final files = <String, dynamic>{};
    void keepFile(dynamic name) {
      if (name is String && srcFiles.containsKey(name)) {
        files[name] = srcFiles[name];
      }
    }

    for (final r in kept) {
      keepFile(r['poster']);
      keepFile(r['still']);
      final ep = episodeKeyPattern.firstMatch(r['key'] as String? ?? '');
      if (ep == null) continue;
      final showKey = ep.group(1)!;
      final seasonKey = '$showKey:s${ep.group(2)}';
      if (srcShows[showKey] case final Map<String, dynamic> show) {
        shows[showKey] = show;
        keepFile(show['poster']);
      }
      if (srcSeasons.containsKey(seasonKey)) {
        seasons[seasonKey] = srcSeasons[seasonKey];
      }
    }
    return {
      'v': 1,
      'rows': kept,
      if (shows.isNotEmpty) 'shows': shows,
      if (seasons.isNotEmpty) 'seasons': seasons,
      if (files.isNotEmpty) 'files': files,
    };
  }

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
    List<String> haveHashes = const [],
    Map<String, dynamic>? tmdbSection,
    Map<String, ChannelSyncSub> channelSubs = const {},
    Map<String, int> channelStones = const {},
  }) {
    var entryBudget = maxDocEntries;
    final listDocs = <Map<String, dynamic>>[];
    for (final l in lists) {
      // Channel lists sync as subscriptions (`channels` below), never as
      // copies of their content.
      if (l.isChannel) continue;
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
    final held = {
      for (final l in lists)
        if (!l.isChannel) l.title.toLowerCase(),
    };
    for (final e in tombstones.entries) {
      if (held.contains(e.key) || e.value.isEmpty) continue;
      listDocs.add({'title': e.key, 'entries': const [], 'removed': e.value});
    }
    return {
      'v': 1,
      'updated_ms': nowMs,
      'lists': listDocs,
      // Always published, even empty: its presence tells linked devices
      // this build understands TMDB metadata sync at all.
      'have': haveHashes,
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
      'tmdb': ?tmdbSection,
      // Channel subscriptions (own channel included, announced by its
      // creator): the receiving device subscribes by code, so the
      // channel arrives amber-badged and auto-updating.
      if (channelSubs.isNotEmpty || channelStones.isNotEmpty)
        'channels': {
          if (channelSubs.isNotEmpty)
            'subs': {
              for (final e in channelSubs.entries)
                e.key: {'code': e.value.code, 'added_ms': e.value.addedMs},
            },
          if (channelStones.isNotEmpty) 'removed': channelStones,
        },
    };
  }

  /// [buildDoc] kept under [maxDocBytes]: when the doc is over budget,
  /// watch states drop first (stalest-played last quarter per round — a
  /// stale resume point is the cheapest loss and returns once the doc
  /// has room), then the TMDB section shrinks (it self-heals: applied
  /// rows join the receivers' `have` lists and stop being needed), and
  /// the user's detail edits drop only when nothing else is left.
  /// Before this reprioritisation a long viewing history (300 states ≈
  /// 45 KB alone) could permanently crowd every detail edit out of the
  /// doc while list entries kept syncing fine — the "publishes sync,
  /// edits don't" failure. [watchStates] must arrive newest-first (the
  /// store's order).
  static ({
    Map<String, dynamic> doc,
    int watchDropped,
    int metaDropped,
    int tmdbDropped,
  }) buildDocWithinBudget({
    required List<MediaList> lists,
    required Map<String, Map<String, int>> tombstones,
    required List<WatchState> watchStates,
    required int nowMs,
    List<Map<String, dynamic>> metaRows = const [],
    List<String> haveHashes = const [],
    Map<String, dynamic>? tmdbSection,
    Map<String, ChannelSyncSub> channelSubs = const {},
    Map<String, int> channelStones = const {},
  }) {
    final tmdbRows = (tmdbSection?['rows'] as List?)?.length ?? 0;
    var watch = watchStates;
    var meta = metaRows;
    var tmdb = tmdbSection;
    Map<String, dynamic> build() => buildDoc(
          lists: lists,
          tombstones: tombstones,
          watchStates: watch,
          nowMs: nowMs,
          metaRows: meta,
          haveHashes: haveHashes,
          tmdbSection: tmdb,
          channelSubs: channelSubs,
          channelStones: channelStones,
        );
    var doc = build();
    while (jsonEncode(doc).length > maxDocBytes) {
      if (watch.isNotEmpty) {
        watch = watch.sublist(
            0, watch.length - (watch.length / 4).ceil().clamp(1, watch.length));
      } else if (tmdb != null) {
        tmdb = shrunkenTmdbSection(tmdb);
      } else if (meta.isNotEmpty) {
        // Newest-first order, so the oldest edit drops first.
        meta = meta.sublist(0, meta.length - 1);
      } else {
        break;
      }
      doc = build();
    }
    return (
      doc: doc,
      watchDropped: watchStates.length - watch.length,
      metaDropped: metaRows.length - meta.length,
      tmdbDropped: tmdbRows - ((tmdb?['rows'] as List?)?.length ?? 0),
    );
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
          // A channel list mirrors its manifest — remote personal lists
          // (e.g. an older build's badge-less copy) never merge into it.
          if (i != -1 && out[i].isChannel) continue;
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
      if (out[i].isChannel) continue; // immune to personal tombstones
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

  static final _channelPubkeyPattern = RegExp(r'^[0-9a-f]{64}$');
  static final _channelCodePattern = RegExp(r'^wchn1-[a-z0-9]{1,120}$');

  /// Actions implied by the remote docs' `channels` sections: per pubkey
  /// the newest add (subscribe, anywhere) races the newest unsubscribe
  /// tombstone, ties going to the tombstone — the same LWW the list
  /// entries use. This device's own channel is skipped (it is the owner
  /// there, not a subscriber); remote tombstones newer than ours are
  /// adopted so they keep propagating.
  static ChannelSyncActions channelActions({
    required Map<String, ChannelSyncSub> localSubs,
    required Map<String, int> localStones,
    required String? ownPubkey,
    required List<RemoteSyncDoc> remote,
  }) {
    final bestAdd = <String, ChannelSyncSub>{};
    final remoteStones = <String, int>{};
    for (final d in remote) {
      final section = d.doc['channels'];
      if (section is! Map<String, dynamic>) continue;
      final subs = section['subs'];
      if (subs is Map<String, dynamic>) {
        for (final e in subs.entries) {
          final pubkey = e.key.toLowerCase();
          final v = e.value;
          if (v is! Map<String, dynamic>) continue;
          final code = (v['code'] as String? ?? '').toLowerCase();
          final addedMs = v['added_ms'] as int? ?? 0;
          if (!_channelPubkeyPattern.hasMatch(pubkey) ||
              !_channelCodePattern.hasMatch(code) ||
              addedMs <= 0) {
            continue;
          }
          final cur = bestAdd[pubkey];
          if (cur == null || addedMs > cur.addedMs) {
            bestAdd[pubkey] = ChannelSyncSub(code: code, addedMs: addedMs);
          }
        }
      }
      final removed = section['removed'];
      if (removed is Map<String, dynamic>) {
        for (final e in removed.entries) {
          final pubkey = e.key.toLowerCase();
          final ms = e.value as int? ?? 0;
          if (!_channelPubkeyPattern.hasMatch(pubkey) || ms <= 0) continue;
          if (ms > (remoteStones[pubkey] ?? 0)) remoteStones[pubkey] = ms;
        }
      }
    }
    int stoneFor(String pubkey) {
      final r = remoteStones[pubkey] ?? 0;
      final l = localStones[pubkey] ?? 0;
      return r > l ? r : l;
    }

    final subscribe = <ChannelSyncSubscribe>[];
    for (final e in bestAdd.entries) {
      final pubkey = e.key;
      if (pubkey == ownPubkey || localSubs.containsKey(pubkey)) continue;
      if (e.value.addedMs > stoneFor(pubkey)) {
        subscribe.add(ChannelSyncSubscribe(
          pubkey: pubkey,
          code: e.value.code,
          addedMs: e.value.addedMs,
        ));
      }
    }
    final unsubscribe = <String, int>{};
    for (final e in localSubs.entries) {
      final pubkey = e.key;
      if (pubkey == ownPubkey) continue;
      final remoteAdd = bestAdd[pubkey]?.addedMs ?? 0;
      final newestAdd =
          remoteAdd > e.value.addedMs ? remoteAdd : e.value.addedMs;
      final stone = stoneFor(pubkey);
      if (stone >= newestAdd) unsubscribe[pubkey] = stone;
    }
    return ChannelSyncActions(
      subscribe: subscribe,
      unsubscribe: unsubscribe,
      stones: {
        for (final e in remoteStones.entries)
          if (e.value > (localStones[e.key] ?? 0)) e.key: e.value,
      },
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

/// One remote device's TMDB metadata row after the cross-device
/// newest-wins pass, show/season shared texts already resolved — ready
/// to fill a gap in the local cache.
class RemoteTmdbRow {
  const RemoteTmdbRow({
    required this.agentId,
    required this.key,
    required this.updatedMs,
    this.title,
    this.year,
    this.overview,
    this.category,
    this.episodeLabel,
    this.mediaType,
    this.tmdbId,
    this.rating,
    this.airDate,
    this.posterFile,
    this.stillFile,
    this.showOverview,
    this.seasonOverview,
    this.showPosterFile,
  });

  final String agentId;
  final String key;
  final int updatedMs;
  final String? title;
  final int? year;
  final String? overview;
  final String? category;
  final String? episodeLabel;
  final String? mediaType;
  final int? tmdbId;
  final double? rating;
  final String? airDate;

  /// TMDB file names in the posters dir (for episode rows [posterFile]
  /// is the season-art slot, exactly as the origin device stored it);
  /// the bytes ride the artwork transfer, keyed by the doc's manifest.
  final String? posterFile;
  final String? stillFile;
  final String? showPosterFile;
  final String? showOverview;
  final String? seasonOverview;
}

/// One artwork file some linked device can serve: its manifest plus the
/// devices whose docs published it.
class RemoteArtFile {
  RemoteArtFile({
    required this.name,
    required this.sha256,
    required this.size,
    required this.owners,
  });

  final String name;
  final String sha256;
  final int size;
  final List<String> owners;
}

/// Snapshot of the background sync for indicator UIs (the My W@tch
/// screen's activity card, the home status bar segment). Published on
/// [MyWatchSync.status] at every cycle boundary and stage change.
class MyWatchSyncStatus {
  const MyWatchSyncStatus({
    this.supported = false,
    this.linked = false,
    this.agentState = 'off',
    this.lastSyncMs,
    this.syncing = false,
    this.activity,
    this.lastCycleAtMs,
    this.lastSummary,
    this.problems = const [],
  });

  /// My W@tch exists in this build (false on iOS, and until the first
  /// cycle has asked the embedded client).
  final bool supported;
  final bool linked;

  /// The x0x agent: `off`, `starting`, or `ready`.
  final String agentState;

  /// When another device's record last changed under us (embedded
  /// client's stamp); null when it has never happened.
  final int? lastSyncMs;

  /// A sync cycle is running right now.
  final bool syncing;

  /// What the running cycle is doing, user-readable; null when idle.
  final String? activity;

  /// When the last cycle finished, and its one-line outcome.
  final int? lastCycleAtMs;
  final String? lastSummary;

  /// What went wrong (or could not fit) in the last cycle.
  final List<String> problems;
}

class SyncCycleResult {
  const SyncCycleResult({
    this.entriesAdded = 0,
    this.entriesRemoved = 0,
    this.watchStatesApplied = 0,
    this.mapsImported = 0,
    this.detailsApplied = 0,
    this.tmdbApplied = 0,
    this.artFetched = 0,
    this.channelsChanged = 0,
  });

  final int entriesAdded;
  final int entriesRemoved;
  final int watchStatesApplied;
  final int mapsImported;
  final int detailsApplied;
  final int tmdbApplied;
  final int artFetched;
  final int channelsChanged;

  SyncCycleResult copyWith({
    int? watchStatesApplied,
    int? mapsImported,
    int? detailsApplied,
    int? tmdbApplied,
    int? artFetched,
    int? channelsChanged,
  }) =>
      SyncCycleResult(
        entriesAdded: entriesAdded,
        entriesRemoved: entriesRemoved,
        watchStatesApplied: watchStatesApplied ?? this.watchStatesApplied,
        mapsImported: mapsImported ?? this.mapsImported,
        detailsApplied: detailsApplied ?? this.detailsApplied,
        tmdbApplied: tmdbApplied ?? this.tmdbApplied,
        artFetched: artFetched ?? this.artFetched,
        channelsChanged: channelsChanged ?? this.channelsChanged,
      );
}

/// One channel another device subscribed to that this device should
/// subscribe to as well.
class ChannelSyncSubscribe {
  const ChannelSyncSubscribe({
    required this.pubkey,
    required this.code,
    required this.addedMs,
  });

  final String pubkey;
  final String code;
  final int addedMs;
}

/// What [MyWatchSync.channelActions] decided: subscriptions to add,
/// subscriptions to drop (`pubkey → the winning tombstone's ms`), and
/// remote tombstones to adopt locally.
class ChannelSyncActions {
  const ChannelSyncActions({
    this.subscribe = const [],
    this.unsubscribe = const {},
    this.stones = const {},
  });

  final List<ChannelSyncSubscribe> subscribe;
  final Map<String, int> unsubscribe;
  final Map<String, int> stones;

  bool get isEmpty =>
      subscribe.isEmpty && unsubscribe.isEmpty && stones.isEmpty;
}
