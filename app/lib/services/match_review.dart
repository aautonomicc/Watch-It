import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:watchit_upload/watchit_upload.dart';

/// The match-review carousel core, shared by the batch uploader
/// ([BatchUploadSession]) and the datamap import flow
/// ([ImportReviewSession]): a queue of [BatchConfirm]/[AlbumConfirm]
/// cards with back/forward navigation, and every confirm action —
/// accept/skip/reject, manual search, paste-id, manual entry, the
/// music/video flip — funnelling back through the matcher exactly like
/// the CLI's terminal loop. What a decision *means* (a manifest entry,
/// a library rename) is the subclass's business via the record hooks.
abstract class MatchReviewSession extends ChangeNotifier {
  /// Everything that needs the user's eyes, in scan order — a
  /// [BatchConfirm] per lone file, an [AlbumConfirm] per album group.
  /// Decided cards stay navigable so an earlier answer can be replaced.
  final List<Object> confirmables = [];
  int confirmIndex = 0;

  /// The carousel phase is on (subclass flips it when its scan ends
  /// with undecided cards, or when a card is reopened).
  @protected
  bool confirmPhase = false;

  /// The carousel is showing (cards to review, phase on).
  bool get reviewingMatches => confirmPhase && confirmables.isNotEmpty;

  Object? get _currentConfirmable =>
      confirmPhase && confirmIndex < confirmables.length
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

  int get undecidedConfirmCount => confirmables.where(isUndecided).length;

  static bool isUndecided(Object c) => switch (c) {
        final BatchConfirm f => !f.decided,
        final AlbumConfirm a => !a.decided,
        _ => false,
      };

  // ── subclass hooks ───────────────────────────────────────────────────

  /// Run the matcher (or a test override) over one file/name.
  @protected
  Future<MatchOutcome> runMatch(String path, MediaProbe? probe,
      {Sidecar? sidecar, String? forcedType});

  /// The MusicBrainz client for manual album/track searches, null when
  /// the session isn't running.
  @protected
  MusicBrainz? get mbClient;

  /// The TMDB client for manual video searches, null when no key.
  @protected
  Tmdb? get tmdbClient;

  /// Persist the decision for one file card.
  @protected
  void recordConfirmDecision(BatchConfirm c, MatchOutcome outcome);

  /// Persist the decision for one album card (index-aligned with
  /// [AlbumConfirm.tracks]; null = no outcome for that track).
  @protected
  void recordAlbumDecision(AlbumConfirm c, List<MatchOutcome?> outcomes);

  /// Every card decided — leave the carousel for whatever comes next.
  @protected
  Future<void> onReviewFinished();

  // ── UI wording (import overrides the upload defaults) ────────────────

  /// The reject action: what "no database match" means here.
  String get rejectFileLabel => 'No match';
  String get rejectAlbumLabel => 'No match';

  /// The skip action: leave this file/album out entirely.
  String get skipFileLabel => 'Skip file';
  String get skipAlbumLabel => 'Skip album';

  /// The manual-entry dialog's explainer line.
  String get manualEntryBlurb =>
      'For content not in any database — home videos, personal '
      'recordings, unreleased work. The details travel in the '
      'list bundle so every device shows them.';

  // ── carousel navigation ──────────────────────────────────────────────

  /// Show another card of the queue (back/forward arrows). Decided
  /// cards reopen with their answer replaceable.
  void confirmGoTo(int index) {
    if (!confirmPhase || confirmables.isEmpty) return;
    confirmIndex = index.clamp(0, confirmables.length - 1);
    notifyListeners();
  }

  void confirmPrevious() => confirmGoTo(confirmIndex - 1);
  void confirmNext() => confirmGoTo(confirmIndex + 1);

  /// Leave the carousel — only once every card has an answer.
  void finishConfirms() {
    if (!confirmPhase || confirmables.any(isUndecided)) return;
    unawaited(onReviewFinished());
  }

  /// Record the decision for the current card and move on: to the next
  /// unanswered card, or (none left) out of the carousel.
  void _decideCurrent(BatchConfirm c, MatchOutcome outcome) {
    recordConfirmDecision(c, outcome);
    c.decided = true;
    _advanceConfirm();
  }

  void _decideAlbum(AlbumConfirm c, List<MatchOutcome?> result) {
    recordAlbumDecision(c, result);
    c.decided = true;
    _advanceConfirm();
  }

  void _advanceConfirm() {
    for (var i = confirmIndex + 1; i < confirmables.length; i++) {
      if (isUndecided(confirmables[i])) {
        confirmIndex = i;
        notifyListeners();
        return;
      }
    }
    final first = confirmables.indexWhere(isUndecided);
    if (first >= 0) {
      confirmIndex = first;
      notifyListeners();
      return;
    }
    unawaited(onReviewFinished());
  }

  // ── per-file confirm actions ─────────────────────────────────────────

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

  /// Reject: no name for this file — what happens then is the
  /// subclass's record hook's business (needs-attention for uploads,
  /// keep-the-original-name for imports).
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
      final out = await runMatch(c.path, c.probe, forcedType: flipped);
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
    final mb = mbClient;
    if (c == null || c.busy || mb == null) return;
    c.busy = true;
    notifyListeners();
    try {
      c.mbHits = (await mb.searchReleases(artist, album, limit: 8)).toList();
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
    final tmdb = tmdbClient;
    if (c == null || c.busy || tmdb == null) return;
    c.busy = true;
    notifyListeners();
    try {
      c.tmdbHits = (await tmdb.search(title, year: year, tv: tv))
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
  /// userEdited metadata row exactly like the CLI's edited skeleton.
  Future<void> confirmManual(Sidecar sidecar) => _rematchWith(sidecar);

  Future<void> _rematchWith(Sidecar sidecar) async {
    final c = pendingConfirm;
    if (c == null || c.busy) return;
    c.busy = true;
    notifyListeners();
    try {
      final out = await runMatch(c.path, c.probe, sidecar: sidecar);
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

  /// Accept the album as resolved: placed tracks take the release's
  /// names, unplaced ones go through the reject path.
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

  /// Reject: no release for these files.
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
    final mb = mbClient;
    if (c == null || c.busy || mb == null) return;
    c.busy = true;
    notifyListeners();
    try {
      c.mbHits = (await mb.searchReleases(artist, album, limit: 8)).toList();
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
        c.outcomes[i] = await runMatch(c.tracks[i], c.probes[i],
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
        c.outcomes[i] = await runMatch(c.tracks[i], probe,
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
}

/// One file waiting for the user's eyes — the CLI's beets-style confirm
/// prompt as data. Every action funnels back through Matcher.matchFile
/// with a synthetic sidecar, exactly like the terminal loop. Lives in
/// the session's [MatchReviewSession.confirmables] carousel; once
/// [decided], reopening it and answering again replaces the earlier
/// record.
class BatchConfirm {
  BatchConfirm(this.path, this.probe, this.outcome, this.sha, this.size);

  /// Source path (uploads) or the bare media name (datamap imports).
  final String path;
  final MediaProbe? probe;

  /// Content hash — uploads only; imports have no local bytes and use ''.
  final String sha;
  final int size;
  MatchOutcome outcome;
  List<MbSearchHit>? mbHits;
  List<TmdbHit>? tmdbHits;
  bool busy = false;
  bool decided = false;
}

/// A whole album waiting for the user's eyes — one card, one release
/// decision, applied to every track. Search/paste-id/manual actions
/// re-resolve ALL tracks so an album can never end up split across
/// releases.
class AlbumConfirm {
  AlbumConfirm(this.tracks, this.probes, this.shas, this.sizes,
      this.outcomes, this.album, this.defaults);

  /// Source paths/names in album order (disc, then track number).
  final List<String> tracks;
  final List<MediaProbe?> probes;
  final List<String> shas;
  final List<int> sizes;

  /// Per-track outcome as currently resolved; null or unmatched =
  /// couldn't be placed on the release (goes through the reject path on
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
