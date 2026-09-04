import '../models/media_list.dart';
import 'download_manager.dart';
import 'metadata.dart';
import 'season_grouping.dart' show VersionKeys;

/// Version-aware helpers shared by the detail page and the card
/// builders: discovering every upload of a title/episode in the library,
/// and picking which one a page should open by default (the best
/// downloaded copy, else the tier the user streamed last).

String _normalize(String address) =>
    address.toLowerCase().replaceFirst('0x', '');

/// Whether [entry]'s download is complete on disk.
bool isEntryDownloaded(MediaEntry entry) =>
    DownloadManager.instance.taskFor(entry.address)?.status ==
    DownloadStatus.done;

/// Whether any upload of a title is complete on disk — the aggregate the
/// blue tick, offline gating, and "download remaining" buttons key off.
bool anyVersionDownloaded(Iterable<MediaEntry> versions,
    {bool Function(MediaEntry entry)? isDownloaded}) {
  final check = isDownloaded ?? isEntryDownloaded;
  return versions.any(check);
}

/// All uploads of [entry]'s title (or episode) across the enabled lists
/// (same parsed lookup key, duplicate addresses dropped), in library
/// order. [entry] itself is prepended when the library no longer holds
/// it. Episodes fold exactly like movies — same episode marker, same
/// show — mirroring [HomeSeason.versions].
List<MediaEntry> versionsInLibrary(List<MediaList> lists, MediaEntry entry) {
  final parsed = parseMediaName(entry.name);
  final keys = VersionKeys([
    entry,
    for (final l in lists)
      if (l.enabled) ...l.entries,
  ]);
  final key = keys.keyFor(parsed);
  final seen = <String>{};
  final found = <MediaEntry>[];
  for (final l in lists) {
    if (!l.enabled) continue;
    for (final e in l.entries) {
      if (keys.keyFor(parseMediaName(e.name)) != key) continue;
      if (seen.add(_normalize(e.address))) found.add(e);
    }
  }
  if (!seen.contains(_normalize(entry.address))) found.insert(0, entry);
  return found;
}

/// Height in pixels parsed off a `1080p H.264`-style [MediaEntry.videoInfo]
/// label; null when the label is missing or carries no `NNNp` tag.
int? videoInfoHeight(String? videoInfo) {
  if (videoInfo == null) return null;
  final m = RegExp(r'(\d{3,4})p\b').firstMatch(videoInfo);
  return m == null ? null : int.tryParse(m.group(1)!);
}

/// The version of a title a detail page should show by default:
///
/// 1. the highest-resolution fully DOWNLOADED version (a downloaded copy
///    always beats streaming, whatever its tier — also what makes
///    offline playback work when a non-primary tier is the one on disk);
/// 2. else [opened], when the navigation deliberately targeted a
///    NON-primary version (Continue Watching resumes the exact copy that
///    was being watched) — that choice is never second-guessed;
/// 3. else, when [preferredHeight] is set (the tier the user last
///    streamed), the version with the nearest known resolution (ties go
///    to the lower tier — cheaper on data);
/// 4. else the primary (first) version.
MediaEntry preferredVersion(
  List<MediaEntry> versions, {
  bool Function(MediaEntry entry)? isDownloaded,
  int? preferredHeight,
  MediaEntry? opened,
}) {
  if (versions.length <= 1) return versions.first;
  final check = isDownloaded ?? isEntryDownloaded;

  MediaEntry? best;
  var bestHeight = -1;
  for (final v in versions) {
    if (!check(v)) continue;
    // Unknown resolution ranks below any known one, above none.
    final h = videoInfoHeight(v.videoInfo) ?? 0;
    if (best == null || h > bestHeight) {
      best = v;
      bestHeight = h;
    }
  }
  if (best != null) return best;

  if (opened != null &&
      _normalize(opened.address) != _normalize(versions.first.address)) {
    return opened;
  }

  if (preferredHeight != null) {
    MediaEntry? nearest;
    var nearestDiff = 0;
    var nearestHeight = 0;
    for (final v in versions) {
      final h = videoInfoHeight(v.videoInfo);
      if (h == null) continue;
      final diff = (h - preferredHeight).abs();
      if (nearest == null ||
          diff < nearestDiff ||
          (diff == nearestDiff && h < nearestHeight)) {
        nearest = v;
        nearestDiff = diff;
        nearestHeight = h;
      }
    }
    if (nearest != null) return nearest;
  }
  return opened ?? versions.first;
}
