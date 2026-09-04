import 'package:flutter/material.dart';

import '../models/media_list.dart';
import '../services/connectivity.dart';
import '../services/download_manager.dart';
import '../services/metadata_service.dart';
import '../services/season_grouping.dart';
import '../services/version_choice.dart';
import '../theme/tokens.dart';
import '../widgets/detail_header.dart';
import '../widgets/download_badge.dart';
import 'edit_details_screen.dart';
import 'season_screen.dart';

/// One show: big show artwork with description and rating, then the
/// seasons in the library as normal-size tiles. Tapping a season opens
/// its [SeasonScreen].
class ShowScreen extends StatelessWidget {
  const ShowScreen({super.key, required this.seasons});

  /// The show's seasons present in the list, sorted by season number
  /// (see [showSeasons]); never empty.
  final List<HomeSeason> seasons;

  @override
  Widget build(BuildContext context) {
    // Rebuild as TMDB matches for the episodes land in the cache, as
    // downloads change the season tiles' badges and the download-all
    // button, and as connectivity flips the button's enabled state.
    return ListenableBuilder(
      listenable: Listenable.merge([
        MetadataService.instance,
        DownloadManager.instance,
        ConnectivityMonitor.instance,
      ]),
      builder: (context, _) => _build(context),
    );
  }

  /// Queue every not-yet-downloaded episode ([remaining]) for download.
  Future<void> _downloadAll(
      BuildContext context, List<MediaEntry> remaining) async {
    for (final entry in remaining) {
      await DownloadManager.instance.enqueue(entry);
    }
    if (!context.mounted) return;
    final n = remaining.length;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            n == 1 ? '1 episode added to downloads' : '$n episodes added to downloads')));
  }

  Widget _build(BuildContext context) {
    final t = WiTokens.of(context);
    // Any episode's match carries the show title, artwork, rating, and
    // synopsis; the first is as good as any.
    final meta = MetadataService.instance.metadataFor(
        seasons.first.episodes.first);
    final overview = meta.showOverview ?? meta.overview;
    // Episodes across every season not fully downloaded yet — what
    // "download show" queues (all seasons' episodes are already in
    // memory on this screen).
    final episodes = [for (final s in seasons) ...s.episodes];
    final remaining = [
      for (final s in seasons)
        for (final e in s.episodes)
          // No quality tier of the episode on disk yet.
          if (!anyVersionDownloaded(s.versionsOf(e))) e,
    ];
    // Starting a download needs the network (same gating as SeasonScreen);
    // browsing the show stays open.
    final offline = ConnectivityMonitor.instance.offline;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Text(meta.title,
            style: TextStyle(color: t.bone, fontSize: 16),
            overflow: TextOverflow.ellipsis),
        actions: [
          // Edit details for the whole show — title, year, synopsis, and
          // show poster, written under the show's own key and overlaid
          // on every episode by MetadataService.
          IconButton(
            tooltip: 'Edit details',
            icon: Icon(Icons.edit_outlined, color: t.boneDim, size: 20),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => EditDetailsScreen(
                  entry: seasons.first.episodes.first,
                  scope: EditDetailsScope.show,
                ),
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DetailHeader(
            poster: headerArtwork(
              t,
              showPosterImage(meta, fit: BoxFit.cover),
              Icons.live_tv_outlined,
            ),
            info: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  meta.title,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: t.bone,
                  ),
                ),
                if (meta.year != null) ...[
                  const SizedBox(height: 4),
                  Text('${meta.year}',
                      style: TextStyle(fontSize: 13, color: t.ash)),
                ],
                if (meta.category != null) ...[
                  const SizedBox(height: 4),
                  Text(meta.category!,
                      style: TextStyle(fontSize: 12, color: t.ash)),
                ],
                if (meta.rating != null) ...[
                  const SizedBox(height: 10),
                  ratingLine(t, meta.rating!),
                ],
                if (overview != null) ...[
                  const SizedBox(height: 14),
                  Text(
                    overview,
                    style: TextStyle(
                        fontSize: 13.5, height: 1.5, color: t.boneDim),
                  ),
                ],
                const SizedBox(height: 16),
                if (remaining.isEmpty)
                  OutlinedButton.icon(
                    onPressed: null,
                    style: OutlinedButton.styleFrom(
                      disabledForegroundColor: t.accent,
                      side: BorderSide(color: t.accent),
                    ),
                    icon: const Icon(Icons.download_done, size: 18),
                    label: const Text('Show downloaded'),
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
                    label: Text(remaining.length == episodes.length
                        ? 'Download show'
                        : 'Download remaining (${remaining.length})'),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          sectionLabel(t, 'SEASONS'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 16,
            children: [
              for (final season in seasons)
                _SeasonTile(group: season, tokens: t),
            ],
          ),
        ],
      ),
    );
  }
}

/// Normal-size (wall-card) season tile: season artwork, `Season N`, and
/// the episode count.
class _SeasonTile extends StatelessWidget {
  const _SeasonTile({required this.group, required this.tokens});

  final HomeSeason group;
  final WiTokens tokens;

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    // The episode match carries the season's artwork.
    final meta = MetadataService.instance.metadataFor(group.episodes.first);
    final count = group.episodes.length;
    // An episode counts as downloaded when ANY of its quality tiers is.
    final badge = versionGroupDownloadBadge(
        t, [for (final e in group.episodes) group.versionsOf(e)]);
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => SeasonScreen(group: group)),
      ),
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 120,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 120,
                height: 180,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    posterImage(meta, fit: BoxFit.cover) ??
                        Container(
                          color: t.ink2,
                          child: Icon(Icons.live_tv_outlined,
                              color: t.ash, size: 40),
                        ),
                    ?badge,
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Season ${group.season}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: t.boneDim),
            ),
            Text(
              '$count ${count == 1 ? 'episode' : 'episodes'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10.5, color: t.ash),
            ),
          ],
        ),
      ),
    );
  }
}
