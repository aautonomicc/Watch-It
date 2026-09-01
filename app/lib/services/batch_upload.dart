import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:watchit_upload/watchit_upload.dart';

import 'embedded_client.dart';
import 'publish_api.dart';

/// The one running in-app batch-upload session (desktop only) — the
/// upload CLI's prepare/upload pipeline (cli/, docs/UPLOAD-CLI.md)
/// front-ended by the app instead of a terminal.
///
/// Reused unchanged from the CLI: the matcher (MusicBrainz/TMDB id
/// recovery + canonical name regeneration), the manifest lifecycle, the
/// content-hash ledger at ~/.watchit-upload/ledger.jsonl (shared with
/// the CLI — files either tool uploaded never re-pay), and the
/// .watch-list bundle writer. Replaced: the `ant` CLI + SECRET_KEY layer
/// becomes the embedded core's authed `/upload` (named uploads, paid
/// from the keychain wallet) + `GET /datamap/{addr}` for the bundle
/// bytes; the terminal confirm loop becomes [BatchConfirm] driven by the
/// Batch upload screen.
///
/// Lives outside the screen (PublishSession's pattern) so navigating
/// away mid-prepare or mid-upload loses nothing.
class BatchUploadSession extends ChangeNotifier {
  BatchUploadSession._();

  static BatchUploadSession instance = BatchUploadSession._();

  @visibleForTesting
  static void resetForTesting() {
    instance._aborted = true;
    instance._failPendingConfirm();
    instance._failPendingAlbumConfirm();
    instance = BatchUploadSession._();
  }

  BatchStage stage = BatchStage.idle;

  PublishApi? _api;
  Manifest? manifest;
  Ledger? _ledger;
  Matcher? _matcher;
  MusicBrainz? _mb;
  Tmdb? _tmdb;
  Directory? workDir;
  String _ffprobeBin = 'ffprobe';
  bool _aborted = false;

  /// Test overrides — when set they replace the real matcher/probe.
  @visibleForTesting
  Future<MatchOutcome> Function(String path, MediaProbe? probe,
      {Sidecar? sidecar, String? forcedType})? matchOverride;
  @visibleForTesting
  Future<MediaProbe?> Function(String path)? probeOverride;

  // ── prepare progress ─────────────────────────────────────────────────
  int prepareDone = 0;
  int prepareTotal = 0;
  String? currentFile;
  BatchConfirm? pendingConfirm;
  AlbumConfirm? pendingAlbumConfirm;

  // ── cost / wallet ────────────────────────────────────────────────────
  Map<String, Object?>? costEstimate; // per manifest.cost shape
  String? estimateError;
  String? prepareError;
  WalletBalances? balances;

  // ── upload progress ──────────────────────────────────────────────────
  int uploadDone = 0;
  int uploadTotal = 0;
  UploadJob? currentJob;
  String? currentUploadName;
  String? bundlePath;

  bool get idle => stage == BatchStage.idle;

  List<ManifestEntry> get entries => manifest?.entries ?? const [];

  List<ManifestEntry> _byStatus(String s) =>
      [for (final e in entries) if (e.status == s) e];

  int get readyCount => _byStatus('ready').length;
  int get dedupCount => _byStatus('already-uploaded').length;
  int get attentionCount => _byStatus('needs-attention').length;
  int get skippedCount => _byStatus('skipped').length;
  int get uploadedCount => _byStatus('uploaded').length;
  int get failedCount => _byStatus('failed').length;

  /// Kick off the prepare pass over [paths] (files and/or folders).
  /// [tmdbKey] comes from the app's Settings → Metadata key, falling
  /// back to the CLI config; [ffprobeBin] from FfmpegService's location
  /// logic (bundled binary beside the executable, then PATH).
  Future<void> startPrepare({
    required PublishApi api,
    required List<String> paths,
    required String listName,
    required Directory workDir,
    String? forcedType,
    String? tmdbKey,
    String ffprobeBin = 'ffprobe',
    Directory? configDir,
  }) async {
    assert(idle);
    _aborted = false;
    _api = api;
    _ffprobeBin = ffprobeBin;
    this.workDir = workDir..createSync(recursive: true);
    final config = CliConfig.load(home: configDir)..ensureDirs();
    _ledger = Ledger.load(config.ledgerFile);
    _mb = MusicBrainz(cacheDir: config.mbCacheDir);
    final key = _blank(tmdbKey) ?? config.tmdbKey;
    _tmdb = key == null ? null : Tmdb(key);
    _matcher = Matcher(config: config, mb: _mb!, tmdb: _tmdb);
    manifest = _loadOrCreateManifest(listName);
    stage = BatchStage.preparing;
    prepareDone = 0;
    prepareTotal = 0;
    costEstimate = null;
    estimateError = null;
    prepareError = null;
    balances = null;
    bundlePath = null;
    notifyListeners();
    unawaited(_prepare(paths));
  }

  static String? _blank(String? s) =>
      (s == null || s.trim().isEmpty) ? null : s.trim();

  Manifest _loadOrCreateManifest(String listName) {
    final file = File(p.join(workDir!.path, 'watchit-manifest.yaml'));
    if (file.existsSync()) {
      final m = Manifest.load(file);
      m.listName = listName;
      return m;
    }
    return Manifest(
      file: file,
      listName: listName,
      created: DateTime.now().toIso8601String(),
      entries: [],
    );
  }

  Future<MediaProbe?> _probe(String path) =>
      probeOverride?.call(path) ??
      probeFile(path, ffprobeBin: _ffprobeBin);

  Future<MatchOutcome> _match(String path, MediaProbe? probe,
          {Sidecar? sidecar, String? forcedType}) =>
      matchOverride?.call(path, probe,
          sidecar: sidecar, forcedType: forcedType) ??
      _matcher!.matchFile(path, probe,
          sidecar: sidecar, forcedType: forcedType);

  /// The prepare pass — runPrepare's loop with the terminal review
  /// swapped for [pendingConfirm] and sidecar skeletons swapped for the
  /// in-app manual form (rejects simply land `needs-attention`). Audio
  /// files without a per-file sidecar are deferred into album groups
  /// (albumGroupKey) and reviewed one whole album at a time — one
  /// release picked for every track, never track by track.
  Future<void> _prepare(List<String> paths) async {
    final m = manifest!;
    try {
      final files = collectMediaFiles(paths);
      prepareTotal = files.length;
      notifyListeners();
      // Insertion-ordered: albums review in the order their first track
      // appeared in the batch.
      final albums = <String, List<_PendingTrack>>{};
      for (final path in files) {
        if (_aborted) return;
        currentFile = p.basename(path);
        notifyListeners();
        final existing = m.bySource(path);
        final sidecar = Sidecar.read(path);
        if (existing != null &&
            (existing.status == 'uploaded' ||
                existing.status == 'already-uploaded' ||
                (existing.status == 'ready' && sidecar == null))) {
          prepareDone++;
          continue;
        }
        if (cueSiblingProblem(path)) {
          _upsert(
              existing,
              ManifestEntry(source: path, status: 'skipped')
                ..error = 'cue+single-file album rip — split into tracks '
                    'first (e.g. with ffmpeg/shnsplit)');
          prepareDone++;
          notifyListeners();
          continue;
        }
        final sha = await sha256OfFile(path);
        final size = File(path).lengthSync();
        final hit = _ledger!.lookup(sha);
        if (hit != null) {
          _upsert(
              existing,
              ManifestEntry(source: path, status: 'already-uploaded')
                ..sha256 = sha
                ..sizeBytes = size
                ..name = hit.name
                ..address = hit.address
                ..datamap = hit.datamapPath);
          prepareDone++;
          notifyListeners();
          continue;
        }
        final probe = await _probe(path);
        if (_aborted) return;
        if (sidecar == null &&
            kAudioExtensions.contains(p.extension(path).toLowerCase())) {
          albums
              .putIfAbsent(albumGroupKey(path, probe), () => [])
              .add(_PendingTrack(path, sha, size, probe, existing));
          continue;
        }
        await _matchAndRecord(path, sha, size, probe, sidecar, existing);
        if (_aborted) return;
        prepareDone++;
        m.save();
        notifyListeners();
      }
      for (final group in albums.values) {
        if (_aborted) return;
        if (group.length == 1) {
          // A lone track keeps the per-file card (incl. the
          // music/video toggle).
          final tr = group.single;
          currentFile = p.basename(tr.path);
          notifyListeners();
          await _matchAndRecord(
              tr.path, tr.sha, tr.size, tr.probe, null, tr.existing);
          if (_aborted) return;
          prepareDone++;
          m.save();
          notifyListeners();
        } else {
          await _prepareAlbum(group);
          if (_aborted) return;
        }
      }
      currentFile = null;
      m.save();
      stage = BatchStage.review;
      notifyListeners();
      await _estimate();
    } catch (e) {
      if (_aborted) return;
      currentFile = null;
      prepareError = '$e';
      m.save();
      stage = BatchStage.review;
      notifyListeners();
    }
  }

  /// The per-file leg: match, hold for the confirm card when the CLI's
  /// auto-accept rule (id-backed high confidence) doesn't apply, record.
  Future<void> _matchAndRecord(String path, String sha, int size,
      MediaProbe? probe, Sidecar? sidecar, ManifestEntry? existing) async {
    var outcome = await _match(path, probe, sidecar: sidecar);
    if (_aborted) return;

    // Auto-accept rule straight from the CLI: id-backed high
    // confidence passes without eyes. Everything else — uncertain
    // matches AND no-match-at-all files — raises the confirm card,
    // so a file in no database can get manual details/artwork or a
    // music/video flip on the spot instead of silently landing in
    // needs-attention.
    final autoAccept = outcome.matched &&
        outcome.confidence == 'high' &&
        outcome.method != 'search';
    if (!autoAccept && !outcome.skip) {
      final confirmed = await _awaitConfirm(path, probe, outcome);
      if (_aborted) return;
      outcome = confirmed ??
          MatchOutcome(
              type: outcome.type,
              note: 'match rejected at confirm',
              sidecarDefaults: outcome.sidecarDefaults);
    }
    _recordOutcome(path, sha, size, outcome, existing);
  }

  void _recordOutcome(String path, String sha, int size,
      MatchOutcome outcome, ManifestEntry? existing) {
    if (outcome.skip) {
      _upsert(existing, ManifestEntry(source: path, status: 'skipped'));
    } else if (!outcome.matched) {
      _upsert(
          existing,
          ManifestEntry(source: path, status: 'needs-attention')
            ..sha256 = sha
            ..sizeBytes = size
            ..type = outcome.type
            ..error = outcome.note);
    } else {
      String? artPath;
      final art = outcome.artBytes;
      if (art != null) {
        final artDir = Directory(p.join(workDir!.path, 'art'))
          ..createSync(recursive: true);
        artPath = p.join(artDir.path, '${sha.substring(0, 12)}.jpg');
        File(artPath).writeAsBytesSync(art);
      }
      _upsert(
          existing,
          ManifestEntry(source: path, status: 'ready')
            ..sha256 = sha
            ..sizeBytes = size
            ..type = outcome.type
            ..name = outcome.name
            ..ids = outcome.ids
            ..matchMethod = outcome.method
            ..confidence = outcome.confidence
            ..art = artPath
            ..description = outcome.description
            ..custom = outcome.custom
            ..customFields = outcome.customFields);
    }
  }

  // ── album flow ───────────────────────────────────────────────────────

  /// One album group: find the release once (Picard-tagged tracks get
  /// first say), resolve every track against it, then either auto-accept
  /// (id-backed high confidence, all tracks placed) or raise ONE
  /// [pendingAlbumConfirm] for the whole album.
  Future<void> _prepareAlbum(List<_PendingTrack> tracks) async {
    final m = manifest!;
    int trackNoOf(_PendingTrack t) =>
        t.probe?.trackNumber ??
        guessMusicName(p.basename(t.path)).track ??
        1 << 20;
    tracks.sort((a, b) {
      final d = (a.probe?.discNumber ?? 1).compareTo(b.probe?.discNumber ?? 1);
      if (d != 0) return d;
      final t = trackNoOf(a).compareTo(trackNoOf(b));
      return t != 0 ? t : a.path.compareTo(b.path);
    });

    // Discovery order: tracks carrying an embedded release id first, so
    // a tagged album resolves by id even when track 1's tag is missing.
    final order = List.generate(tracks.length, (i) => i)
      ..sort((a, b) {
        final ta = tracks[a].probe?.releaseMbid != null ? 0 : 1;
        final tb = tracks[b].probe?.releaseMbid != null ? 0 : 1;
        return ta != tb ? ta - tb : a - b;
      });
    final outcomes = List<MatchOutcome?>.filled(tracks.length, null);
    MatchOutcome? album;
    for (final i in order) {
      currentFile = p.basename(tracks[i].path);
      notifyListeners();
      final out = await _match(tracks[i].path, tracks[i].probe);
      if (_aborted) return;
      outcomes[i] = out;
      if (out.matched && out.ids['release_mbid'] != null) {
        album = out;
        break;
      }
    }
    final mbid = album?.ids['release_mbid'];
    if (mbid != null) {
      await _resolveAlbumTracks(tracks, outcomes, mbid);
      if (_aborted) return;
    }

    final allPlaced = outcomes.every((o) => o?.matched ?? false);
    final autoAccept = album != null &&
        album.confidence == 'high' &&
        album.method != 'search' &&
        allPlaced;
    var result = outcomes;
    if (!autoAccept) {
      final confirmed = await _awaitAlbumConfirm(tracks, outcomes, album);
      if (_aborted) return;
      result = confirmed ??
          [
            for (final o in outcomes)
              MatchOutcome(
                  type: 'music',
                  note: o?.note ?? 'album match rejected at confirm'),
          ];
    }
    for (var i = 0; i < tracks.length; i++) {
      final tr = tracks[i];
      _recordOutcome(
          tr.path,
          tr.sha,
          tr.size,
          result[i] ??
              MatchOutcome(
                  type: 'music',
                  note: outcomes[i]?.note ?? 'no album match'),
          tr.existing);
      prepareDone++;
    }
    m.save();
    notifyListeners();
  }

  /// Resolve every not-yet-placed track of the group against [mbid] via
  /// the matcher's sidecar path (recording mbid → track number → title
  /// similarity) — one release for the whole album by construction.
  Future<void> _resolveAlbumTracks(List<_PendingTrack> tracks,
      List<MatchOutcome?> outcomes, String mbid) async {
    for (var i = 0; i < tracks.length; i++) {
      if (_aborted) return;
      final cur = outcomes[i];
      if (cur != null && cur.matched && cur.ids['release_mbid'] == mbid) {
        continue;
      }
      final tr = tracks[i];
      currentFile = p.basename(tr.path);
      notifyListeners();
      outcomes[i] = await _match(tr.path, tr.probe,
          sidecar: Sidecar(
            type: 'music',
            releaseMbid: mbid,
            track: tr.probe?.trackNumber ??
                guessMusicName(p.basename(tr.path)).track,
          ));
    }
  }

  void _upsert(ManifestEntry? existing, ManifestEntry entry) {
    final m = manifest!;
    if (existing == null) {
      m.entries = [...m.entries, entry];
    } else {
      m.entries[m.entries.indexOf(existing)] = entry;
    }
  }

  // ── confirm flow ─────────────────────────────────────────────────────

  Future<MatchOutcome?> _awaitConfirm(
      String path, MediaProbe? probe, MatchOutcome outcome) {
    final confirm = BatchConfirm._(path, probe, outcome);
    pendingConfirm = confirm;
    notifyListeners();
    return confirm._completer.future.whenComplete(() {
      pendingConfirm = null;
      notifyListeners();
    });
  }

  void _failPendingConfirm() {
    final c = pendingConfirm;
    if (c != null && !c._completer.isCompleted) {
      c._completer.complete(MatchOutcome(type: c.outcome.type, skip: true));
    }
  }

  void confirmAccept() {
    final c = pendingConfirm;
    if (c == null || c._completer.isCompleted) return;
    c._completer.complete(c.outcome);
  }

  void confirmSkip() {
    final c = pendingConfirm;
    if (c == null || c._completer.isCompleted) return;
    c._completer.complete(MatchOutcome(type: c.outcome.type, skip: true));
  }

  /// Reject: no name for this file — it lands `needs-attention` and can
  /// be fixed with the manual form or another prepare pass.
  void confirmReject() {
    final c = pendingConfirm;
    if (c == null || c._completer.isCompleted) return;
    c._completer.complete(null);
  }

  Future<void> confirmToggleType() async {
    final c = pendingConfirm;
    if (c == null || c.busy) return;
    c.busy = true;
    notifyListeners();
    try {
      final flipped = c.outcome.type == 'music' ? 'video' : 'music';
      final out = await _match(c.path, c.probe, forcedType: flipped);
      if (!out.matched) {
        // Nothing on the other side either — keep waiting with the note.
        c.outcome = MatchOutcome(
            type: flipped,
            note: out.note ?? 'no match as $flipped',
            sidecarDefaults: out.sidecarDefaults);
      } else {
        c.outcome = out;
      }
    } finally {
      c.busy = false;
      notifyListeners();
    }
  }

  /// Manual music search; results land in [BatchConfirm.mbHits].
  Future<void> confirmSearchMusic(String artist, String album) async {
    final c = pendingConfirm;
    if (c == null || c.busy || _mb == null) return;
    c.busy = true;
    notifyListeners();
    try {
      c.mbHits =
          (await _mb!.searchReleases(artist, album, limit: 8)).toList();
      c.tmdbHits = null;
    } finally {
      c.busy = false;
      notifyListeners();
    }
  }

  /// Manual video search; results land in [BatchConfirm.tmdbHits].
  Future<void> confirmSearchVideo(String title,
      {int? year, required bool tv}) async {
    final c = pendingConfirm;
    if (c == null || c.busy || _tmdb == null) return;
    c.busy = true;
    notifyListeners();
    try {
      c.tmdbHits = (await _tmdb!.search(title, year: year, tv: tv))
          .take(8)
          .toList();
      c.mbHits = null;
    } finally {
      c.busy = false;
      notifyListeners();
    }
  }

  Future<void> confirmPickMb(String mbid) => _rematchWith(Sidecar(
      type: 'music',
      releaseMbid: mbid,
      track: pendingConfirm?.probe?.trackNumber));

  Future<void> confirmPickTmdb(int tmdbId, {required bool tv}) =>
      _rematchWith(Sidecar(type: 'video', tmdb: tmdbId, tmdbTv: tv));

  /// Paste an id/URL — MusicBrainz release, IMDb tt…, tmdb movie:N/tv:N.
  /// Returns false when nothing recognizable was in [raw].
  Future<bool> confirmPasteId(String raw) async {
    final mbid = RegExp(
            r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
            caseSensitive: false)
        .firstMatch(raw);
    final imdb = RegExp(r'tt\d+').firstMatch(raw);
    final tmdbM =
        RegExp(r'^(movie|tv)\s*[:/]\s*(\d+)$').firstMatch(raw.trim());
    if (mbid != null) {
      await confirmPickMb(mbid.group(0)!.toLowerCase());
      return true;
    }
    if (imdb != null) {
      await _rematchWith(Sidecar(type: 'video', imdb: imdb.group(0)));
      return true;
    }
    if (tmdbM != null) {
      await confirmPickTmdb(int.parse(tmdbM.group(2)!),
          tv: tmdbM.group(1) == 'tv');
      return true;
    }
    return false;
  }

  /// Case B — content in no database: the manual form's fields become a
  /// synthetic manual-entry sidecar, giving an id-tag-free name plus a
  /// userEdited bundle row exactly like the CLI's edited skeleton.
  Future<void> confirmManual(Sidecar sidecar) => _rematchWith(sidecar);

  Future<void> _rematchWith(Sidecar sidecar) async {
    final c = pendingConfirm;
    if (c == null || c.busy) return;
    c.busy = true;
    notifyListeners();
    try {
      final out = await _match(c.path, c.probe, sidecar: sidecar);
      if (out.matched && out.confidence == 'high' && out.method == 'sidecar') {
        if (!c._completer.isCompleted) c._completer.complete(out);
        return;
      }
      c.outcome = out;
      c.mbHits = null;
      c.tmdbHits = null;
    } finally {
      c.busy = false;
      notifyListeners();
    }
  }

  // ── album confirm flow ───────────────────────────────────────────────

  Future<List<MatchOutcome?>?> _awaitAlbumConfirm(List<_PendingTrack> tracks,
      List<MatchOutcome?> outcomes, MatchOutcome? album) {
    final first = tracks.first;
    final guess = guessMusicName(p.basename(first.path));
    final confirm = AlbumConfirm._(
      [for (final t in tracks) t.path],
      [for (final t in tracks) t.probe],
      outcomes,
      album,
      {
        'artist': first.probe?.tag('album_artist') ??
            first.probe?.tag('artist') ??
            guess.artist,
        'album': first.probe?.tag('album') ?? guess.album,
        'year': first.probe?.year,
      },
    );
    pendingAlbumConfirm = confirm;
    currentFile = null;
    notifyListeners();
    return confirm._completer.future.whenComplete(() {
      pendingAlbumConfirm = null;
      notifyListeners();
    });
  }

  void _failPendingAlbumConfirm() {
    final c = pendingAlbumConfirm;
    if (c != null && !c._completer.isCompleted) {
      c._completer.complete([
        for (final _ in c.tracks) MatchOutcome(type: 'music', skip: true),
      ]);
    }
  }

  /// Accept the album as resolved: placed tracks upload, unplaced ones
  /// land `needs-attention`.
  void albumAccept() {
    final c = pendingAlbumConfirm;
    if (c == null || c._completer.isCompleted) return;
    c._completer.complete(List.of(c.outcomes));
  }

  void albumSkip() {
    final c = pendingAlbumConfirm;
    if (c == null || c._completer.isCompleted) return;
    c._completer.complete([
      for (final _ in c.tracks) MatchOutcome(type: 'music', skip: true),
    ]);
  }

  /// Reject: no release for these files — every track lands
  /// `needs-attention` for another pass.
  void albumReject() {
    final c = pendingAlbumConfirm;
    if (c == null || c._completer.isCompleted) return;
    c._completer.complete(null);
  }

  /// Manual album search; results land in [AlbumConfirm.mbHits].
  Future<void> albumSearch(String artist, String album) async {
    final c = pendingAlbumConfirm;
    if (c == null || c.busy || _mb == null) return;
    c.busy = true;
    notifyListeners();
    try {
      c.mbHits =
          (await _mb!.searchReleases(artist, album, limit: 8)).toList();
    } finally {
      c.busy = false;
      notifyListeners();
    }
  }

  /// Re-resolve the whole album against a picked release.
  Future<void> albumPickMb(String mbid) async {
    final c = pendingAlbumConfirm;
    if (c == null || c.busy) return;
    c.busy = true;
    notifyListeners();
    try {
      for (var i = 0; i < c.tracks.length; i++) {
        c.outcomes[i] = await _match(c.tracks[i], c.probes[i],
            sidecar: Sidecar(
              type: 'music',
              releaseMbid: mbid,
              track: c.probes[i]?.trackNumber ??
                  guessMusicName(p.basename(c.tracks[i])).track,
            ));
      }
      c.album = c.outcomes.firstWhere((o) => o?.matched ?? false,
          orElse: () => c.outcomes.first);
      c.mbHits = null;
    } finally {
      c.busy = false;
      notifyListeners();
    }
  }

  /// Paste a MusicBrainz release id/URL for the whole album. Returns
  /// false when nothing recognizable was in [raw].
  Future<bool> albumPasteId(String raw) async {
    final mbid = RegExp(
            r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
            caseSensitive: false)
        .firstMatch(raw);
    if (mbid == null) return false;
    await albumPickMb(mbid.group(0)!.toLowerCase());
    return true;
  }

  /// Case B for a whole album not in any database: one manual form
  /// (artist/album/year/art) applied to every track, per-track titles
  /// and numbers from tags or the file names. Completes the confirm
  /// when every track resolves.
  Future<void> albumManual({
    required String artist,
    required String album,
    int? year,
    String? description,
    String? artPath,
  }) async {
    final c = pendingAlbumConfirm;
    if (c == null || c.busy) return;
    c.busy = true;
    notifyListeners();
    try {
      for (var i = 0; i < c.tracks.length; i++) {
        final probe = c.probes[i];
        final guess = guessMusicName(p.basename(c.tracks[i]));
        final title = probe?.tag('title') ??
            guess.title ??
            p.basenameWithoutExtension(c.tracks[i]);
        c.outcomes[i] = await _match(c.tracks[i], probe,
            sidecar: Sidecar(
              type: 'music',
              artist: artist,
              album: album,
              title: title,
              track: probe?.trackNumber ?? guess.track ?? i + 1,
              year: year,
              description: description,
              art: artPath,
            ));
      }
      c.album = c.outcomes.firstWhere((o) => o?.matched ?? false,
          orElse: () => c.outcomes.first);
      if (c.outcomes.every((o) => o?.matched ?? false) &&
          !c._completer.isCompleted) {
        c._completer.complete(List.of(c.outcomes));
      }
    } finally {
      c.busy = false;
      notifyListeners();
    }
  }

  // ── cost estimate ────────────────────────────────────────────────────

  Future<void> _estimate() async {
    final ready = _byStatus('ready');
    if (ready.isEmpty || _api == null) return;
    estimateError = null;
    notifyListeners();
    try {
      final quote = await _api!.estimate(ready.first.source);
      final perChunkAtto = quote.costAtto ~/
          BigInt.from(quote.chunkCount == 0 ? 1 : quote.chunkCount);
      var totalChunks = 0;
      for (final e in ready) {
        totalChunks += Ant.chunksFor(e.sizeBytes ?? 0);
      }
      final totalAtto = perChunkAtto * BigInt.from(totalChunks);
      costEstimate = {
        'total_atto': '$totalAtto',
        'total_chunks': totalChunks,
        'per_chunk_atto': '$perChunkAtto',
        'quoted_at': DateTime.now().toIso8601String(),
      };
      manifest!
        ..cost = {
          'estimated_total_ant': formatUnits(totalAtto),
          ...costEstimate!,
        }
        ..save();
    } catch (e) {
      estimateError = '$e';
    }
    try {
      balances = await _api!.balances();
    } catch (_) {
      // No wallet / unreachable — the screen gates on wallet status.
    }
    notifyListeners();
  }

  Future<void> refreshEstimate() => _estimate();

  BigInt? get estimatedTotalAtto {
    final raw = costEstimate?['total_atto'];
    return raw == null ? null : BigInt.tryParse('$raw');
  }

  // ── upload ───────────────────────────────────────────────────────────

  /// Upload every `ready` entry under its final name — the CLI's
  /// runUpload with the core's named `/upload` replacing the staging
  /// symlink + `ant file upload`. Manifest saved per state change;
  /// failures get one retry pass; ends with the .watch-list bundle.
  Future<void> startUpload() async {
    if (stage != BatchStage.review && stage != BatchStage.done) return;
    stage = BatchStage.uploading;
    uploadDone = 0;
    final pending = _byStatus('ready');
    uploadTotal = pending.length;
    notifyListeners();
    unawaited(_upload(pending));
  }

  Future<void> _upload(List<ManifestEntry> pending) async {
    final m = manifest!;
    final datamapsDir = Directory(p.join(workDir!.path, 'datamaps'))
      ..createSync(recursive: true);

    Future<void> uploadOne(ManifestEntry entry) async {
      final name = entry.name;
      if (name == null) {
        entry.status = 'failed';
        entry.error = 'no final name in manifest';
        m.save();
        return;
      }
      currentUploadName = name;
      currentJob = null;
      notifyListeners();
      try {
        final id = await _api!.startUpload(entry.source, name: name);
        while (true) {
          await Future<void>.delayed(const Duration(seconds: 1));
          if (_aborted) return;
          UploadJob job;
          try {
            job = await _api!.jobStatus(id);
          } catch (_) {
            continue; // Transient poll failure — next tick retries.
          }
          currentJob = job;
          notifyListeners();
          final result = job.result;
          if (job.phase == 'done' && result != null) {
            entry.address = result.address;
            entry.uploadedAt = DateTime.now().toIso8601String();
            final mapPath = p.join(datamapsDir.path, '$name.datamap');
            await _saveDatamap(result.address, mapPath);
            entry.datamap = mapPath;
            entry.status = 'uploaded';
            entry.error = null;
            m.save();
            _ledger!.append(LedgerEntry(
              sha256: entry.sha256 ?? '',
              name: name,
              sizeBytes:
                  entry.sizeBytes ?? File(entry.source).lengthSync(),
              date: entry.uploadedAt!,
              address: entry.address,
              datamapPath: mapPath,
              manifestPath: m.file.absolute.path,
            ));
            return;
          }
          if (job.phase == 'error') {
            throw PublishApiException(job.error ?? 'upload failed');
          }
        }
      } catch (e) {
        entry.status = 'failed';
        entry.error = '$e';
        m.save();
      }
    }

    for (final entry in pending) {
      if (_aborted) return;
      await uploadOne(entry);
      uploadDone++;
      notifyListeners();
    }
    // Retry pass: one more attempt for anything that failed this run.
    final retries = pending.where((e) => e.status == 'failed').toList();
    for (final entry in retries) {
      if (_aborted) return;
      entry.status = 'ready';
      await uploadOne(entry);
      notifyListeners();
    }
    _writeBundle();
    currentUploadName = null;
    currentJob = null;
    stage = BatchStage.done;
    m.save();
    notifyListeners();
  }

  /// The uploaded root map, ant-cli-compatible msgpack — same route the
  /// Upload done page's save-.datamap button uses.
  Future<void> _saveDatamap(String address, String toPath) async {
    final base = _api?.base ?? EmbeddedClient.baseUrl();
    if (base == null) throw PublishApiException('embedded client gone');
    final res = await http.get(Uri.parse('$base/datamap/$address'));
    if (res.statusCode != 200) {
      throw PublishApiException(
          'datamap fetch failed (${res.statusCode})');
    }
    File(toPath).writeAsBytesSync(res.bodyBytes, flush: true);
  }

  void _writeBundle() {
    final m = manifest!;
    final uploaded = [
      for (final e in m.entries)
        if ((e.status == 'uploaded' || e.status == 'already-uploaded') &&
            e.name != null &&
            e.datamap != null &&
            File(e.datamap!).existsSync())
          e,
    ];
    if (uploaded.isEmpty) return;
    final bundleEntries = [
      for (final e in uploaded)
        BundleOutEntry(
          name: e.name!,
          datamapBytes: File(e.datamap!).readAsBytesSync(),
          custom: e.custom,
          description: e.description,
          artBytes: e.custom && e.art != null && File(e.art!).existsSync()
              ? File(e.art!).readAsBytesSync()
              : null,
          customTitle: e.customFields['title']?.toString() ??
              ((e.customFields['artist'] != null &&
                      e.customFields['album'] != null)
                  ? '${e.customFields['artist']} - ${e.customFields['album']}'
                  : null),
          customYear: e.customFields['year'] as int?,
          mediaType:
              e.custom ? (e.type == 'music' ? 'music' : null) : null,
        ),
    ];
    final out = File(p.join(workDir!.path, '${m.listName}.watch-list'));
    writeBundle(out, m.listName, bundleEntries);
    bundlePath = out.path;
  }

  /// Entries that made it onto the network this session — the done
  /// page's add-to-library rows.
  List<ManifestEntry> get uploadedEntries => [
        for (final e in entries)
          if ((e.status == 'uploaded' || e.status == 'already-uploaded') &&
              e.name != null &&
              e.address != null)
            e,
      ];

  /// Flip this run's failures back to ready and run the upload again.
  void retryFailed() {
    if (stage != BatchStage.done) return;
    for (final e in _byStatus('failed')) {
      e.status = 'ready';
    }
    manifest?.save();
    startUpload();
  }

  /// Abort whatever is running and forget the session (the manifest and
  /// any uploads already paid for stay on disk / in the ledger).
  void clear() {
    _aborted = true;
    _failPendingConfirm();
    _failPendingAlbumConfirm();
    _mb?.close();
    _tmdb?.close();
    _mb = null;
    _tmdb = null;
    _matcher = null;
    _ledger = null;
    _api = null;
    manifest = null;
    workDir = null;
    stage = BatchStage.idle;
    pendingConfirm = null;
    pendingAlbumConfirm = null;
    costEstimate = null;
    estimateError = null;
    prepareError = null;
    balances = null;
    bundlePath = null;
    prepareDone = prepareTotal = 0;
    uploadDone = uploadTotal = 0;
    currentFile = null;
    currentUploadName = null;
    currentJob = null;
    notifyListeners();
  }
}

enum BatchStage { idle, preparing, review, uploading, done }

/// One file waiting for the user's eyes — the CLI's beets-style confirm
/// prompt as data. Every action funnels back through Matcher.matchFile
/// with a synthetic sidecar, exactly like the terminal loop.
class BatchConfirm {
  BatchConfirm._(this.path, this.probe, this.outcome);

  final String path;
  final MediaProbe? probe;
  MatchOutcome outcome;
  List<MbSearchHit>? mbHits;
  List<TmdbHit>? tmdbHits;
  bool busy = false;
  final _completer = Completer<MatchOutcome?>();
}

/// One audio file waiting for its album group to be prepared.
class _PendingTrack {
  _PendingTrack(this.path, this.sha, this.size, this.probe, this.existing);

  final String path;
  final String sha;
  final int size;
  final MediaProbe? probe;
  final ManifestEntry? existing;
}

/// A whole album waiting for the user's eyes — one card, one release
/// decision, applied to every track. Search/paste-id/manual actions
/// re-resolve ALL tracks so an album can never end up split across
/// releases.
class AlbumConfirm {
  AlbumConfirm._(
      this.tracks, this.probes, this.outcomes, this.album, this.defaults);

  /// Source paths in album order (disc, then track number).
  final List<String> tracks;
  final List<MediaProbe?> probes;

  /// Per-track outcome as currently resolved; null or unmatched =
  /// couldn't be placed on the release (lands `needs-attention` on
  /// accept).
  final List<MatchOutcome?> outcomes;

  /// The outcome that named the release — carries the album note and
  /// cover art. Null when nothing matched at all.
  MatchOutcome? album;

  /// Artist/album/year prefills for the search and manual-entry forms.
  final Map<String, Object?> defaults;

  List<MbSearchHit>? mbHits;
  bool busy = false;
  final _completer = Completer<List<MatchOutcome?>?>();

  /// "Artist — Album (Year)" from the representative note (the note's
  /// leading segment before its ", track N" suffix).
  String? get albumLine {
    final note = album?.note;
    if (note == null) return null;
    final cut = note.indexOf(', track ');
    return cut < 0 ? note : note.substring(0, cut);
  }
}
