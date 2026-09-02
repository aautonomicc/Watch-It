import 'parse.dart';
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

/// [name] with its track marker swapped for [track] / [disc] — the
/// track-number edit (a number is identity: it comes from the file
/// name, not a metadata row, so changing it means renaming the entry).
/// Only the marker changes; every other character of the name — casing,
/// id tags, the exact title — survives verbatim. [disc] null keeps a
/// plain `NN` marker, a value emits `D-NN` (the multi-disc form).
///
/// Returns null when [name] is not a music-convention track name or the
/// swap cannot be done losslessly (the renamed name must parse back to
/// exactly the same artist/album/year/title with the new numbers).
String? renumberedMusicFileName(String name,
    {required int track, int? disc}) {
  final parsed = parseMediaName(name);
  if (!parsed.isTrack) return null;
  final n = track.toString().padLeft(2, '0');
  final marker = disc != null ? '$disc-$n' : n;
  // The marker as it sits in the raw name: `Artist - Album (Year) - `
  // then `NN `/`D-NN ` (the same shape the parser's music regex reads
  // after tag stripping; canonical names carry their tags at the end,
  // so the head matches the raw string too).
  final m = RegExp(r'^(.+? - .+?(?: \(\d{4}\))? - )(?:\d{1,2}-)?\d{2,3} ')
      .firstMatch(name);
  if (m == null) return null;
  final renamed =
      '${m.group(1)}$marker ${name.substring(m.end)}';
  final check = parseMediaName(renamed);
  if (!check.isTrack ||
      check.track != track ||
      check.disc != disc ||
      check.artist != parsed.artist ||
      check.title != parsed.title ||
      check.year != parsed.year ||
      check.trackTitle != parsed.trackTitle ||
      check.releaseMbid != parsed.releaseMbid) {
    return null;
  }
  return renamed;
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
