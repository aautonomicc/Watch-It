import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:watchit_naming/watchit_naming.dart' show parseMediaName;
import 'package:watchit_upload/watchit_upload.dart';

import '../models/media_list.dart';
import 'bundle.dart' show seedMetadataGapFill;
import 'library_store.dart' show addEntriesToLists;
import 'match_review.dart';

/// The datamap import counterpart of the batch uploader's prepare pass
/// (2026-09-02 decision): imported `.datamap` entries go through the
/// SAME matcher and review carousel as uploads — auto-tag everything
/// that matches cleanly, one look for the rest, manual details for
/// content in no database — so imports land sorted music/video with
/// canonical names, artwork and descriptions instead of raw video-guess
/// entries.
///
/// The one structural difference from uploads: there is no local file,
/// only the name the datamap arrived under. Matching is name-driven —
/// `Matcher.matchFile` with a null probe (it never reads the media
/// itself), plus a fast path for canonical W@tch names whose embedded
/// `{mbid-…}` release id becomes an id-backed sidecar match (video
/// `{imdb-tt…}` tags already resolve by id from the name alone). A
/// decision renames the entry to its canonical W@tch name — matched
/// ids then self-hydrate metadata and artwork through the app's
/// normal metadata matcher; manual (case-B) details seed the local
/// metadata cache the same way a bundle's userEdited rows do. Rejecting
/// keeps the original name (exactly what import did before this flow),
/// skipping leaves that datamap out of the library.
///
/// Lives outside the screen (survive-navigation pattern), one session
/// at a time, like [BatchUploadSession].
class ImportReviewSession extends MatchReviewSession {
  ImportReviewSession._();

  static ImportReviewSession instance = ImportReviewSession._();

  @visibleForTesting
  static void resetForTesting() {
    instance._aborted = true;
    instance = ImportReviewSession._();
  }

  ImportReviewStage stage = ImportReviewStage.idle;
  bool get idle => stage == ImportReviewStage.idle;

  final List<ImportItem> items = [];
  List<String> listTitles = const [];

  MusicBrainz? _mb;
  Tmdb? _tmdb;
  Matcher? _matcher;
  bool _aborted = false;

  /// Which card decides which items (album cards index-align with
  /// [AlbumConfirm.tracks]) — identity-keyed, so duplicate names in one
  /// pick can never cross wires.
  final Map<Object, List<ImportItem>> _itemsByConfirm = {};

  // ── progress / results ───────────────────────────────────────────────
  int matchDone = 0;
  int matchTotal = 0;
  String? currentName;

  /// Entries actually added to the library by the apply step.
  int addedCount = 0;
  String? applyError;

  int _countOf(String status) =>
      items.where((i) => i.status == status).length;

  /// Renamed to a database match / manual details entered / kept under
  /// the original name / left out.
  int get matchedCount => _countOf('matched');
  int get customCount => _countOf('custom');
  int get asIsCount => _countOf('as-is') + _countOf('pending');
  int get skippedCount => _countOf('skipped');

  /// Test overrides.
  @visibleForTesting
  Future<MatchOutcome> Function(String path, MediaProbe? probe,
      {Sidecar? sidecar, String? forcedType})? matchOverride;
  @visibleForTesting
  Future<void> Function(List<MediaEntry> entries, List<String> lists)?
      addOverride;
  @visibleForTesting
  Future<Directory> Function()? postersDirProvider;

  @override
  Future<MatchOutcome> runMatch(String path, MediaProbe? probe,
          {Sidecar? sidecar, String? forcedType}) =>
      matchOverride?.call(path, probe,
          sidecar: sidecar, forcedType: forcedType) ??
      _matcher!.matchFile(path, probe,
          sidecar: sidecar, forcedType: forcedType);

  @override
  MusicBrainz? get mbClient => _mb;

  @override
  Tmdb? get tmdbClient => _tmdb;

  // Import wording: rejecting a match keeps the datamap's own name;
  // skipping leaves it out of the library entirely.
  @override
  String get rejectFileLabel => 'Keep name as-is';
  @override
  String get rejectAlbumLabel => 'Keep names as-is';
  @override
  String get skipFileLabel => 'Don\'t add';
  @override
  String get skipAlbumLabel => 'Don\'t add album';
  @override
  String get manualEntryBlurb =>
      'For content not in any database — home videos, personal '
      'recordings, unreleased work. The details are saved on this '
      'device and shown in your library.';

  /// Kick off name matching over the imported datamaps. [tmdbKey] comes
  /// from Settings → Metadata, falling back to the CLI config;
  /// [configDir] overrides `~/.watchit-upload` (tests, and platforms
  /// without a HOME).
  Future<void> start({
    required List<ImportCandidate> files,
    required List<String> lists,
    String? tmdbKey,
    Directory? configDir,
  }) async {
    assert(idle);
    _aborted = false;
    listTitles = List.of(lists);
    items
      ..clear()
      ..addAll([for (final f in files) ImportItem(f)]);
    confirmables.clear();
    confirmIndex = 0;
    confirmPhase = false;
    _itemsByConfirm.clear();
    final config = CliConfig.load(home: configDir)..ensureDirs();
    _mb = MusicBrainz(cacheDir: config.mbCacheDir);
    final key = (tmdbKey == null || tmdbKey.trim().isEmpty)
        ? config.tmdbKey
        : tmdbKey.trim();
    _tmdb = key == null ? null : Tmdb(key);
    _matcher = Matcher(config: config, mb: _mb!, tmdb: _tmdb);
    stage = ImportReviewStage.matching;
    matchDone = 0;
    matchTotal = files.length;
    currentName = null;
    addedCount = 0;
    applyError = null;
    notifyListeners();
    unawaited(_matchAll());
  }

  /// The prepare pass: albums grouped by the name-derived key and
  /// reviewed one release at a time, everything else per file — the
  /// uploader's scan minus fingerprint/probe (no local bytes).
  Future<void> _matchAll() async {
    try {
      final albums = <String, List<ImportItem>>{};
      final loners = <ImportItem>[];
      for (final item in items) {
        final key = importAlbumKey(item.candidate.name);
        key == null
            ? loners.add(item)
            : albums.putIfAbsent(key, () => []).add(item);
      }
      for (final item in loners) {
        if (_aborted) return;
        await _matchOne(item);
      }
      for (final group in albums.values) {
        if (_aborted) return;
        if (group.length == 1) {
          // A lone track keeps the per-file card (incl. the
          // music/video toggle).
          await _matchOne(group.single);
        } else {
          await _matchAlbum(group);
        }
      }
      currentName = null;
      if (_aborted) return;
      if (confirmables.any(MatchReviewSession.isUndecided)) {
        confirmPhase = true;
        confirmIndex =
            confirmables.indexWhere(MatchReviewSession.isUndecided);
        stage = ImportReviewStage.reviewing;
        notifyListeners();
      } else {
        await onReviewFinished();
      }
    } catch (e) {
      if (_aborted) return;
      // A broken matcher setup shouldn't strand the import — everything
      // still undecided goes in under its original name.
      applyError ??= '$e';
      await finishRemainingAsIs();
    }
  }

  Future<void> _matchOne(ImportItem item) async {
    currentName = item.candidate.name;
    notifyListeners();
    final out = await _tryMatch(item.candidate.name);
    if (_aborted) return;
    final autoAccept = out.matched &&
        out.confidence == 'high' &&
        out.method != 'search';
    final confirm =
        BatchConfirm(item.candidate.name, null, out, '', 0);
    _itemsByConfirm[confirm] = [item];
    if (autoAccept) {
      _applyOutcome(item, out);
      confirm.decided = true;
    }
    confirmables.add(confirm);
    matchDone++;
    notifyListeners();
  }

  /// Match one name, id fast path first; a thrown lookup (offline, API
  /// down) becomes a reviewable no-match card instead of killing the
  /// import.
  Future<MatchOutcome> _tryMatch(String name) async {
    try {
      return await runMatch(name, null, sidecar: _sidecarFromName(name));
    } catch (e) {
      final guess = guessMusicName(name);
      final parsed = parseMediaName(name);
      final music =
          kAudioExtensions.contains(p.extension(name).toLowerCase());
      return MatchOutcome(
        type: music ? 'music' : 'video',
        note: 'lookup failed: $e',
        sidecarDefaults: music
            ? {
                'artist': guess.artist,
                'album': guess.album,
                'title': guess.title,
                'track': guess.track,
              }
            : {
                'title': parsed.title,
                'year': parsed.year,
                'season': parsed.season,
                'episode': parsed.episode,
              },
      );
    }
  }

  /// The canonical-name fast path: a `{mbid-…}` release id in the name
  /// becomes an id-backed sidecar match (high confidence, auto-accept)
  /// — the matcher only reads embedded ids from ffprobe tags, which
  /// imports don't have. Video `{imdb-tt…}` tags need no sidecar; the
  /// matcher's name parse already resolves those by id.
  Sidecar? _sidecarFromName(String name) {
    final parsed = parseMediaName(name);
    if (parsed.releaseMbid == null || !parsed.isAudio) return null;
    return Sidecar(
        type: 'music', releaseMbid: parsed.releaseMbid, track: parsed.track);
  }

  /// One album group: find the release once (names carrying an mbid get
  /// first say), resolve every track against it, then either record it
  /// whole or queue ONE [AlbumConfirm] — the uploader's album leg,
  /// name-driven.
  Future<void> _matchAlbum(List<ImportItem> group) async {
    int trackNo(ImportItem it) =>
        parseMediaName(it.candidate.name).track ??
        guessMusicName(it.candidate.name).track ??
        1 << 20;
    int discNo(ImportItem it) =>
        parseMediaName(it.candidate.name).disc ?? 1;
    group.sort((a, b) {
      final d = discNo(a).compareTo(discNo(b));
      if (d != 0) return d;
      final t = trackNo(a).compareTo(trackNo(b));
      return t != 0 ? t : a.candidate.name.compareTo(b.candidate.name);
    });

    final order = List.generate(group.length, (i) => i)
      ..sort((a, b) {
        final ta =
            parseMediaName(group[a].candidate.name).releaseMbid != null
                ? 0
                : 1;
        final tb =
            parseMediaName(group[b].candidate.name).releaseMbid != null
                ? 0
                : 1;
        return ta != tb ? ta - tb : a - b;
      });
    final outcomes = List<MatchOutcome?>.filled(group.length, null);
    MatchOutcome? album;
    for (final i in order) {
      currentName = group[i].candidate.name;
      notifyListeners();
      final out = await _tryMatch(group[i].candidate.name);
      if (_aborted) return;
      outcomes[i] = out;
      if (out.matched && out.ids['release_mbid'] != null) {
        album = out;
        break;
      }
    }
    final mbid = album?.ids['release_mbid'];
    if (mbid != null) {
      for (var i = 0; i < group.length; i++) {
        if (_aborted) return;
        final cur = outcomes[i];
        if (cur != null &&
            cur.matched &&
            cur.ids['release_mbid'] == mbid) {
          continue;
        }
        final name = group[i].candidate.name;
        currentName = name;
        notifyListeners();
        outcomes[i] = await _tryMatch2(name, mbid);
      }
    }

    final allPlaced = outcomes.every((o) => o?.matched ?? false);
    final autoAccept = album != null &&
        album.confidence == 'high' &&
        album.method != 'search' &&
        allPlaced;
    if (autoAccept) {
      for (var i = 0; i < group.length; i++) {
        _applyOutcome(group[i], outcomes[i]!);
      }
    }
    final firstName = group.first.candidate.name;
    final parsed = parseMediaName(firstName);
    final guess = guessMusicName(firstName);
    final confirm = AlbumConfirm(
      [for (final it in group) it.candidate.name],
      [for (final _ in group) null],
      [for (final _ in group) ''],
      [for (final _ in group) 0],
      outcomes,
      album,
      {
        'artist': parsed.artist ?? guess.artist,
        'album': parsed.album ?? guess.album,
        'year': parsed.year,
      },
    )..decided = autoAccept;
    _itemsByConfirm[confirm] = List.of(group);
    confirmables.add(confirm);
    matchDone += group.length;
    notifyListeners();
  }

  /// Resolve one track against a known release, catch-safe like
  /// [_tryMatch].
  Future<MatchOutcome> _tryMatch2(String name, String mbid) async {
    try {
      return await runMatch(name, null,
          sidecar: Sidecar(
            type: 'music',
            releaseMbid: mbid,
            track: parseMediaName(name).track ?? guessMusicName(name).track,
          ));
    } catch (e) {
      return MatchOutcome(type: 'music', note: 'lookup failed: $e');
    }
  }

  void _applyOutcome(ImportItem item, MatchOutcome out) {
    item.outcome = out;
    if (out.skip) {
      item.status = 'skipped';
    } else if (!out.matched) {
      item.status = 'as-is';
    } else {
      item.status = out.custom ? 'custom' : 'matched';
    }
  }

  @override
  void recordConfirmDecision(BatchConfirm c, MatchOutcome outcome) {
    final targets = _itemsByConfirm[c];
    if (targets != null) _applyOutcome(targets.single, outcome);
  }

  @override
  void recordAlbumDecision(AlbumConfirm c, List<MatchOutcome?> result) {
    final targets = _itemsByConfirm[c];
    if (targets == null) return;
    for (var i = 0; i < targets.length; i++) {
      final out = result[i] ??
          MatchOutcome(
              type: 'music',
              note: c.outcomes[i]?.note ?? 'no album match');
      _applyOutcome(targets[i], out);
    }
  }

  @override
  Future<void> onReviewFinished() => _apply();

  /// The escape hatch on both the matching and review pages: stop
  /// looking things up and add everything still undecided under its
  /// original name (exactly what import did before this flow existed).
  Future<void> finishRemainingAsIs() async {
    if (stage != ImportReviewStage.matching &&
        stage != ImportReviewStage.reviewing) {
      return;
    }
    _aborted = true;
    await _apply();
  }

  /// Add nothing at all and forget the session (the datamaps themselves
  /// stay in the embedded client's store — re-importing the same files
  /// is instant).
  void cancelAll() {
    _aborted = true;
    clear();
  }

  /// All decided (or given up on): seed manual details/artwork into the
  /// local metadata cache — the same gap-fill a bundle's userEdited
  /// rows use — then add every kept entry to the chosen lists.
  Future<void> _apply() async {
    if (stage != ImportReviewStage.matching &&
        stage != ImportReviewStage.reviewing) {
      return;
    }
    confirmPhase = false;
    stage = ImportReviewStage.applying;
    notifyListeners();

    final entries = <MediaEntry>[];
    final metadataRows = <String, Map<String, dynamic>>{};
    final posters = <String, Uint8List>{};
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final item in items) {
      final out = item.outcome;
      if (item.status == 'skipped') continue;
      if (item.status == 'matched' || item.status == 'custom') {
        final name = out!.name!;
        entries.add(MediaEntry(
          name: name,
          address: item.candidate.address,
          sizeBytes: item.candidate.sizeBytes,
        ));
        if (out.custom) {
          // Same row shape a case-B upload bakes into its bundle
          // (cli bundle_out.dart) — the app's metadata matcher treats
          // both identically: userEdited rows always win, no id tag
          // means no API lookup ever overwrites them.
          final parsed = parseMediaName(name);
          String? posterFile;
          final art = out.artBytes;
          if (art != null) {
            final artHash =
                sha256.convert(art).toString().substring(0, 12);
            posterFile = 'user_import_$artHash.jpg';
            posters[posterFile] = Uint8List.fromList(art);
          }
          final fields = out.customFields;
          final customTitle = fields['title']?.toString() ??
              ((fields['artist'] != null && fields['album'] != null)
                  ? '${fields['artist']} - ${fields['album']}'
                  : null);
          metadataRows.putIfAbsent(
              parsed.lookupKey,
              () => {
                    'title': customTitle ?? parsed.title,
                    'year': (fields['year'] as int?) ?? parsed.year,
                    'overview': out.description,
                    'episodeLabel': parsed.isEpisode
                        ? 'S${parsed.season.toString().padLeft(2, '0')}'
                            'E${parsed.episode.toString().padLeft(2, '0')}'
                        : null,
                    'posterFile': posterFile,
                    'mediaType': out.type == 'music'
                        ? 'music'
                        : (parsed.isEpisode ? 'tv' : 'movie'),
                    'userEdited': true,
                    'fetchedAt': now,
                  });
        }
      } else {
        // 'as-is' and never-matched 'pending' keep the original name.
        entries.add(MediaEntry(
          name: item.candidate.name,
          address: item.candidate.address,
          sizeBytes: item.candidate.sizeBytes,
        ));
      }
    }

    if (metadataRows.isNotEmpty || posters.isNotEmpty) {
      try {
        await seedMetadataGapFill(metadataRows, posters,
            postersDirProvider: postersDirProvider);
      } catch (e) {
        // Best effort — the entries themselves still go in.
        debugPrint('import metadata seed failed: $e');
      }
    }
    try {
      if (entries.isNotEmpty) {
        await (addOverride ?? addEntriesToLists)(entries, listTitles);
      }
      addedCount = entries.length;
    } catch (e) {
      applyError = '$e';
    }
    stage = ImportReviewStage.done;
    notifyListeners();
  }

  /// Forget the session.
  void clear() {
    _aborted = true;
    _mb?.close();
    _tmdb?.close();
    _mb = null;
    _tmdb = null;
    _matcher = null;
    items.clear();
    listTitles = const [];
    confirmables.clear();
    confirmIndex = 0;
    confirmPhase = false;
    _itemsByConfirm.clear();
    matchDone = matchTotal = 0;
    currentName = null;
    addedCount = 0;
    applyError = null;
    stage = ImportReviewStage.idle;
    notifyListeners();
  }
}

enum ImportReviewStage { idle, matching, reviewing, applying, done }

/// One imported datamap waiting to become a library entry: the media
/// name the `.datamap` file arrived under plus the address the embedded
/// client derived from the map's own bytes.
class ImportCandidate {
  const ImportCandidate(
      {required this.name, required this.address, this.sizeBytes});

  final String name;
  final String address;
  final int? sizeBytes;
}

/// One candidate's place in the review: `pending` until matched, then
/// `matched` (renamed to a database match) / `custom` (manual details)
/// / `as-is` (kept under the original name) / `skipped` (left out).
class ImportItem {
  ImportItem(this.candidate);

  final ImportCandidate candidate;
  String status = 'pending';
  MatchOutcome? outcome;

  /// The name the entry goes into the library under.
  String get finalName => (status == 'matched' || status == 'custom')
      ? outcome!.name!
      : candidate.name;
}

/// Groups audio names into one album for album-at-a-time review — the
/// uploader's albumGroupKey rebuilt from names alone: an embedded
/// `{mbid-…}` release id wins, then the canonical-name parse's
/// artist/album, then the `Artist - Album - NN Title` guess. Bare
/// names with no album signal review alone (there is no parent folder
/// to fall back on), and non-audio names never group.
String? importAlbumKey(String name) {
  if (!kAudioExtensions.contains(p.extension(name).toLowerCase())) {
    return null;
  }
  String norm(String s) => s.trim().toLowerCase();
  final parsed = parseMediaName(name);
  if (parsed.releaseMbid != null) return 'mbid:${norm(parsed.releaseMbid!)}';
  if (parsed.isTrack) {
    return 'name:${norm(parsed.artist ?? '')}:${norm(parsed.title)}'
        ':${parsed.year ?? ''}';
  }
  final guess = guessMusicName(name);
  if (guess.album != null) {
    return 'guess:${norm(guess.artist ?? '')}:${norm(guess.album!)}';
  }
  return null;
}
