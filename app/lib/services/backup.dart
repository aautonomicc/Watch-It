import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'embedded_client.dart';
import 'library_store.dart';
import 'metadata_service.dart';
import 'my_watch_api.dart';
import 'my_watch_sync.dart';
import 'profile_sync.dart';
import 'profiles.dart';
import 'user_metadata.dart';
import 'watch_state.dart';

/// Seed-phrase backup (phase 1 of the adopted 2026-10-06 plan): the
/// FULL W@tch state — lists + entries, root data maps, user edits,
/// TMDB rows, posters/art, watch states, profiles — published to
/// Autonomi under keys the native side derives from the upload wallet's
/// private key (which the 12 words reproduce). Restore works on a fresh
/// install from the words alone: reading the network is free, so no
/// funded wallet and no linked device is needed.
///
/// Division of labour: this service ASSEMBLES the state (reusing the
/// My W@tch sync-document shape, so the restore side reuses the exact
/// sync merge machinery) and APPLIES a restored document; the native
/// side owns derivation, deterministic encryption, the object store,
/// the head chunk and the pointer (`native/watchit_core/src/backup.rs`).

/// Client for the embedded server's backup routes (token-guarded:
/// backups spend ANT and the pointer identifies the user's backup).
class BackupApi {
  BackupApi({String? base, String? token})
      : _baseOverride = base,
        _tokenOverride = token;

  final String? _baseOverride;
  final String? _tokenOverride;

  String get _base {
    final base = _baseOverride ?? EmbeddedClient.baseUrl();
    if (base == null) {
      throw BackupException('the embedded client is not running');
    }
    return base.replaceFirst(RegExp(r'/+$'), '');
  }

  Map<String, String> get _headers {
    final token = _tokenOverride ?? EmbeddedClient.authToken();
    return {
      'content-type': 'application/json',
      'x-watchit-auth': ?token,
    };
  }

  Future<Map<String, dynamic>> _request(String method, String path,
      {Object? body}) async {
    final client = http.Client();
    try {
      final uri = Uri.parse('$_base$path');
      final http.Response res = switch (method) {
        'GET' => await client.get(uri, headers: _headers),
        'POST' => await client.post(uri,
            headers: _headers, body: body == null ? null : jsonEncode(body)),
        _ => throw ArgumentError(method),
      };
      if (res.statusCode != 200) {
        throw BackupException(res.body.trim().isEmpty
            ? 'request failed (${res.statusCode})'
            : res.body.trim());
      }
      return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } on BackupException {
      rethrow;
    } catch (e) {
      throw BackupException('could not reach the embedded client: $e');
    } finally {
      client.close();
    }
  }

  Future<BackupStatus> status() async =>
      BackupStatus.fromJson(await _request('GET', '/backup'));

  Future<void> run(Map<String, dynamic> payload) =>
      _request('POST', '/backup/run', body: payload);

  Future<void> restoreStart({String? key, required String artDir}) =>
      _request('POST', '/backup/restore', body: {
        'key': ?key,
        'art_dir': artDir,
      });

  /// One free pointer read: does a backup exist under [ptr], and which
  /// head chunk does it target? The follower's cheap no-change check.
  Future<BackupPeek> peek(String ptr) async {
    final json = await _request('POST', '/backup/peek', body: {'ptr': ptr});
    return (
      found: json['found'] as bool? ?? false,
      head: json['head'] as String?,
    );
  }

  /// Start a follow fetch of another device's backup with its shared
  /// read keys (job kind `follow`; free — reads only, no wallet here).
  Future<void> followStart({
    required String ptr,
    required String key,
    required String artDir,
  }) =>
      _request('POST', '/backup/follow', body: {
        'ptr': ptr,
        'key': key,
        'art_dir': artDir,
      });
}

typedef BackupPeek = ({bool found, String? head});

class BackupException implements Exception {
  BackupException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// `GET /backup` — identity, last backup, and the running/finished job.
class BackupStatus {
  const BackupStatus({
    required this.configured,
    this.pointer,
    this.key,
    this.last,
    this.job,
  });

  factory BackupStatus.fromJson(Map<String, dynamic> json) => BackupStatus(
        configured: json['configured'] as bool? ?? false,
        pointer: json['pointer'] as String?,
        key: json['key'] as String?,
        last: json['last'] is Map<String, dynamic>
            ? BackupLast.fromJson(json['last'] as Map<String, dynamic>)
            : null,
        job: json['job'] is Map<String, dynamic>
            ? BackupJob.fromJson(json['job'] as Map<String, dynamic>)
            : null,
      );

  /// Whether a wallet (and so a backup identity) exists on this device.
  final bool configured;
  final String? pointer;

  /// The derived content READ key (hex) — with [pointer] it is what a
  /// master shares over My W@tch so linked devices can follow its
  /// backups. Never the wallet key; it cannot spend anything.
  final String? key;
  final BackupLast? last;
  final BackupJob? job;
}

/// The last successful backup from THIS device (local record).
class BackupLast {
  const BackupLast({
    required this.ms,
    required this.backups,
    required this.objects,
    required this.uploaded,
  });

  factory BackupLast.fromJson(Map<String, dynamic> json) => BackupLast(
        ms: json['ms'] as int? ?? 0,
        backups: json['backups'] as int? ?? 0,
        objects: json['objects'] as int? ?? 0,
        uploaded: json['uploaded'] as int? ?? 0,
      );

  final int ms;
  final int backups;
  final int objects;
  final int uploaded;
}

class BackupJob {
  const BackupJob({
    required this.kind,
    required this.phase,
    required this.done,
    required this.total,
    this.error,
    this.result,
  });

  factory BackupJob.fromJson(Map<String, dynamic> json) => BackupJob(
        kind: json['kind'] as String? ?? '',
        phase: json['phase'] as String? ?? '',
        done: json['done'] as int? ?? 0,
        total: json['total'] as int? ?? 0,
        error: json['error'] as String?,
        result: json['result'] as Map<String, dynamic>?,
      );

  /// `backup` or `restore`.
  final String kind;
  final String phase;
  final int done;
  final int total;
  final String? error;
  final Map<String, dynamic>? result;

  bool get finished => phase == 'done' || phase == 'error';

  /// A short progress line for the screen.
  String get label => switch (phase) {
        'deriving' => 'Preparing…',
        'packing' => 'Packing your library…',
        'uploading' =>
          'Uploading changes… ${total == 0 ? '' : '($done of $total)'}',
        'manifest' || 'head' || 'pointer' => 'Finishing the backup…',
        'locating' => 'Looking up the backup…',
        'fetching' =>
          'Fetching the backup… ${total == 0 ? '' : '($done of $total)'}',
        'importing' => 'Importing data maps…',
        'done' => 'Done.',
        'error' => 'Failed.',
        _ => phase,
      };
}

/// What [BackupService.runBackup] published.
class BackupRunSummary {
  const BackupRunSummary({
    required this.objects,
    required this.uploaded,
    required this.backups,
    required this.mapsMissing,
  });
  final int objects;
  final int uploaded;
  final int backups;
  final int mapsMissing;
}

/// What a restore merged into this device.
class RestoreSummary {
  const RestoreSummary({
    this.head,
    required this.createdMs,
    required this.entriesAdded,
    required this.watchApplied,
    required this.profilesChanged,
    required this.detailsApplied,
    required this.tmdbApplied,
    required this.mapsImported,
    required this.artInstalled,
    required this.problems,
  });

  /// The backup head chunk this fetch walked (hex) — the follower
  /// records it so its next peek can skip an unchanged backup.
  final String? head;
  final int createdMs;
  final int entriesAdded;
  final int watchApplied;
  final int profilesChanged;
  final int detailsApplied;
  final int tmdbApplied;
  final int mapsImported;
  final int artInstalled;
  final List<String> problems;
}

class BackupService {
  BackupService({BackupApi? api, this.pollInterval = _defaultPoll})
      : _api = api ?? BackupApi();

  static BackupService instance = BackupService();

  final BackupApi _api;
  final Duration pollInterval;
  static const _defaultPoll = Duration(seconds: 1);

  /// For tests: pins the posters directory somewhere writable.
  @visibleForTesting
  static Future<Directory> Function()? postersDirOverride;

  /// For tests: pins the restore-art staging directory.
  @visibleForTesting
  static Future<Directory> Function()? stagingDirOverride;

  Future<BackupStatus> status() => _api.status();

  static Future<Directory> _postersDir() =>
      (postersDirOverride ?? defaultPostersDir)();

  static Future<Directory> _stagingDir() async {
    if (stagingDirOverride != null) return stagingDirOverride!();
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/backup_restore_art');
  }

  // ---- payload assembly -------------------------------------------------

  /// The full backup payload: the state document (the My W@tch sync-doc
  /// shape, UNBUDGETED — every entry, every watch state, every edit),
  /// the artwork files it references, and every entry address whose
  /// root map should ride along.
  Future<Map<String, dynamic>> buildPayload() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final lists = await LibraryStore.load();
    final dir = await _postersDir();
    final artByName = <String, String>{}; // file name → absolute path
    final artInfoCache = <String, ({String sha256, int size})?>{};

    Future<({String sha256, int size})?> posterInfo(String name) async {
      if (artInfoCache.containsKey(name)) return artInfoCache[name];
      final file = File('${dir.path}/$name');
      ({String sha256, int size})? info;
      if (file.existsSync()) {
        final bytes = await file.readAsBytes();
        if (bytes.length <= MyWatchSync.maxArtBytes) {
          info = (
            sha256: crypto.sha256.convert(bytes).toString(),
            size: bytes.length
          );
        }
      }
      artInfoCache[name] = info;
      return info;
    }

    void wantArt(String? name) {
      if (name == null || name.isEmpty) return;
      artByName.putIfAbsent(name, () => '${dir.path}/$name');
    }

    // User detail edits, with their artwork manifests.
    final db = await LibraryStore.database();
    final editedRows = await (db.select(db.metadataCache)
          ..where((t) => t.userEdited.equals(true)))
        .get();
    editedRows.sort((a, b) => b.fetchedAt.compareTo(a.fetchedAt));
    final artByFile = <String, ({String sha256, int size})>{};
    for (final r in editedRows) {
      final poster = r.posterFile;
      if (poster == null || !poster.startsWith('user_')) continue;
      final info = await posterInfo(poster);
      if (info != null) {
        artByFile[poster] = info;
        wantArt(poster);
      }
    }
    final metaRows = MyWatchSync.metaRowsFrom(editedRows, artByFile);

    // TMDB metadata for every library key — the backup twin of the
    // sync's need-based `tmdb` section, so a keyless restored install
    // still shows posters and descriptions.
    final libKeys = MyWatchSync.libraryLookupKeys(lists);
    final tmdbSection = await _fullTmdbSection(libKeys, posterInfo, wantArt);

    // Profiles (per-profile watch points included, uncapped).
    Map<String, dynamic>? profilesSection;
    try {
      profilesSection = await buildLocalProfilesSection(
        lists: lists,
        nowMs: now,
        avatarInfo: posterInfo,
        tombstoneTtlMs: MyWatchSync.tombstoneTtlMs,
        maxWatchStatesPerProfile: 1 << 30,
      );
      for (final p in ProfileStore.instance.profiles) {
        final avatar = p.avatar;
        if (avatar != null && !avatar.startsWith('preset:')) {
          if (await posterInfo(avatar) != null) wantArt(avatar);
        }
      }
    } catch (e) {
      debugPrint('backup: profiles section failed: $e');
    }

    var totalEntries = 0;
    for (final l in lists) {
      totalEntries += l.entries.length;
    }
    final watch =
        await WatchStateStore.instance.all(profileId: kAdminProfileId);
    final doc = MyWatchSync.buildDoc(
      lists: lists,
      tombstones: const {},
      watchStates: watch,
      nowMs: now,
      metaRows: metaRows,
      haveHashes: const [],
      tmdbSection: tmdbSection,
      profilesSection: profilesSection,
      entryCap: totalEntries,
    );
    // buildDoc caps watch states for the sync-doc byte budget; a backup
    // has no budget — carry them all.
    doc['watch'] = [
      for (final s in watch)
        {
          'address': s.address,
          'pos_ms': s.positionMs,
          'dur_ms': s.durationMs,
          'completed': s.completed,
          'updated_ms': s.updatedAt,
        },
    ];

    final mapAddrs = <String>{
      for (final l in lists)
        for (final e in l.entries) e.address.toLowerCase(),
    };
    return {
      'doc': doc,
      'art': [
        for (final e in artByName.entries) {'file': e.key, 'path': e.value},
      ],
      'map_addrs': [...mapAddrs],
    };
  }

  /// All-rows version of the sync's `tmdb` section (same shape, so the
  /// restore side applies it through the same code).
  Future<Map<String, dynamic>?> _fullTmdbSection(
    Set<String> libKeys,
    Future<({String sha256, int size})?> Function(String) posterInfo,
    void Function(String?) wantArt,
  ) async {
    final db = await LibraryStore.database();
    final all = await (db.select(db.metadataCache)
          ..where((t) => t.found.equals(true)))
        .get();
    final rows = [
      for (final r in all)
        if (!r.userEdited && libKeys.contains(r.lookupKey)) r,
    ]..sort((a, b) => b.fetchedAt.compareTo(a.fetchedAt));
    if (rows.isEmpty) return null;

    final out = <Map<String, dynamic>>[];
    final shows = <String, dynamic>{};
    final seasons = <String, dynamic>{};
    final files = <String, dynamic>{};
    Future<void> addFile(String? name) async {
      if (name == null || name.startsWith('user_')) return;
      if (files.containsKey(name)) return;
      final info = await posterInfo(name);
      if (info == null) return;
      files[name] = {'sha256': info.sha256, 'size': info.size};
      wantArt(name);
    }

    for (final r in rows) {
      out.add({
        'key': r.lookupKey,
        'updated_ms': r.fetchedAt,
        if (r.title != null) 'title': r.title,
        if (r.year != null) 'year': r.year,
        if (r.overview != null) 'overview': r.overview,
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
      final ep = MyWatchSync.episodeKeyPattern.firstMatch(r.lookupKey);
      if (ep == null) continue;
      final showKey = ep.group(1)!;
      final seasonKey = '$showKey:s${ep.group(2)}';
      if (!shows.containsKey(showKey) &&
          (r.showOverview != null || r.showPosterFile != null)) {
        shows[showKey] = {
          if (r.showOverview != null) 'overview': r.showOverview,
          if (r.showPosterFile != null) 'poster': r.showPosterFile,
        };
        await addFile(r.showPosterFile);
      }
      if (!seasons.containsKey(seasonKey) && r.seasonOverview != null) {
        seasons[seasonKey] = {'overview': r.seasonOverview};
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

  // ---- backup -------------------------------------------------------------

  /// Called after every successful backup with the published payload's
  /// [payloadFingerprint] — the auto-backup scheduler stores it so an
  /// unchanged state never pays for a redundant backup.
  static void Function(String fingerprint)? onBackupPublished;

  /// A stable digest of a backup payload's content: the state document
  /// (minus its build stamp — two payloads of identical state must
  /// fingerprint identically), the art manifest and the map addresses.
  static String payloadFingerprint(Map<String, dynamic> payload) {
    final doc = {
      for (final e
          in (payload['doc'] as Map<String, dynamic>? ?? const {}).entries)
        if (e.key != 'updated_ms') e.key: e.value,
    };
    final body = jsonEncode({
      'doc': doc,
      'art': payload['art'],
      'map_addrs': payload['map_addrs'],
    });
    return crypto.sha256.convert(utf8.encode(body)).toString();
  }

  /// Build the payload (unless one is handed in), start the backup, and
  /// wait it out. [onProgress] gets every polled job state.
  Future<BackupRunSummary> runBackup(
      {Map<String, dynamic>? payload,
      void Function(BackupJob job)? onProgress}) async {
    payload ??= await buildPayload();
    await _api.run(payload);
    final job = await _awaitJob('backup', onProgress);
    final result = job.result ?? const {};
    try {
      onBackupPublished?.call(payloadFingerprint(payload));
    } catch (e) {
      debugPrint('backup: fingerprint hook failed: $e');
    }
    return BackupRunSummary(
      objects: result['objects'] as int? ?? 0,
      uploaded: result['uploaded'] as int? ?? 0,
      backups: result['backups'] as int? ?? 0,
      mapsMissing: result['maps_missing'] as int? ?? 0,
    );
  }

  Future<BackupJob> _awaitJob(
      String kind, void Function(BackupJob job)? onProgress) async {
    while (true) {
      await Future<void>.delayed(pollInterval);
      final status = await _api.status();
      final job = status.job;
      if (job == null || job.kind != kind) continue;
      onProgress?.call(job);
      if (!job.finished) continue;
      if (job.phase == 'error') {
        throw BackupException(job.error ?? 'the $kind failed');
      }
      return job;
    }
  }

  // ---- restore --------------------------------------------------------------

  /// Fetch the backup (from the stored wallet, or a pasted [walletKey])
  /// and merge it into this device: lists, watch points, profiles,
  /// detail edits, TMDB metadata, artwork — through the exact My W@tch
  /// sync merge rules, so a restore never regresses newer local state.
  /// Root maps were already imported natively, so entries play.
  Future<RestoreSummary> restore(
      {String? walletKey, void Function(BackupJob job)? onProgress}) =>
      _fetchAndApply(
        'restore',
        (artDir) => _api.restoreStart(key: walletKey, artDir: artDir),
        onProgress,
      );

  /// Phase 2: fetch another device's backup with the read keys it shared
  /// over My W@tch and merge it in — the same walk and the same
  /// never-regress merge as [restore], differing only in where the keys
  /// came from. Free: no wallet on this device is needed.
  Future<RestoreSummary> followFetch({
    required String ptr,
    required String key,
    void Function(BackupJob job)? onProgress,
  }) =>
      _fetchAndApply(
        'follow',
        (artDir) => _api.followStart(ptr: ptr, key: key, artDir: artDir),
        onProgress,
      );

  /// One free pointer read against [ptr] (see [BackupApi.peek]).
  Future<BackupPeek> peek(String ptr) => _api.peek(ptr);

  Future<RestoreSummary> _fetchAndApply(
    String kind,
    Future<void> Function(String artDir) start,
    void Function(BackupJob job)? onProgress,
  ) async {
    final staging = await _stagingDir();
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    staging.createSync(recursive: true);
    try {
      await start(staging.path);
      final job = await _awaitJob(kind, onProgress);
      return await _applyRestore(job.result ?? const {}, staging);
    } finally {
      // Covers the failed-job path too — a "no backup found" must not
      // leave an empty staging dir behind.
      try {
        if (staging.existsSync()) staging.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  Future<RestoreSummary> _applyRestore(
      Map<String, dynamic> result, Directory staging) async {
    final problems = <String>[];
    final doc = result['doc'] is Map<String, dynamic>
        ? result['doc'] as Map<String, dynamic>
        : <String, dynamic>{};
    final docs = [
      RemoteSyncDoc(agentId: 'backup', doc: doc, maps: const {}),
    ];

    // Staged artwork, lazily hashed (user art + avatars match by sha).
    final stagedByName = <String, File>{};
    if (staging.existsSync()) {
      for (final f in staging.listSync()) {
        if (f is File) stagedByName[f.uri.pathSegments.last] = f;
      }
    }
    final shaCache = <String, String>{};
    Future<File?> stagedBySha(String sha256) async {
      for (final e in stagedByName.entries) {
        final known = shaCache[e.key] ??=
            crypto.sha256.convert(await e.value.readAsBytes()).toString();
        if (known == sha256) return e.value;
      }
      return null;
    }

    // 1. Lists — the LWW element-set merge (the backup doc carries the
    // master's tombstones, so deletions propagate too).
    var lists = await LibraryStore.load();
    final merge = MyWatchSync.mergeRemoteDocs(
      lists: lists,
      tombstones: const {},
      remoteDocs: [doc],
    );
    if (merge.changed) {
      lists = merge.lists;
      await LibraryStore.save(lists);
      MyWatchSync.revision.value++;
    }

    // 2. Watch points (admin) — newest-updatedAt wins, never regresses.
    var watchApplied = 0;
    try {
      watchApplied = await WatchStateStore.instance
          .mergeAll(MyWatchSync.watchStatesFromDoc(doc));
    } catch (e) {
      problems.add('Applying watch positions failed: $e');
    }

    // 3. Profiles + their watch points + avatars from staging.
    var profilesChanged = 0;
    try {
      final actions = profileActionsFrom(docs);
      if (!actions.isEmpty) {
        final apply = await applyProfileActions(
          items: actions.items,
          remoteStones: actions.stones,
          lists: lists,
        );
        profilesChanged = apply.changed;
        final watchByKey = remoteProfileWatch(docs);
        for (final e in watchByKey.entries) {
          final localId = apply.localIdByKey[e.key];
          if (localId == null || e.value.isEmpty) continue;
          watchApplied += await WatchStateStore.instance
              .mergeAll(e.value, profileId: localId);
        }
        for (final w in apply.wantedAvatars) {
          final staged = await stagedBySha(w.sha256);
          if (staged == null) continue;
          final member = await ProfileStore.saveAvatarImage(
              w.profileId, await staged.readAsBytes());
          final store = ProfileStore.instance;
          final p =
              store.profiles.where((p) => p.id == w.profileId).firstOrNull;
          if (p != null) {
            await store.updateProfile(p.copyWith(avatar: member),
                updatedMs: p.updatedMs);
          }
        }
      }
    } catch (e) {
      problems.add('Restoring profiles failed: $e');
    }

    // 4. Detail edits — LWW per row; artwork bytes from staging.
    var detailsApplied = 0;
    for (final w in MyWatchSync.remoteMetaWinners(docs)) {
      try {
        final local = await metadataRowFor(w.key);
        if (!MyWatchSync.shouldApplyRemoteRow(
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
        final art = w.art;
        if (art != null) {
          final staged = await stagedBySha(art.sha256);
          if (staged != null) {
            await applyRemotePoster(w.key, await staged.readAsBytes(),
                postersDirProvider: postersDirOverride);
          }
        }
      } catch (e) {
        problems.add('Restoring details for "${w.title ?? w.key}" failed: $e');
      }
    }

    // 5. TMDB rows (fill-only — never beats a user edit or own match),
    // then their artwork files under the original shared names.
    var tmdbApplied = 0;
    for (final w in MyWatchSync.remoteTmdbWinners(docs)) {
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
        problems.add('Restoring details for "${w.title ?? w.key}" failed: $e');
      }
    }
    var artInstalled = 0;
    try {
      final dir = await _postersDir();
      dir.createSync(recursive: true);
      for (final name in MyWatchSync.remoteTmdbFiles(docs).keys) {
        final staged = stagedByName[name];
        if (staged == null) continue;
        final target = File('${dir.path}/$name');
        if (target.existsSync()) continue;
        target.writeAsBytesSync(await staged.readAsBytes(), flush: true);
        artInstalled++;
      }
    } catch (e) {
      problems.add('Restoring artwork failed: $e');
    }
    if (artInstalled > 0) {
      MetadataService.instance.notifyExternalSeed();
    }

    final mapsFailed = result['maps_failed'] as int? ?? 0;
    if (mapsFailed > 0) {
      problems.add(
          '$mapsFailed data map(s) could not be imported — those titles '
          'need their .datamap re-imported to play');
    }
    final artFailed = result['art_failed'] as int? ?? 0;
    if (artFailed > 0) {
      problems.add('$artFailed artwork file(s) could not be fetched');
    }
    return RestoreSummary(
      head: result['head'] as String?,
      createdMs: result['created_ms'] as int? ?? 0,
      entriesAdded: merge.entriesAdded,
      watchApplied: watchApplied,
      profilesChanged: profilesChanged,
      detailsApplied: detailsApplied,
      tmdbApplied: tmdbApplied,
      mapsImported: result['maps_imported'] as int? ?? 0,
      artInstalled: artInstalled,
      problems: problems,
    );
  }
}
