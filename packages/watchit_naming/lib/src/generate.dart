import 'sanitize.dart';

/// Canonical W@tch music file name (docs/NAMING.md music convention,
/// 2026-09-01 plan):
///
/// `Artist - Album (Year) - NN Title {mbid-<release-mbid>}.ext`
///
/// - Track `NN` plays the role SxxEyy does for TV; when the release has
///   more than one disc the token becomes `D-NN` (multi-disc decision).
/// - [releaseMbid] omitted → no id tag (case-B custom items: no id tag
///   means the app skips metadata APIs and uses baked-in data).
/// - Compilation albums pass `Various Artists` as [artist]; featuring
///   credits arrive verbatim inside [title]/[artist] from the caller.
/// - Every component is sanitized; the title is truncated to keep the
///   whole name within 255 UTF-8 bytes with the id tag + extension always
///   intact.
String musicFileName({
  required String artist,
  required String album,
  int? year,
  required int track,
  int disc = 1,
  int discTotal = 1,
  required String title,
  String? releaseMbid,
  required String ext,
}) {
  final a = sanitizeNamePart(artist);
  final b = sanitizeNamePart(album);
  final t = sanitizeNamePart(title);
  final yearPart = year != null ? ' ($year)' : '';
  final trackNo = track.toString().padLeft(2, '0');
  final trackPart = discTotal > 1 ? '$disc-$trackNo' : trackNo;
  final tag = releaseMbid != null ? ' {mbid-$releaseMbid}' : '';
  final dotExt = ext.startsWith('.') ? ext : '.$ext';
  // The track title takes the truncation first; artist/album only when
  // they alone blow the budget (pathological input).
  final head = '$a - $b$yearPart - $trackPart ';
  final suffix = '$tag$dotExt';
  final name = fitFileName('$head$t', suffix);
  if (name.length >= head.length + suffix.length) return name;
  // Head itself did not fit: refit with head truncated and a minimal title.
  return fitFileName(head.trimRight(), suffix);
}

/// Canonical W@tch video file name (docs/NAMING.md):
///
/// - Movie: `Title (Year) {imdb-ttXXXXXXX} - [1080p].ext`
/// - Episode: `Show (Year) SxxEyy {imdb-ttXXXXXXX}.ext` — the imdb id is
///   the show's; the parser reads the year and marker before the tag
///   blocks are stripped, so everything round-trips.
///
/// [imdbId] omitted → no id tag (case-B custom items). [height] omitted →
/// no resolution tag.
String videoFileName({
  required String title,
  int? year,
  String? imdbId,
  int? season,
  int? episode,
  int? height,
  required String ext,
}) {
  final t = sanitizeNamePart(title);
  final yearPart = year != null ? ' ($year)' : '';
  final marker = season != null && episode != null
      ? ' S${season.toString().padLeft(2, '0')}'
          'E${episode.toString().padLeft(2, '0')}'
      : '';
  final tag = imdbId != null ? ' {imdb-$imdbId}' : '';
  final res = height != null ? ' - [${height}p]' : '';
  final dotExt = ext.startsWith('.') ? ext : '.$ext';
  return fitFileName(t, '$yearPart$marker$tag$res$dotExt');
}
