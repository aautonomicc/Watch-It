import 'metadata.dart' show parseMediaName;

/// The library list a batch of media [names] most likely belongs in,
/// judged from the names alone: mostly audio → "Music", mostly episodes
/// (`SxxEyy`/`1x02` markers) → "TV Shows", other video → "Movies".
/// Shared by the batch uploader's list default and the datamap import's
/// pre-checked list suggestion, so both flows sort by type the same
/// way. [fallback] survives an empty pick.
String defaultListForNames(Iterable<String> names,
    {String fallback = 'My uploads'}) {
  var audio = 0;
  var episodes = 0;
  var video = 0;
  for (final name in names) {
    final parsed = parseMediaName(name);
    if (parsed.isAudio) {
      audio++;
    } else {
      video++;
      if (parsed.isEpisode) episodes++;
    }
  }
  if (audio + video == 0) return fallback;
  if (audio * 2 > audio + video) return 'Music';
  return episodes * 2 > video ? 'TV Shows' : 'Movies';
}
