import 'package:flutter/material.dart';

import '../models/media_list.dart';
import '../services/metadata_service.dart';
import '../services/season_grouping.dart';
import '../theme/tokens.dart';
import 'download_badge.dart';
import 'watch_progress.dart';

/// Wall card for a single (non-episode) entry: poster with watch bar and
/// download badge, title/year underneath. Shared by the home shelves and
/// the per-list browse grid.
class PosterCard extends StatelessWidget {
  const PosterCard({
    super.key,
    required this.entry,
    required this.tokens,
    required this.onTap,
  });

  final MediaEntry entry;
  final WiTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    final meta = MetadataService.instance.metadataFor(entry);
    final badge = entryDownloadBadge(t, entry);
    return InkWell(
      onTap: onTap,
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
                          child: Icon(Icons.movie_outlined,
                              color: t.ash, size: 40),
                        ),
                    ?entryWatchBar(t, entry),
                    ?badge,
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              meta.year != null ? '${meta.title} (${meta.year})' : meta.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: t.boneDim),
            ),
          ],
        ),
      ),
    );
  }
}

/// A whole show folded into one wall card: the show's main poster with
/// its name and season/episode counts underneath. Tap opens the show
/// page, which lists the seasons.
class ShowCard extends StatelessWidget {
  const ShowCard({
    super.key,
    required this.group,
    required this.tokens,
    required this.onTap,
  });

  final HomeShow group;
  final WiTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    // Any episode's match carries the show title and show artwork.
    final meta = MetadataService.instance
        .metadataFor(group.seasons.first.episodes.first);
    final seasons = group.seasons.length;
    final count = group.episodeCount;
    final badge = groupDownloadBadge(
        t, [for (final s in group.seasons) ...s.episodes]);
    return InkWell(
      onTap: onTap,
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
                    showPosterImage(meta, fit: BoxFit.cover) ??
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
              meta.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: t.boneDim),
            ),
            Text(
              seasons == 1
                  ? 'Season ${group.seasons.single.season} · $count ep'
                  : '$seasons seasons · $count ep',
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
