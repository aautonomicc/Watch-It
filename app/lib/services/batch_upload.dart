import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:watchit_upload/watchit_upload.dart';

import '../models/media_list.dart';
import 'bundle.dart' show parseBundle, seedBundle;
import 'embedded_client.dart';
import 'ffmpeg.dart' show FfmpegService;
import 'library_store.dart' show addEntriesToLists;
import 'publish_api.dart';
import 'publish_plan.dart' as plan;

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
/// bytes; the terminal confirm loop becomes the [confirmables] carousel
/// driven by the Batch upload screen — every match needing eyes is
/// queued during the scan and reviewed afterwards, with back/forward
/// navigation so an earlier answer can be changed.
///
/// Lives outside the screen (survive-navigation pattern) so navigating
/// away mid-prepare or mid-upload loses nothing.
class BatchUploadSession extends ChangeNotifier {
  BatchUploadSession._();

  static BatchUploadSession instance = BatchUploadSession._();

  @visibleForTesting
  static void resetForTesting() {
    instance._aborted = true;
    instance._ffmpeg?.cancel();
    instance = BatchUploadSession._();
  }

  BatchStage stage = BatchStage.idle;

  PublishApi? _api;
  Manifest? manifest;
  Ledger? _ledger;
  Matcher? _matcher;
  MusicBrainz? _mb;
  Tmdb? _tmdb;
  FfmpegService? _ffmpeg;
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

  /// What the scan is doing to [currentFile] right now — drives the
  /// per-file step line on the preparing page, so the slow legs (the
  /// fingerprint read of a multi-GB movie) don't look like a hang.
  PrepareStep? prepareStep;

  /// Fingerprint progress (0–1) for the current file. Only set while
  /// [prepareStep] is [PrepareStep.fingerprint].
  double? hashFraction;

  void _setPrepareStep(PrepareStep? step) {
    prepareStep = step;
    hashFraction = null;
    notifyListeners();
  }

  /// Everything that needs the user's eyes, in scan order — a
  /// [BatchConfirm] per lone file, an [AlbumConfirm] per album group.
  /// Filled during the scan, reviewed as a carousel afterwards; decided
  /// cards stay navigable so an earlier answer can be replaced (each
  /// decision upserts the manifest entry).
  final List<Object> confirmables = [];
  int confirmIndex = 0;
  bool _confirmPhase = false;

  /// The carousel is showing (scan finished, cards to review — or a
  /// card reopened from the summary).
  bool get reviewingMatches => _confirmPhase && confirmables.isNotEmpty;

  Object? get _currentConfirmable =>
      _confirmPhase && confirmIndex < confirmables.length
          ? confirmables[confirmIndex]
          : null;

  BatchConfirm? get pendingConfirm {
    final c = _currentConfirmable;
    return c is BatchConfirm ? c : null;
  }

  AlbumConfirm? get pendingAlbumConfirm {
    final c = _currentConfirmable;
    return c is AlbumConfirm ? c : null;
  }

  int get undecidedConfirmCount =>
      confirmables.where(_undecided).length;

  static bool _undecided(Object c) => switch (c) {
        final BatchConfirm f => !f.decided,
        final AlbumConfirm a => !a.decided,
        _ => false,
      };

  // ── cost / wallet ────────────────────────────────────────────────────
  Map<String, Object?>? costEstimate; // per manifest.cost shape
  String? estimateError;
  String? prepareError;
  WalletBalances? balances;

  // ── quality tiers (video entries only) ───────────────────────────────

  /// App-side ffprobe results for ready video entries, keyed by source
  /// path — drives the review page's QUALITY section. Music and
  /// unprobeable files never appear here and upload as-is.
  final Map<String, plan.MediaProbe?> videoProbes = {};

  /// Selected quality tiers, applied to every ready video entry they
  /// fit (same global-selection model the old Upload tier flow used).
  Set<plan.PublishTier> tiers = {};
  bool _tiersInitialized = false;

  /// Per-output `1080p H.264`-style labels for the library entries.
  final Map<String, String?> videoInfoByName = {};

  // ── upload progress ──────────────────────────────────────────────────
  int uploadDone = 0;
  int uploadTotal = 0;
  UploadJob? currentJob;
  String? currentUploadName;
  double? encodeFraction;
  String? bundlePath;
  List<_UploadTask> _tasks = [];

  // ── done page ────────────────────────────────────────────────────────

  /// The list the finished batch was automatically added to (the
  /// setup-page choice), null when the auto-add did not run/failed.
  String? autoAddedList;
  int autoAddedCount = 0;

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
  /// logic (bundled binary beside the executable, then PATH); [ffmpeg]
  /// enables the review page's quality-tier encodes for video entries.
  Future<void> startPrepare({
    required PublishApi api,
    required List<String> paths,
    required String listName,
    required Directory workDir,
    String? forcedType,
    String? tmdbKey,
    String ffprobeBin = 'ffprobe',
    Directory? configDir,
    FfmpegService? ffmpeg,
  }) async {
    assert(idle);
    _aborted = false;
    _api = api;
    _ffprobeBin = ffprobeBin;
    _ffmpeg = ffmpeg;
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
    prepareStep = null;
    hashFraction = null;
    confirmables.clear();
    confirmIndex = 0;
    _confirmPhase = false;
    videoProbes.clear();
    tiers = {};
    _tiersInitialized = false;
    videoInfoByName.clear();
    _tasks = [];
    costEstimate = null;
    estimateError = null;
    prepareError = null;
    balances = null;
    bundlePath = null;
    autoAddedList = null;
    autoAddedCount = 0;
    notifyListeners();
    unawaited(_prepare(paths));
  }

  static String? _blank(String? s) =>
      (s == null || s.trim().isEmpty) ? null : s.trim();

  /// Reopen an interrupted batch at its review page — the Previous
  /// uploads Continue button. The manifest's still-`ready` entries (and
  /// `failed` ones, flipped back) are offered for upload again;
  /// everything already uploaded is left alone, so the batch picks up
  /// where it was cut short instead of starting over or re-paying.
  Future<void> resumeBatch({
    required PublishApi api,
    required Directory workDir,
    String ffprobeBin = 'ffprobe',
    Directory? configDir,
    FfmpegService? ffmpeg,
  }) async {
    assert(idle);
    final file = File(p.join(workDir.path, 'watchit-manifest.yaml'));
    final Manifest m;
    try {
      m = Manifest.load(file);
    } catch (_) {
      return; // Unreadable/missing manifest — nothing to resume.
    }
    _aborted = false;
    _api = api;
    _ffprobeBin = ffprobeBin;
    _ffmpeg = ffmpeg;
    this.workDir = workDir;
    final config = CliConfig.load(home: configDir)..ensureDirs();
    _ledger = Ledger.load(config.ledgerFile);
    // Per-tier sibling rows from an interrupted video upload collapse
    // back to one ready row per source — tiers are re-picked on the
    // review page and re-expand at upload (already-uploaded tier
    // outputs are never planned again, see _videoItems).
    final seenReadySource = <String>{};
    final entries = <ManifestEntry>[];
    for (final e in m.entries) {
      if (e.status == 'failed') {
        e.status = 'ready';
        e.error = null;
      }
      if (e.status == 'ready') {
        if (!File(e.source).existsSync()) {
          e.status = 'failed';
          e.error = 'source file no longer exists';
        } else if (!seenReadySource.add(e.source)) {
          continue;
        }
      }
      entries.add(e);
    }
    m.entries = entries;
    m.save();
    manifest = m;
    prepareDone = prepareTotal = 0;
    currentFile = null;
    prepareStep = null;
    hashFraction = null;
    confirmables.clear();
    confirmIndex = 0;
    _confirmPhase = false;
    videoProbes.clear();
    tiers = {};
    _tiersInitialized = false;
    videoInfoByName.clear();
    _tasks = [];
    costEstimate = null;
    estimateError = null;
    prepareError = null;
    balances = null;
    bundlePath = null;
    autoAddedList = null;
    autoAddedCount = 0;
    uploadDone = uploadTotal = 0;
    await _finishPrepare();
  }

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
  /// swapped for the deferred [confirmables] queue and sidecar skeletons
  /// swapped for the in-app manual form (rejects simply land
  /// `needs-attention`). Audio files without a per-file sidecar are
  /// deferred into album groups (albumGroupKey) and reviewed one whole
  /// album at a time — one release picked for every track, never track
  /// by track. Files the auto-accept rule doesn't cover queue up during
  /// the scan and are reviewed together once it finishes.
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
        final size = File(path).lengthSync();
        prepareStep = PrepareStep.fingerprint;
        hashFraction = size == 0 ? null : 0;
        notifyListeners();
        var lastNotified = 0.0;
        final sha = await sha256OfFile(path, onBytes: (read) {
          if (size == 0) return;
          final f = read / size;
          // Throttled — the callback fires per 64KB chunk.
          if (f - lastNotified >= 0.01) {
            lastNotified = f;
            hashFraction = f;
            notifyListeners();
          }
        });
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
          _setPrepareStep(null);
          continue;
        }
        _setPrepareStep(PrepareStep.mediaInfo);
        final probe = await _probe(path);
        if (_aborted) return;
        if (sidecar == null &&
            kAudioExtensions.contains(p.extension(path).toLowerCase())) {
          albums
              .putIfAbsent(albumGroupKey(path, probe), () => [])
              .add(_PendingTrack(path, sha, size, probe, existing));
          _setPrepareStep(null);
          continue;
        }
        _setPrepareStep(PrepareStep.match);
        await _matchOrDefer(path, sha, size, probe, sidecar, existing);
        if (_aborted) return;
        prepareDone++;
        prepareStep = null;
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
          prepareStep = PrepareStep.match;
          notifyListeners();
          await _matchOrDefer(
              tr.path, tr.sha, tr.size, tr.probe, null, tr.existing);
          if (_aborted) return;
          prepareDone++;
          prepareStep = null;
          m.save();
          notifyListeners();
        } else {
          await _prepareAlbum(group);
          if (_aborted) return;
        }
      }
      currentFile = null;
      prepareStep = null;
      hashFraction = null;
      m.save();
      if (confirmables.any(_undecided)) {
        _confirmPhase = true;
        confirmIndex = confirmables.indexWhere(_undecided);
        notifyListeners();
      } else {
        await _finishPrepare();
      }
    } catch (e) {
      if (_aborted) return;
      currentFile = null;
      prepareStep = null;
      hashFraction = null;
      prepareError = '$e';
      _confirmPhase = false;
      m.save();
      stage = BatchStage.review;
      notifyListeners();
    }
  }

  /// The per-file leg: match, then either record straight away (the
  /// CLI's id-backed high-confidence auto-accept) or queue a confirm
  /// card. Everything else — uncertain matches AND no-match-at-all
  /// files — waits for eyes, so a file in no database can get manual
  /// details/artwork or a music/video flip instead of silently landing
  /// in needs-attention. An auto-accept still gets a card — already
  /// decided, so the carousel never stops on it, but reopenable from
  /// the summary so the match (title, art) is visible and a wrong
  /// automatic answer stays fixable.
  Future<void> _matchOrDefer(String path, String sha, int size,
      MediaProbe? probe, Sidecar? sidecar, ManifestEntry? existing) async {
    final outcome = await _match(path, probe, sidecar: sidecar);
    if (_aborted) return;
    final autoAccept = outcome.matched &&
        outcome.confidence == 'high' &&
        outcome.method != 'search';
    if (autoAccept || outcome.skip) {
      _recordOutcome(path, sha, size, outcome, existing);
      if (autoAccept) {
        confirmables.add(
            BatchConfirm._(path, probe, outcome, sha, size)..decided = true);
      }
    } else {
      confirmables.add(BatchConfirm._(path, probe, outcome, sha, size));
    }
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
  /// first say), resolve every track against it, then either record it
  /// whole (id-backed high confidence, all tracks placed) or queue ONE
  /// [AlbumConfirm] for the whole album.
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
      prepareStep = PrepareStep.match;
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
    if (autoAccept) {
      for (var i = 0; i < tracks.length; i++) {
        final tr = tracks[i];
        _recordOutcome(tr.path, tr.sha, tr.size,
            outcomes[i]!, tr.existing);
      }
    }
    // Auto-accepted albums keep their card too — decided, never shown
    // by the carousel, but reopenable from the summary so the release
    // (cover art, track placement) is visible and replaceable.
    final first = tracks.first;
    final guess = guessMusicName(p.basename(first.path));
    confirmables.add(AlbumConfirm._(
      [for (final t in tracks) t.path],
      [for (final t in tracks) t.probe],
      [for (final t in tracks) t.sha],
      [for (final t in tracks) t.size],
      outcomes,
      album,
      {
        'artist': first.probe?.tag('album_artist') ??
            first.probe?.tag('artist') ??
            guess.artist,
        'album': first.probe?.tag('album') ?? guess.album,
        'year': first.probe?.year,
      },
    )..decided = autoAccept);
    prepareDone += tracks.length;
    prepareStep = null;
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

  // ── confirm carousel ─────────────────────────────────────────────────

  /// Show another card of the queue (back/forward arrows). Decided
  /// cards reopen with their answer replaceable.
  void confirmGoTo(int index) {
    if (!_confirmPhase || confirmables.isEmpty) return;
    confirmIndex = index.clamp(0, confirmables.length - 1);
    notifyListeners();
  }

  void confirmPrevious() => confirmGoTo(confirmIndex - 1);
  void confirmNext() => confirmGoTo(confirmIndex + 1);

  /// Reopen the card that decided [source] (a manifest entry's source
  /// path) from the review summary.
  bool canReopen(String source) => _confirmIndexFor(source) >= 0;

  void reopenConfirmForSource(String source) {
    final i = _confirmIndexFor(source);
    if (i < 0) return;
    confirmIndex = i;
    _confirmPhase = true;
    stage = BatchStage.preparing;
    notifyListeners();
  }

  int _confirmIndexFor(String source) {
    for (var i = 0; i < confirmables.length; i++) {
      final c = confirmables[i];
      if (c is BatchConfirm && c.path == source) return i;
      if (c is AlbumConfirm && c.tracks.contains(source)) return i;
    }
    return -1;
  }

  /// Leave the carousel for the review summary — only once every card
  /// has an answer.
  void finishConfirms() {
    if (!_confirmPhase || confirmables.any(_undecided)) return;
    unawaited(_finishPrepare());
  }

  /// Record the decision for the current card and move on: to the next
  /// unanswered card, or (none left) to the review summary.
  void _decideCurrent(BatchConfirm c, MatchOutcome outcome) {
    final m = manifest!;
    _recordOutcome(c.path, c.sha, c.size, outcome, m.bySource(c.path));
    c.decided = true;
    m.save();
    _advanceConfirm();
  }

  void _decideAlbum(AlbumConfirm c, List<MatchOutcome?> result) {
    final m = manifest!;
    for (var i = 0; i < c.tracks.length; i++) {
      final out = result[i] ??
          MatchOutcome(
              type: 'music',
              note: c.outcomes[i]?.note ?? 'no album match');
      _recordOutcome(
          c.tracks[i], c.shas[i], c.sizes[i], out, m.bySource(c.tracks[i]));
    }
    c.decided = true;
    m.save();
    _advanceConfirm();
  }

  void _advanceConfirm() {
    for (var i = confirmIndex + 1; i < confirmables.length; i++) {
      if (_undecided(confirmables[i])) {
        confirmIndex = i;
        notifyListeners();
        return;
      }
    }
    final first = confirmables.indexWhere(_undecided);
    if (first >= 0) {
      confirmIndex = first;
      notifyListeners();
      return;
    }
    unawaited(_finishPrepare());
  }

  /// All matches settled — on to the review summary: probe video
  /// entries for the QUALITY section, then the cost estimate.
  Future<void> _finishPrepare() async {
    _confirmPhase = false;
    stage = BatchStage.review;
    notifyListeners();
    await _probeVideos();
    await _estimate();
  }

  void confirmAccept() {
    final c = pendingConfirm;
    if (c == null || c.busy) return;
    _decideCurrent(c, c.outcome);
  }

  void confirmSkip() {
    final c = pendingConfirm;
    if (c == null || c.busy) return;
    _decideCurrent(c, MatchOutcome(type: c.outcome.type, skip: true));
  }

  /// Reject: no name for this file — it lands `needs-attention` and can
  /// be fixed with the manual form or another prepare pass.
  void confirmReject() {
    final c = pendingConfirm;
    if (c == null || c.busy) return;
    _decideCurrent(
        c,
        MatchOutcome(
            type: c.outcome.type,
            note: 'match rejected at confirm',
            sidecarDefaults: c.outcome.sidecarDefaults));
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
        // Keep the card showing what was decided — reopening it from
        // the summary shows the answer, not the stale pre-answer state.
        c.outcome = out;
        c.mbHits = null;
        c.tmdbHits = null;
        c.busy = false;
        _decideCurrent(c, out);
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

  // ── album confirm actions ────────────────────────────────────────────

  /// Accept the album as resolved: placed tracks upload, unplaced ones
  /// land `needs-attention`.
  void albumAccept() {
    final c = pendingAlbumConfirm;
    if (c == null || c.busy) return;
    _decideAlbum(c, List.of(c.outcomes));
  }

  void albumSkip() {
    final c = pendingAlbumConfirm;
    if (c == null || c.busy) return;
    _decideAlbum(c, [
      for (final _ in c.tracks) MatchOutcome(type: 'music', skip: true),
    ]);
  }

  /// Reject: no release for these files — every track lands
  /// `needs-attention` for another pass.
  void albumReject() {
    final c = pendingAlbumConfirm;
    if (c == null || c.busy) return;
    _decideAlbum(c, [
      for (final o in c.outcomes)
        MatchOutcome(
            type: 'music',
            note: o?.note ?? 'album match rejected at confirm'),
    ]);
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
  /// and numbers from tags or the file names. Decides the card when
  /// every track resolves.
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
      if (c.outcomes.every((o) => o?.matched ?? false)) {
        c.busy = false;
        _decideAlbum(c, List.of(c.outcomes));
        return;
      }
    } finally {
      c.busy = false;
      notifyListeners();
    }
  }

  // ── quality tiers ────────────────────────────────────────────────────

  /// Probe every ready video entry with the app-side ffprobe wrapper
  /// (publish_plan's codec-aware probe — the CLI's music-centric probe
  /// lacks codec/container fields) so the review page can offer encode
  /// tiers. Music entries and files that can't be probed upload as-is.
  Future<void> _probeVideos() async {
    final ff = _ffmpeg;
    if (ff == null || !await ff.available) return;
    for (final e in _byStatus('ready')) {
      if (_aborted) return;
      if (e.type == 'music' || videoProbes.containsKey(e.source)) continue;
      try {
        videoProbes[e.source] = await ff.probe(e.source);
      } catch (_) {
        videoProbes[e.source] = null;
      }
    }
    if (!_tiersInitialized) {
      _tiersInitialized = true;
      tiers = {
        for (final probe in videoProbes.values)
          if (probe?.hasVideo ?? false) ...plan.defaultTiers(probe),
      };
    }
    notifyListeners();
  }

  /// Ready entries the QUALITY section applies to.
  List<ManifestEntry> get readyVideoEntries => [
        for (final e in _byStatus('ready'))
          if (videoProbes[e.source]?.hasVideo ?? false) e,
      ];

  /// Tiers any ready video entry offers, encode tiers first.
  List<plan.PublishTier> get offeredTiers {
    final offered = <plan.PublishTier>{
      for (final e in readyVideoEntries)
        ...plan.offeredTiers(videoProbes[e.source]),
    };
    return [
      ...plan.kEncodeTierOrder.where(offered.contains),
      if (offered.contains(plan.PublishTier.original))
        plan.PublishTier.original,
    ];
  }

  void setTier(plan.PublishTier tier, bool selected) {
    if (selected) {
      tiers.add(tier);
    } else {
      tiers.remove(tier);
    }
    _tiersInitialized = true;
    notifyListeners();
    unawaited(_estimate());
  }

  /// The tier expansion for one ready entry: the planned per-tier
  /// outputs, empty when the entry uploads as-is (music, unprobeable,
  /// or no selected tier applies).
  List<plan.PublishItem> _videoItems(ManifestEntry e) {
    if (_ffmpeg == null) return const [];
    final probe = videoProbes[e.source];
    if (probe == null || !probe.hasVideo) return const [];
    final src = plan.PublishSource(
      path: e.source,
      name: e.name ?? p.basename(e.source),
      size: e.sizeBytes ?? 0,
      probe: probe,
    );
    // A resumed batch may already hold some tier outputs (sibling rows
    // uploaded before the interruption) — never plan those again.
    final done = _uploadedNamesFor(e.source);
    return [
      for (final item in plan.buildQueue([src], tiers))
        if (!done.contains(item.outputName)) item,
    ];
  }

  /// Final names this batch already put on the network for [source].
  Set<String> _uploadedNamesFor(String source) => {
        for (final e in entries)
          if (e.source == source &&
              (e.status == 'uploaded' || e.status == 'already-uploaded') &&
              e.name != null)
            e.name!,
      };

  /// Uploads the batch will run, tier expansion included.
  int get plannedUploadCount {
    var n = 0;
    for (final e in _byStatus('ready')) {
      final items = _videoItems(e);
      n += items.isEmpty ? 1 : items.length;
    }
    return n;
  }

  /// Videos none of the selected tiers cover — they upload as-is (the
  /// review page calls it out).
  List<ManifestEntry> get uncoveredVideoEntries => [
        for (final e in readyVideoEntries)
          if (_videoItems(e).isEmpty) e,
      ];

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
        final items = _videoItems(e);
        if (items.isEmpty) {
          totalChunks += Ant.chunksFor(e.sizeBytes ?? 0);
        } else {
          for (final item in items) {
            totalChunks +=
                Ant.chunksFor(item.predictedBytes ?? e.sizeBytes ?? 0);
          }
        }
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
  /// symlink + `ant file upload`. Video entries with selected quality
  /// tiers expand into one upload per tier (encoded on the fly, sibling
  /// manifest rows added so the bundle and library carry every
  /// version). Manifest saved per state change; failures get one retry
  /// pass; ends with the .watch-list bundle, a local metadata seed, and
  /// the automatic add to the chosen list.
  Future<void> startUpload() async {
    if (stage != BatchStage.review) return;
    stage = BatchStage.uploading;
    uploadDone = 0;
    _tasks = _buildTasks();
    uploadTotal = _tasks.length;
    notifyListeners();
    unawaited(_upload(_tasks));
  }

  List<_UploadTask> _buildTasks() {
    final m = manifest!;
    final tasks = <_UploadTask>[];
    final entries = List<ManifestEntry>.of(m.entries);
    for (final e in _byStatus('ready')) {
      final items = _videoItems(e);
      if (items.isEmpty) {
        if (_uploadedNamesFor(e.source).contains(e.name)) {
          // Resumed batch: every selected version of this source is
          // already on the network — nothing left to pay for.
          e.status = 'skipped';
          e.error = 'already uploaded in this batch';
          continue;
        }
        tasks.add(_UploadTask(e));
        continue;
      }
      final probe = videoProbes[e.source];
      // First output rides the source's manifest row; the other tiers
      // get sibling rows so every version lands in the manifest, the
      // ledger, the bundle, and the library (version-picker fold).
      e.name = items.first.outputName;
      videoInfoByName[items.first.outputName] =
          plan.tierVideoInfo(probe, items.first.tier);
      tasks.add(_UploadTask(e, tierItem: items.first));
      var at = entries.indexOf(e) + 1;
      for (final item in items.skip(1)) {
        final clone = ManifestEntry(
          source: e.source,
          status: 'ready',
          sha256: e.sha256,
          sizeBytes: e.sizeBytes,
          type: e.type,
          name: item.outputName,
          ids: Map.of(e.ids),
          matchMethod: e.matchMethod,
          confidence: e.confidence,
          art: e.art,
          description: e.description,
          custom: e.custom,
          customFields: Map.of(e.customFields),
        );
        entries.insert(at++, clone);
        videoInfoByName[item.outputName] =
            plan.tierVideoInfo(probe, item.tier);
        tasks.add(_UploadTask(clone, tierItem: item));
      }
    }
    m.entries = entries;
    m.save();
    return tasks;
  }

  Future<void> _upload(List<_UploadTask> tasks) async {
    final m = manifest!;
    final datamapsDir = Directory(p.join(workDir!.path, 'datamaps'))
      ..createSync(recursive: true);
    final encodesDir = Directory(p.join(workDir!.path, 'encodes'));

    Future<void> uploadOne(_UploadTask task) async {
      final entry = task.entry;
      final name = entry.name;
      if (name == null) {
        entry.status = 'failed';
        entry.error = 'no final name in manifest';
        m.save();
        return;
      }
      currentUploadName = name;
      currentJob = null;
      encodeFraction = null;
      notifyListeners();
      try {
        var uploadPath = entry.source;
        final item = task.tierItem;
        if (item != null && item.needsEncode) {
          // A retry after an upload failure reuses the finished encode.
          var temp = task.tempPath;
          if (temp == null || !File(temp).existsSync()) {
            encodesDir.createSync(recursive: true);
            temp = p.join(encodesDir.path, name);
            await _ffmpeg!.encode(
              input: entry.source,
              output: temp,
              tier: item.tier,
              probe: item.source.probe,
              onProgress: (fraction) {
                encodeFraction = fraction;
                notifyListeners();
              },
            );
            if (_aborted) return;
            task.tempPath = temp;
          }
          encodeFraction = null;
          // The ledger keys by content, so the encoded output gets its
          // own hash and size (the source's stay on its own row).
          entry.sha256 = await sha256OfFile(temp);
          entry.sizeBytes = File(temp).lengthSync();
          m.save();
          uploadPath = temp;
        }
        final id = await _api!.startUpload(uploadPath, name: name);
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
                  entry.sizeBytes ?? File(uploadPath).lengthSync(),
              date: entry.uploadedAt!,
              address: entry.address,
              datamapPath: mapPath,
              manifestPath: m.file.absolute.path,
            ));
            task.deleteTemp();
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

    for (final task in tasks) {
      if (_aborted) return;
      await uploadOne(task);
      uploadDone++;
      notifyListeners();
    }
    // Retry pass: one more attempt for anything that failed this run.
    final retries =
        tasks.where((t) => t.entry.status == 'failed').toList();
    for (final task in retries) {
      if (_aborted) return;
      task.entry.status = 'ready';
      await uploadOne(task);
      notifyListeners();
    }
    _writeBundle();
    await _seedBundleLocally();
    await _autoAddToLibrary();
    currentUploadName = null;
    currentJob = null;
    encodeFraction = null;
    try {
      if (encodesDir.existsSync()) encodesDir.deleteSync(recursive: true);
    } catch (_) {}
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

  /// Seed the LOCAL metadata cache and posters from the batch's own
  /// bundle — manual-entry (case-B) details and artwork otherwise only
  /// travel in the bundle and never show on this device (matched files
  /// masked the gap because their ids re-fetch). Gap-fill semantics:
  /// existing local rows always win.
  Future<void> _seedBundleLocally() async {
    final path = bundlePath;
    if (path == null) return;
    try {
      final bytes = Uint8List.fromList(File(path).readAsBytesSync());
      await seedBundle(parseBundle(bytes), importHistory: false);
    } catch (_) {
      // Best-effort — the bundle itself still carries everything.
    }
  }

  /// Add the finished uploads to the list chosen on the setup page —
  /// the user already picked it there, so the done page reports the
  /// result instead of asking again.
  Future<void> _autoAddToLibrary() async {
    final uploaded = uploadedEntries;
    final list = manifest?.listName.trim();
    if (uploaded.isEmpty || list == null || list.isEmpty) return;
    try {
      await addEntriesToLists([
        for (final e in uploaded)
          MediaEntry(
            name: e.name!,
            address: e.address!,
            sizeBytes: e.sizeBytes,
            videoInfo: videoInfoByName[e.name!],
          ),
      ], [
        list,
      ]);
      autoAddedList = list;
      autoAddedCount = uploaded.length;
    } catch (_) {
      // The done page falls back to the manual add button.
    }
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
    final retry =
        [for (final t in _tasks) if (t.entry.status == 'failed') t];
    if (retry.isEmpty) return;
    for (final t in retry) {
      t.entry.status = 'ready';
    }
    manifest?.save();
    stage = BatchStage.uploading;
    uploadDone = 0;
    uploadTotal = retry.length;
    notifyListeners();
    unawaited(_upload(retry));
  }

  /// Abort whatever is running and forget the session (any uploads
  /// already paid for stay in the ledger and on the network).
  void clear() {
    // A fully successful batch is closed for good when the user leaves
    // the done page — its whole work dir goes (manifest, datamaps,
    // bundle, encode leftovers). Nothing load-bearing lives there:
    // library entries, the files on the network, root maps in the
    // embedded client's store, and the dedup hashes in the shared
    // ledger all sit elsewhere, so finished batches leave no records
    // to pile up.
    if (stage == BatchStage.done &&
        failedCount == 0 &&
        attentionCount == 0 &&
        workDir != null) {
      try {
        workDir!.deleteSync(recursive: true);
      } catch (_) {}
    }
    _aborted = true;
    _mb?.close();
    _tmdb?.close();
    _ffmpeg?.cancel();
    _mb = null;
    _tmdb = null;
    _matcher = null;
    _ledger = null;
    _api = null;
    _ffmpeg = null;
    manifest = null;
    workDir = null;
    stage = BatchStage.idle;
    confirmables.clear();
    confirmIndex = 0;
    _confirmPhase = false;
    videoProbes.clear();
    tiers = {};
    _tiersInitialized = false;
    videoInfoByName.clear();
    _tasks = [];
    costEstimate = null;
    estimateError = null;
    prepareError = null;
    balances = null;
    bundlePath = null;
    autoAddedList = null;
    autoAddedCount = 0;
    prepareDone = prepareTotal = 0;
    uploadDone = uploadTotal = 0;
    currentFile = null;
    prepareStep = null;
    hashFraction = null;
    currentUploadName = null;
    currentJob = null;
    encodeFraction = null;
    notifyListeners();
  }
}

enum BatchStage { idle, preparing, review, uploading, done }

/// The per-file legs of the prepare scan, in order: [fingerprint] reads
/// the whole file once for the dedup ledger (the slow leg on big
/// files), [mediaInfo] is the ffprobe pass, [match] the MusicBrainz /
/// TMDB lookup.
enum PrepareStep { fingerprint, mediaInfo, match }

/// One file waiting for the user's eyes — the CLI's beets-style confirm
/// prompt as data. Every action funnels back through Matcher.matchFile
/// with a synthetic sidecar, exactly like the terminal loop. Lives in
/// the session's [BatchUploadSession.confirmables] carousel; once
/// [decided], reopening it and answering again replaces the earlier
/// manifest record.
class BatchConfirm {
  BatchConfirm._(this.path, this.probe, this.outcome, this.sha, this.size);

  final String path;
  final MediaProbe? probe;
  final String sha;
  final int size;
  MatchOutcome outcome;
  List<MbSearchHit>? mbHits;
  List<TmdbHit>? tmdbHits;
  bool busy = false;
  bool decided = false;
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

/// One planned upload: a manifest entry, optionally through a quality
/// tier's encode first.
class _UploadTask {
  _UploadTask(this.entry, {this.tierItem});

  final ManifestEntry entry;
  final plan.PublishItem? tierItem;

  /// Finished encode output, kept across a failed upload for the retry.
  String? tempPath;

  void deleteTemp() {
    final path = tempPath;
    tempPath = null;
    if (path == null) return;
    try {
      File(path).deleteSync();
    } catch (_) {}
  }
}

/// A whole album waiting for the user's eyes — one card, one release
/// decision, applied to every track. Search/paste-id/manual actions
/// re-resolve ALL tracks so an album can never end up split across
/// releases.
class AlbumConfirm {
  AlbumConfirm._(this.tracks, this.probes, this.shas, this.sizes,
      this.outcomes, this.album, this.defaults);

  /// Source paths in album order (disc, then track number).
  final List<String> tracks;
  final List<MediaProbe?> probes;
  final List<String> shas;
  final List<int> sizes;

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
  bool decided = false;

  /// "Artist — Album (Year)" from the representative note (the note's
  /// leading segment before its ", track N" suffix).
  String? get albumLine {
    final note = album?.note;
    if (note == null) return null;
    final cut = note.indexOf(', track ');
    return cut < 0 ? note : note.substring(0, cut);
  }
}

/// One earlier batch whose manifest still lists needs-attention files —
/// surfaced on the Upload/Batch setup pages so they stop being
/// forgotten. Only files that still exist on disk count.
class AttentionBatch {
  AttentionBatch(this.workDir, this.listName, this.sources);

  final Directory workDir;
  final String listName;

  /// Source paths of the needs-attention entries, existing files only.
  final List<String> sources;
}

/// Scan `<support>/batch_uploads/*/watchit-manifest.yaml` for batches
/// with unresolved needs-attention entries. Reviewing one re-runs
/// prepare over just those files in the batch's own work dir, under its
/// original list.
Future<List<AttentionBatch>> scanAttentionBatches(Directory root) async => [
      for (final b in await scanPreviousBatches(root))
        if (b.needsAttention)
          AttentionBatch(b.workDir, b.listName, b.attentionSources),
    ];

/// One earlier batch's work dir + manifest summary — the setup page's
/// "Previous uploads" management list. Every batch with a readable
/// manifest appears (finished ones too), so old runs can be reviewed,
/// dismissed, or deleted instead of silently piling up on disk.
class PreviousBatch {
  PreviousBatch(
      this.workDir, this.listName, this.created, this.counts,
      this.attentionSources, this.resumableSources, this.uploadedShas);

  final Directory workDir;
  final String listName;

  /// The manifest's creation time, null when it never recorded one.
  final DateTime? created;

  /// Entry count per manifest status (`uploaded`, `needs-attention`…).
  final Map<String, int> counts;

  /// Source paths of the needs-attention entries, existing files only —
  /// what the Review button re-runs prepare over.
  final List<String> attentionSources;

  /// Source paths of the still-`ready` (and `failed`) entries whose
  /// file still exists — an interrupted upload the Continue button can
  /// resume.
  final List<String> resumableSources;

  /// Content hashes of the batch's uploaded/deduped entries — what the
  /// Delete dialog's "also forget" opt-in removes from the shared
  /// ledger.
  final List<String> uploadedShas;

  bool get needsAttention => attentionSources.isNotEmpty;

  /// The batch was cut short mid-upload — something matched and paid-
  /// for-nothing-yet is still waiting to go up.
  bool get interrupted => resumableSources.isNotEmpty;

  /// Nothing left to do: every entry is uploaded, deduped, or skipped
  /// (and no attention/resumable file survives on disk). Finished
  /// batches are records, not work — the setup page hides them.
  bool get finished => !needsAttention && !interrupted;
}

/// Every batch work dir under [root] with a readable manifest, newest
/// first.
Future<List<PreviousBatch>> scanPreviousBatches(Directory root) async {
  final result = <PreviousBatch>[];
  try {
    if (!root.existsSync()) return result;
    for (final dir in root.listSync()) {
      if (dir is! Directory) continue;
      final file = File(p.join(dir.path, 'watchit-manifest.yaml'));
      if (!file.existsSync()) continue;
      try {
        final m = Manifest.load(file);
        final counts = <String, int>{};
        for (final e in m.entries) {
          counts[e.status] = (counts[e.status] ?? 0) + 1;
        }
        result.add(PreviousBatch(
          dir,
          m.listName,
          DateTime.tryParse(m.created ?? ''),
          counts,
          [
            for (final e in m.entries)
              if (e.status == 'needs-attention' &&
                  File(e.source).existsSync())
                e.source,
          ],
          [
            for (final e in m.entries)
              if ((e.status == 'ready' || e.status == 'failed') &&
                  File(e.source).existsSync())
                e.source,
          ],
          [
            for (final e in m.entries)
              if ((e.status == 'uploaded' ||
                      e.status == 'already-uploaded') &&
                  e.sha256 != null)
                e.sha256!,
          ],
        ));
      } catch (_) {
        // Unreadable manifest — skip the batch.
      }
    }
  } catch (_) {}
  result.sort((a, b) => (b.created ?? DateTime(0))
      .compareTo(a.created ?? DateTime(0)));
  return result;
}

/// Batches an interrupted upload left waiting — still-`ready` (or
/// `failed`) files whose source exists — newest first. What the
/// startup resume prompt offers to continue after a crash or
/// unexpected shutdown.
Future<List<PreviousBatch>> scanInterruptedBatches(
        Directory root) async =>
    [
      for (final b in await scanPreviousBatches(root))
        if (b.interrupted) b,
    ];

/// Delete every fully finished batch under [root] (all entries
/// uploaded, deduped, or skipped). A finished batch's work dir holds
/// nothing load-bearing — playback addresses live in the library, root
/// maps in the embedded client's store, dedup hashes in the shared
/// ledger — so finished batches are swept on sight instead of piling
/// up as records (user decision 2026-09-02; the Delete dialog's "also
/// forget" opt-in is knowingly given up with them). [keepPath]
/// protects the live session's own work dir. Returns batches removed.
Future<int> deleteFinishedBatches(Directory root,
    {String? keepPath}) async {
  var removed = 0;
  for (final b in await scanPreviousBatches(root)) {
    if (!b.finished) continue;
    if (keepPath != null && p.equals(b.workDir.path, keepPath)) continue;
    try {
      b.workDir.deleteSync(recursive: true);
      removed++;
    } catch (_) {}
  }
  return removed;
}

/// Dismiss [batch]: its needs-attention entries are marked `skipped` in
/// the manifest, so the attention scan stops surfacing it. Uploads stay
/// in the ledger and the files can always go through a fresh batch
/// later — but with nothing left to do the batch counts as finished,
/// and the next scan sweeps its records away.
void dismissBatch(PreviousBatch batch) {
  final file =
      File(p.join(batch.workDir.path, 'watchit-manifest.yaml'));
  final m = Manifest.load(file);
  for (final e in m.entries) {
    if (e.status == 'needs-attention') e.status = 'skipped';
  }
  m.save();
}

/// Delete [batch]'s whole work dir — manifest, datamaps, bundle, art,
/// and any encode leftovers. Uploaded files themselves live on the
/// network (and in the shared ledger), so they are never re-paid even
/// after their batch records are gone.
void deleteBatch(PreviousBatch batch) {
  try {
    batch.workDir.deleteSync(recursive: true);
  } catch (_) {}
}

/// The explicit "forget these uploads" opt-in on the Delete dialog:
/// drop [batch]'s content hashes from the shared upload ledger, so
/// nothing in the app remembers those files were ever uploaded.
/// Deliberately NOT tied to deleting media from the library — the
/// bytes on the network are permanent either way, and a kept ledger
/// row is what makes re-adding a file free. A forgotten file put
/// through a new batch is uploaded and PAID FOR again. Returns how
/// many ledger rows were removed.
int forgetUploads(PreviousBatch batch, {Directory? configDir}) {
  if (batch.uploadedShas.isEmpty) return 0;
  try {
    final ledger =
        Ledger.load(CliConfig.load(home: configDir).ledgerFile);
    return ledger.removeAll(batch.uploadedShas);
  } catch (_) {
    return 0;
  }
}

/// Directory name for a new batch under `<support>/batch_uploads`: the
/// list-name slug plus a start timestamp, so every batch gets a FRESH
/// work dir. Reusing one dir per list made every later stage of a new
/// batch walk the old batch's manifest too — stale counts, and
/// abandoned `ready` files joining the estimate and the paid upload.
/// Cross-batch dedup is the content-hash ledger's job, not the
/// manifest's.
String batchDirName(String listName, {DateTime? now}) {
  final slug = listName
      .replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_')
      .trim()
      .replaceAll(' ', '-');
  final t = now ?? DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${slug.isEmpty ? 'batch' : slug}-'
      '${t.year}${two(t.month)}${two(t.day)}-'
      '${two(t.hour)}${two(t.minute)}${two(t.second)}';
}
