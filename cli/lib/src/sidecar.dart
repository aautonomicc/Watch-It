import 'dart:io';

import 'package:yaml/yaml.dart';

/// Sidecar files: `<media file>.watchit.yaml` beside the source. Pass 1
/// of `prepare` writes a pre-filled skeleton for every file it could not
/// match (or whose match was rejected); the user edits, pass 2 consumes.
/// A sidecar beside a file always overrides the auto-match — it is also
/// the fix for a *wrong* auto-match.
class Sidecar {
  Sidecar({
    this.type,
    this.releaseMbid,
    this.track,
    this.imdb,
    this.tmdb,
    this.tmdbTv = false,
    this.title,
    this.year,
    this.artist,
    this.album,
    this.season,
    this.episode,
    this.description,
    this.art,
    this.skip = false,
  });

  final String? type; // music | video
  final String? releaseMbid;
  final int? track;
  final String? imdb;
  final int? tmdb;
  final bool tmdbTv;
  final String? title;
  final int? year;
  final String? artist;
  final String? album;
  final int? season;
  final int? episode;
  final String? description;
  final String? art;
  final bool skip;

  /// Case A: an id was pasted — resolve through the normal database path.
  bool get hasId => releaseMbid != null || imdb != null || tmdb != null;

  /// Case B: full manual entry (home/unreleased/personal content).
  bool get isManualEntry => !hasId && title != null;

  static String pathFor(String mediaPath) => '$mediaPath.watchit.yaml';

  static Sidecar? read(String mediaPath) {
    final file = File(pathFor(mediaPath));
    if (!file.existsSync()) return null;
    final doc = loadYaml(file.readAsStringSync());
    if (doc is! YamlMap) return null;
    String? str(String k) {
      final v = doc[k];
      if (v == null) return null;
      final s = '$v'.trim();
      return s.isEmpty ? null : s;
    }

    int? intOf(String k) => int.tryParse(str(k) ?? '');
    // `tmdb: tv:123` or `tmdb: movie:123` or bare number (movie).
    var tmdbRaw = str('tmdb');
    var tmdbTv = false;
    if (tmdbRaw != null) {
      final m = RegExp(r'^(movie|tv)\s*[:/]\s*(\d+)$').firstMatch(tmdbRaw);
      if (m != null) {
        tmdbTv = m.group(1) == 'tv';
        tmdbRaw = m.group(2);
      }
    }
    var imdb = str('imdb');
    // Accept a full IMDb URL.
    final urlMatch = RegExp(r'tt\d+').firstMatch(imdb ?? '');
    if (urlMatch != null) imdb = urlMatch.group(0);
    var mbid = str('release_mbid');
    final mbidMatch = RegExp(
            r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
            caseSensitive: false)
        .firstMatch(mbid ?? '');
    if (mbidMatch != null) mbid = mbidMatch.group(0)!.toLowerCase();

    return Sidecar(
      type: str('type'),
      releaseMbid: mbid,
      track: intOf('track'),
      imdb: imdb,
      tmdb: int.tryParse(tmdbRaw ?? ''),
      tmdbTv: tmdbTv,
      title: str('title'),
      year: intOf('year'),
      artist: str('artist'),
      album: str('album'),
      season: intOf('season'),
      episode: intOf('episode'),
      description: str('description'),
      art: str('art'),
      skip: doc['skip'] == true,
    );
  }

  /// Skeleton for an unmatched file, pre-filled from ffprobe + the file
  /// name parse so the user only fills the gaps.
  static void writeSkeleton(
    String mediaPath, {
    required String type,
    String? title,
    int? year,
    String? artist,
    String? album,
    int? track,
    int? season,
    int? episode,
    String? note,
  }) {
    final buf = StringBuffer()
      ..writeln('# W@tch upload sidecar for:')
      ..writeln('#   ${mediaPath.split(Platform.pathSeparator).last}')
      ..writeln(note == null ? '#' : '# $note')
      ..writeln('# Fill ONE of the id fields (preferred), or the manual')
      ..writeln('# fields for content not in any database. Re-run prepare')
      ..writeln('# afterwards. Set `skip: true` to leave the file out.')
      ..writeln('type: $type  # music | video')
      ..writeln();
    if (type == 'music') {
      buf
        ..writeln('# --- Option 1: database id (MusicBrainz release) ---')
        ..writeln("release_mbid: ''  # or paste the release URL")
        ..writeln('track: ${track ?? ''}  # track number on that release')
        ..writeln()
        ..writeln('# --- Option 2: manual entry (no database) ---')
        ..writeln("artist: '${_q(artist)}'")
        ..writeln("album: '${_q(album)}'")
        ..writeln("title: '${_q(title)}'")
        ..writeln('year: ${year ?? ''}');
    } else {
      buf
        ..writeln('# --- Option 1: database id ---')
        ..writeln("imdb: ''  # ttXXXXXXX or the IMDb URL")
        ..writeln("tmdb: ''  # movie:12345 or tv:12345")
        ..writeln()
        ..writeln('# --- Option 2: manual entry (no database) ---')
        ..writeln("title: '${_q(title)}'")
        ..writeln('year: ${year ?? ''}')
        ..writeln('season: ${season ?? ''}')
        ..writeln('episode: ${episode ?? ''}');
    }
    buf
      ..writeln("description: ''  # manual entries: shown in the app")
      ..writeln("art: ''  # manual entries: path to a cover/poster image")
      ..writeln('skip: false');
    File(pathFor(mediaPath)).writeAsStringSync(buf.toString());
  }

  static String _q(String? s) => (s ?? '').replaceAll("'", "''");
}
