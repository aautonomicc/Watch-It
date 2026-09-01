import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:watchit_naming/watchit_naming.dart';

import 'acoustid.dart';
import 'config.dart';
import 'musicbrainz.dart';
import 'probe.dart';
import 'sidecar.dart';
import 'tmdb.dart';

/// Outcome of matching one file. The matcher's only job is recovering
/// the database id — the canonical W@tch name is then REGENERATED from
/// the database's own canonical data, never sanitized from the messy
/// source file name.
class MatchOutcome {
  MatchOutcome({
    required this.type,
    this.name,
    this.ids = const {},
    this.method,
    this.confidence, // 'high' | 'confirm' | null (failed)
    this.custom = false,
    this.customFields = const {},
    this.description,
    this.artBytes,
    this.note,
    this.skip = false,
    this.sidecarDefaults = const {},
  });

  final String type; // music | video
  final String? name;
  final Map<String, String> ids;
  final String? method; // tags | fingerprint | search | sidecar
  final String? confidence;
  final bool custom;
  final Map<String, Object?> customFields;
  final String? description;
  final List<int>? artBytes;

  /// Human note for the confirm line / sidecar skeleton.
  final String? note;
  final bool skip;

  /// Pre-fill values for a skeleton when the match failed.
  final Map<String, Object?> sidecarDefaults;

  bool get matched => name != null;
}

const kAudioExtensions = {
  '.flac', '.mp3', '.ogg', '.oga', '.opus', '.m4a', '.wav', '.aac', '.wma'
};
const kVideoExtensions = {
  '.mkv', '.mp4', '.avi', '.mov', '.webm', '.m4v', '.mpg', '.mpeg', '.ts'
};

/// `Artist - Album - 01 Title`-style filename guess when a music file has
/// no tags: best-effort artist/album for the MB search or the skeleton.
({String? artist, String? album, String? title, int? track}) guessMusicName(
    String fileName) {
  final stem = p.basenameWithoutExtension(fileName);
  final parts = stem.split(RegExp(r'\s+-\s+'));
  String? artist, album, title;
  int? track;
  if (parts.length >= 3) {
    artist = parts[0];
    album = parts[1].replaceAll(RegExp(r'\s*\(\d{4}\)\s*$'), '');
    title = parts.sublist(2).join(' - ');
  } else if (parts.length == 2) {
    artist = parts[0];
    title = parts[1];
  } else {
    title = stem;
  }
  final tm = RegExp(r'^(\d{1,3})[\s._-]+(.+)$').firstMatch(title);
  if (tm != null) {
    track = int.parse(tm.group(1)!);
    title = tm.group(2);
  }
  return (artist: artist, album: album, title: title, track: track);
}

/// Key that groups audio files into one album for album-at-a-time
/// review: an embedded MusicBrainz release id wins, then normalized
/// artist/album tags, then the `Artist - Album - NN Title` filename
/// guess, then the parent directory (one folder = one album for
/// untagged, unparseable rips).
String albumGroupKey(String path, MediaProbe? probe) {
  String norm(String s) => s.trim().toLowerCase();
  final mbid = probe?.releaseMbid;
  if (mbid != null) return 'mbid:${norm(mbid)}';
  final artist = probe?.tag('album_artist') ?? probe?.tag('artist');
  final album = probe?.tag('album');
  if (album != null && album.trim().isNotEmpty) {
    return 'tags:${norm(artist ?? '')}:${norm(album)}';
  }
  final guess = guessMusicName(p.basename(path));
  if (guess.album != null) {
    return 'guess:${norm(guess.artist ?? '')}:${norm(guess.album!)}';
  }
  return 'dir:${p.dirname(path)}';
}

class Matcher {
  Matcher({
    required this.config,
    required this.mb,
    this.tmdb,
    this.fpcalcPresent = false,
  });

  final CliConfig config;
  final MusicBrainz mb;
  final Tmdb? tmdb;
  final bool fpcalcPresent;

  /// Match one file. [probe] may be null (ffprobe missing) — extension
  /// classification still applies.
  Future<MatchOutcome> matchFile(String path, MediaProbe? probe,
      {Sidecar? sidecar, String? forcedType}) async {
    final ext = p.extension(path).toLowerCase();
    var type = forcedType ??
        sidecar?.type ??
        (kAudioExtensions.contains(ext)
            ? 'music'
            : (probe != null && probe.isMusic ? 'music' : 'video'));

    if (sidecar != null) {
      if (sidecar.skip) {
        return MatchOutcome(type: type, skip: true, note: 'sidecar: skip');
      }
      final fromSidecar = await _fromSidecar(path, sidecar, probe, type);
      if (fromSidecar != null) return fromSidecar;
    }

    return type == 'music'
        ? _matchMusic(path, probe)
        : _matchVideo(path, probe);
  }

  Future<MatchOutcome?> _fromSidecar(
      String path, Sidecar s, MediaProbe? probe, String type) async {
    final ext = p.extension(path).replaceFirst('.', '');
    if (s.releaseMbid != null) {
      final release = await mb.release(s.releaseMbid!);
      if (release == null) {
        return MatchOutcome(
            type: 'music',
            note: 'sidecar release_mbid ${s.releaseMbid} not found on '
                'MusicBrainz');
      }
      return _fromRelease(release,
          track: s.track ?? probe?.trackNumber,
          disc: probe?.discNumber,
          recordingMbid: probe?.recordingMbid,
          // Untagged, unnumbered tracks can still place by title.
          titleHint: probe?.tag('title') ??
              guessMusicName(p.basename(path)).title,
          ext: ext,
          method: 'sidecar',
          description: s.description,
          artPath: s.art);
    }
    if (s.imdb != null || s.tmdb != null) {
      if (tmdb == null) {
        return MatchOutcome(
            type: 'video',
            note: 'sidecar has a database id but no TMDB key is '
                'configured (tmdb_key in ~/.watchit-upload/config.yaml)');
      }
      TmdbHit? hit;
      if (s.imdb != null) {
        hit = await tmdb!.findByImdb(s.imdb!);
      } else {
        hit = await tmdb!.byId(s.tmdb!, tv: s.tmdbTv);
        hit?.imdbId = await tmdb!.imdbIdOf(s.tmdb!, tv: s.tmdbTv);
      }
      if (hit == null) {
        return MatchOutcome(type: 'video', note: 'sidecar id not found');
      }
      return _fromTmdbHit(hit, path, probe,
          season: s.season, episode: s.episode,
          method: 'sidecar', description: s.description, artPath: s.art);
    }
    if (s.isManualEntry) {
      return _manualEntry(path, s, probe, type);
    }
    return null; // Sidecar carried nothing usable; fall through to auto.
  }

  /// Case B — not in any database: name WITHOUT an id tag (the app rule:
  /// no id tag → skip metadata APIs, use baked-in data), userEdited
  /// metadata row + art baked into the bundle.
  Future<MatchOutcome> _manualEntry(
      String path, Sidecar s, MediaProbe? probe, String type) async {
    final ext = p.extension(path).replaceFirst('.', '');
    String name;
    final fields = <String, Object?>{};
    if (type == 'music') {
      final artist = s.artist ?? probe?.tag('artist') ?? 'Unknown Artist';
      final album = s.album ?? probe?.tag('album') ?? 'Unknown Album';
      final title = s.title ?? probe?.tag('title') ?? '';
      final track = s.track ?? probe?.trackNumber ?? 1;
      name = musicFileName(
        artist: artist,
        album: album,
        year: s.year ?? probe?.year,
        track: track,
        disc: probe?.discNumber ?? 1,
        discTotal: probe?.discTotal ?? 1,
        title: title,
        ext: ext,
      );
      fields.addAll({
        'artist': artist,
        'album': album,
        'title': title,
        'track': track,
        if (s.year != null || probe?.year != null)
          'year': s.year ?? probe?.year,
      });
    } else {
      name = videoFileName(
        title: s.title!,
        year: s.year,
        season: s.season,
        episode: s.episode,
        height: probe?.height,
        ext: ext,
      );
      fields.addAll({
        'title': s.title,
        if (s.year != null) 'year': s.year,
        if (s.season != null) 'season': s.season,
        if (s.episode != null) 'episode': s.episode,
      });
    }
    List<int>? art;
    if (s.art != null && File(s.art!).existsSync()) {
      art = File(s.art!).readAsBytesSync();
    }
    return MatchOutcome(
      type: type,
      name: name,
      method: 'sidecar',
      confidence: 'high',
      custom: true,
      customFields: fields,
      description: s.description,
      artBytes: art,
    );
  }

  Future<MatchOutcome> _matchMusic(String path, MediaProbe? probe) async {
    final ext = p.extension(path).replaceFirst('.', '');
    final guess = guessMusicName(p.basename(path));

    // (1) Embedded MusicBrainz release id — Picard-tagged files.
    final taggedMbid = probe?.releaseMbid;
    if (taggedMbid != null) {
      final release = await mb.release(taggedMbid);
      if (release != null) {
        final out = await _fromRelease(release,
            track: probe?.trackNumber,
            disc: probe?.discNumber,
            recordingMbid: probe?.recordingMbid,
            titleHint: probe?.tag('title'),
            ext: ext,
            method: 'tags');
        if (out.matched) return out;
      }
    }

    // (2) AcoustID fingerprint (gold standard) when fpcalc + key exist.
    if (fpcalcPresent && config.acoustidKey != null) {
      final hits = await acoustidLookup(path, config.acoustidKey!);
      for (final hit in hits.take(3)) {
        if (hit.score < 0.85) break;
        final releases = await mb.releasesOfRecording(hit.recordingMbid);
        // Prefer a release whose title matches the album tag.
        String? pick;
        final albumTag = probe?.tag('album') ?? guess.album;
        if (albumTag != null && releases.length > 1) {
          for (final rid in releases) {
            final r = await mb.release(rid);
            if (r != null && titleSimilarity(r.title, albumTag) > 0.85) {
              pick = rid;
              break;
            }
          }
        }
        pick ??= releases.isNotEmpty ? releases.first : null;
        if (pick == null) continue;
        final release = await mb.release(pick);
        if (release == null) continue;
        final out = await _fromRelease(release,
            recordingMbid: hit.recordingMbid,
            track: probe?.trackNumber,
            disc: probe?.discNumber,
            titleHint: probe?.tag('title') ?? hit.title,
            ext: ext,
            method: 'fingerprint');
        if (out.matched) return out;
      }
    }

    // (3) MusicBrainz Lucene search from tags (or the filename guess).
    final artist = probe?.tag('album_artist') ??
        probe?.tag('artist') ??
        guess.artist;
    final album = probe?.tag('album') ?? guess.album;
    if (artist != null && album != null) {
      final hits = await mb.searchReleases(artist, album);
      if (hits.isNotEmpty && hits.first.score >= 90) {
        final release = await mb.release(hits.first.mbid);
        if (release != null) {
          final out = await _fromRelease(release,
              track: probe?.trackNumber ?? guess.track,
              disc: probe?.discNumber,
              titleHint: probe?.tag('title') ?? guess.title,
              ext: ext,
              method: 'search',
              // Search matches always get eyes-on (uploads are paid +
              // immutable); tag/fingerprint id matches can auto-accept.
              confidence: 'confirm');
          if (out.matched) return out;
        }
      }
    }

    return MatchOutcome(
      type: 'music',
      note: 'no MusicBrainz match — fill the sidecar '
          '(id, or manual fields for personal recordings)',
      sidecarDefaults: {
        'artist': probe?.tag('artist') ?? guess.artist,
        'album': probe?.tag('album') ?? guess.album,
        'title': probe?.tag('title') ?? guess.title,
        'track': probe?.trackNumber ?? guess.track,
        'year': probe?.year,
      },
    );
  }

  /// Name a track from a fetched release. Track resolution order:
  /// recording mbid → (disc, position) → title similarity.
  Future<MatchOutcome> _fromRelease(
    MbRelease release, {
    int? track,
    int? disc,
    String? recordingMbid,
    String? titleHint,
    required String ext,
    required String method,
    String? confidence,
    String? description,
    String? artPath,
  }) async {
    var hit = release.trackAt(
        recordingMbid: recordingMbid, position: track, disc: disc);
    if (hit == null && titleHint != null) {
      MbTrack? best;
      var bestScore = 0.0;
      for (final t in release.tracks) {
        final s = titleSimilarity(t.title, titleHint);
        if (s > bestScore) {
          bestScore = s;
          best = t;
        }
      }
      if (bestScore > 0.8) hit = best;
    }
    if (hit == null) {
      return MatchOutcome(
          type: 'music',
          note: 'release "${release.title}" matched but the track could '
              'not be placed on it (set `track:` in the sidecar)');
    }
    final name = musicFileName(
      artist: release.artistCredit,
      album: release.title,
      year: release.year,
      track: hit.position,
      disc: hit.disc,
      discTotal: release.discCount,
      title: hit.title,
      releaseMbid: release.mbid,
      ext: ext,
    );
    List<int>? art = artPath != null && File(artPath).existsSync()
        ? File(artPath).readAsBytesSync()
        : await mb.caaFrontCover(release.mbid);
    return MatchOutcome(
      type: 'music',
      name: name,
      ids: {
        'release_mbid': release.mbid,
        if (hit.recordingMbid != null) 'recording_mbid': hit.recordingMbid!,
      },
      method: method,
      confidence: confidence ?? 'high',
      description: description,
      artBytes: art,
      note: '${release.artistCredit} — ${release.title}'
          '${release.year != null ? ' (${release.year})' : ''}, '
          'track ${hit.disc > 1 ? '${hit.disc}-' : ''}${hit.position} '
          '"${hit.title}"',
    );
  }

  Future<MatchOutcome> _matchVideo(String path, MediaProbe? probe) async {
    final parsed = parseMediaName(p.basename(path));
    if (tmdb == null) {
      return MatchOutcome(
        type: 'video',
        note: 'no TMDB key configured — set tmdb_key in '
            '~/.watchit-upload/config.yaml (or TMDB_API_KEY)',
        sidecarDefaults: {
          'title': parsed.title,
          'year': parsed.year,
          'season': parsed.season,
          'episode': parsed.episode,
        },
      );
    }

    // Exact path: embedded imdb tag.
    if (parsed.imdbId != null) {
      final hit = await tmdb!.findByImdb(parsed.imdbId!);
      if (hit != null) {
        return _fromTmdbHit(hit, path, probe,
            season: parsed.season, episode: parsed.episode, method: 'tags');
      }
    }

    // Fuzzy: title/year search, scored by similarity + year.
    final tv = parsed.isEpisode;
    var hits = await tmdb!.search(parsed.title, year: parsed.year, tv: tv);
    if (hits.isEmpty && parsed.year != null) {
      hits = await tmdb!.search(parsed.title, tv: tv);
    }
    TmdbHit? best;
    var bestScore = 0.0;
    for (final h in hits.take(8)) {
      var score = titleSimilarity(h.title, parsed.title) * 0.8;
      if (parsed.year != null && h.year != null) {
        final dy = (parsed.year! - h.year!).abs();
        score += dy == 0 ? 0.2 : (dy == 1 ? 0.1 : 0.0);
      } else {
        score += 0.1;
      }
      if (score > bestScore) {
        bestScore = score;
        best = h;
      }
    }
    if (best == null || bestScore < 0.5) {
      return MatchOutcome(
        type: 'video',
        note: 'no TMDB match for "${parsed.title}"'
            '${parsed.year != null ? ' (${parsed.year})' : ''}',
        sidecarDefaults: {
          'title': parsed.title,
          'year': parsed.year,
          'season': parsed.season,
          'episode': parsed.episode,
        },
      );
    }
    best.imdbId ??= await tmdb!.imdbIdOf(best.tmdbId, tv: tv);
    return _fromTmdbHit(best, path, probe,
        season: parsed.season,
        episode: parsed.episode,
        method: 'search',
        confidence: bestScore >= 0.85 ? 'high' : 'confirm');
  }

  Future<MatchOutcome> _fromTmdbHit(
    TmdbHit hit,
    String path,
    MediaProbe? probe, {
    int? season,
    int? episode,
    required String method,
    String? confidence,
    String? description,
    String? artPath,
  }) async {
    final ext = p.extension(path).replaceFirst('.', '');
    final tvWithMarker = hit.mediaType == 'tv' || season != null;
    final name = videoFileName(
      title: hit.title,
      year: hit.year,
      imdbId: hit.imdbId,
      season: tvWithMarker ? season : null,
      episode: tvWithMarker ? episode : null,
      height: probe?.height,
      ext: ext,
    );
    List<int>? art = artPath != null && File(artPath).existsSync()
        ? File(artPath).readAsBytesSync()
        : (hit.posterPath != null ? await tmdb!.poster(hit.posterPath!) : null);
    return MatchOutcome(
      type: 'video',
      name: name,
      ids: {
        'tmdb': '${hit.mediaType}:${hit.tmdbId}',
        if (hit.imdbId != null) 'imdb': hit.imdbId!,
      },
      method: method,
      confidence: confidence ?? 'high',
      description: description,
      artBytes: art,
      note: '${hit.title}${hit.year != null ? ' (${hit.year})' : ''} '
          '[${hit.mediaType}${hit.imdbId != null ? ', ${hit.imdbId}' : ''}]',
    );
  }
}
