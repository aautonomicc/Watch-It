import 'package:flutter/material.dart';

import '../services/download_manager.dart';
import '../services/metadata_service.dart';
import '../services/season_grouping.dart';
import '../theme/tokens.dart';
import '../widgets/detail_header.dart';
import '../widgets/download_badge.dart';
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
    // Rebuild as TMDB matches for the episodes land in the cache and as
    // downloads change the season tiles' badges.
    return ListenableBuilder(
      listenable: Listenable.merge(
          [MetadataService.instance, DownloadManager.instance]),
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final t = WiTokens.of(context);
    // Any episode's match carries the show title, artwork, rating, and
    // synopsis; the first is as good as any.
    final meta = MetadataService.instance.metadataFor(
        seasons.first.episodes.first);
    final overview = meta.showOverview ?? meta.overview;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Text(meta.title,
            style: TextStyle(color: t.bone, fontSize: 16),
            overflow: TextOverflow.ellipsis),
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
    final badge = groupDownloadBadge(t, group.episodes);
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
