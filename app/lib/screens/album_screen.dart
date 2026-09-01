import 'package:flutter/material.dart';

import '../models/media_list.dart';
import '../services/connectivity.dart';
import '../services/download_manager.dart';
import '../services/metadata.dart';
import '../services/metadata_service.dart';
import '../services/season_grouping.dart';
import '../services/watch_state.dart';
import '../theme/tokens.dart';
import '../widgets/detail_header.dart';
import 'detail_screen.dart';

/// One album: big square cover art with the artist and track count, then
/// the tracklist ordered by disc/track number. Tapping a track opens the
/// regular detail screen for playback — the same plumbing episodes use.
class AlbumScreen extends StatelessWidget {
  const AlbumScreen({super.key, required this.group});

  final HomeAlbum group;

  @override
  Widget build(BuildContext context) {
    // Rebuild as the cover art lands in the cache, as downloads change
    // the rows' ticks and the download-all button, as connectivity flips
    // the button's enabled state, and as playback marks tracks played.
    return ListenableBuilder(
      listenable: Listenable.merge([
        MetadataService.instance,
        DownloadManager.instance,
        ConnectivityMonitor.instance,
        WatchStateStore.instance,
      ]),
      builder: (context, _) => _build(context),
    );
  }

  /// Queue every not-yet-downloaded track ([remaining]) for download.
  Future<void> _downloadAll(
      BuildContext context, List<MediaEntry> remaining) async {
    for (final entry in remaining) {
      await DownloadManager.instance.enqueue(entry);
    }
    if (!context.mounted) return;
    final n = remaining.length;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(n == 1
            ? '1 track added to downloads'
            : '$n tracks added to downloads')));
  }

  Widget _build(BuildContext context) {
    final t = WiTokens.of(context);
    // Any track's match carries the album title, year, and cover art.
    final meta = MetadataService.instance.metadataFor(group.tracks.first);
    final title = meta.title.isEmpty ? group.album : meta.title;
    final count = group.tracks.length;
    // Tracks not fully downloaded yet — what "download album" queues.
    final remaining = [
      for (final e in group.tracks)
        if (DownloadManager.instance.taskFor(e.address)?.status !=
            DownloadStatus.done)
          e,
    ];
    // Starting a download needs the network (same gating as DetailScreen);
    // browsing the album stays open.
    final offline = ConnectivityMonitor.instance.offline;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Text(title,
            style: TextStyle(color: t.bone, fontSize: 16),
            overflow: TextOverflow.ellipsis),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DetailHeader(
            poster: _cover(t, posterImage(meta, fit: BoxFit.cover)),
            info: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: t.bone,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    group.artist,
                    if (meta.year != null) '${meta.year}',
                    '$count ${count == 1 ? 'track' : 'tracks'}',
                  ].join(' · '),
                  style: TextStyle(fontSize: 13, color: t.boneDim),
                ),
                const SizedBox(height: 16),
                if (remaining.isEmpty)
                  OutlinedButton.icon(
                    onPressed: null,
                    style: OutlinedButton.styleFrom(
                      disabledForegroundColor: t.accent,
                      side: BorderSide(color: t.accent),
                    ),
                    icon: const Icon(Icons.download_done, size: 18),
                    label: const Text('Album downloaded'),
                  )
                else
                  OutlinedButton.icon(
                    onPressed: offline
                        ? null
                        : () => _downloadAll(context, remaining),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: t.bone,
                      side: BorderSide(color: t.ash),
                    ),
                    icon: const Icon(Icons.download_outlined, size: 18),
                    label: Text(remaining.length == count
                        ? 'Download album'
                        : 'Download remaining (${remaining.length})'),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          sectionLabel(t, 'TRACKS'),
          const SizedBox(height: 4),
          for (final entry in group.tracks) _TrackRow(entry: entry, tokens: t),
        ],
      ),
    );
  }

  /// Square cover in the header's artwork slot — album covers are 1:1,
  /// so [headerArtwork]'s 2:3 poster frame would letterbox them.
  Widget _cover(WiTokens t, Widget? image) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: DetailHeader.posterWidth,
        height: DetailHeader.posterWidth,
        child: image ??
            Container(
              color: t.ink2,
              child: Icon(Icons.album_outlined, color: t.ash, size: 96),
            ),
      ),
    );
  }
}

/// Tracklist row: mono track number, track title, and a download tick
/// when the file is on disk. Tap opens the detail screen for playback.
class _TrackRow extends StatelessWidget {
  const _TrackRow({required this.entry, required this.tokens});

  final MediaEntry entry;
  final WiTokens tokens;

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    final parsed = parseMediaName(entry.name);
    final downloaded =
        DownloadManager.instance.taskFor(entry.address)?.status ==
            DownloadStatus.done;
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => DetailScreen(entry: entry)),
      ),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        child: Row(
          children: [
            SizedBox(
              width: 44,
              child: Text(
                parsed.trackMarker ?? '',
                style: TextStyle(
                  fontFamily: wiMonoFamily,
                  fontFamilyFallback: wiMonoFallback,
                  fontSize: 12,
                  color: t.accent,
                ),
              ),
            ),
            Expanded(
              child: Text(
                parsed.trackTitle ?? entry.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13.5, color: t.bone),
              ),
            ),
            if (downloaded) ...[
              const SizedBox(width: 8),
              Icon(Icons.download_done, size: 16, color: t.ash),
            ],
          ],
        ),
      ),
    );
  }
}
