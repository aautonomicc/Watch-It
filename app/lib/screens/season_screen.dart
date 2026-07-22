import 'package:flutter/material.dart';

import '../models/media_list.dart';
import '../services/metadata.dart';
import '../services/metadata_service.dart';
import '../services/season_grouping.dart';
import '../theme/tokens.dart';
import '../widgets/detail_header.dart';
import 'detail_screen.dart';

/// One season of a show: big season artwork with description and rating,
/// then the episodes as tiles flowing left to right — TMDB screenshot,
/// `SxxEyy` marker + name, air date, and synopsis. Tapping an episode
/// opens the regular detail screen for playback.
class SeasonScreen extends StatelessWidget {
  const SeasonScreen({super.key, required this.group});

  final HomeSeason group;

  @override
  Widget build(BuildContext context) {
    // Rebuild as TMDB matches for the episodes land in the cache.
    return ListenableBuilder(
      listenable: MetadataService.instance,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final t = WiTokens.of(context);
    // Any episode's match carries the show title, season artwork and
    // synopsis, rating, and category; the first is as good as any.
    final meta = MetadataService.instance.metadataFor(group.episodes.first);
    final overview = meta.seasonOverview ?? meta.showOverview;
    final count = group.episodes.length;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Text('${meta.title} — Season ${group.season}',
            style: TextStyle(color: t.bone, fontSize: 16),
            overflow: TextOverflow.ellipsis),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DetailHeader(
            poster: headerArtwork(
              t,
              posterImage(meta, fit: BoxFit.cover),
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
                const SizedBox(height: 4),
                Text(
                  'Season ${group.season} · '
                  '$count ${count == 1 ? 'episode' : 'episodes'}',
                  style: TextStyle(fontSize: 13, color: t.boneDim),
                ),
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
          sectionLabel(t, 'EPISODES'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 18,
            children: [
              for (final entry in group.episodes)
                _EpisodeTile(entry: entry, tokens: t),
            ],
          ),
        ],
      ),
    );
  }
}

/// Episode tile: 16:9 TMDB screenshot, then the `SxxEyy` marker with the
/// episode name, the air date, and the episode synopsis.
class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile({required this.entry, required this.tokens});

  static const double width = 200;

  final MediaEntry entry;
  final WiTokens tokens;

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    final meta = MetadataService.instance.metadataFor(entry);
    final parsed = parseMediaName(entry.name);
    final marker = 'S${parsed.season.toString().padLeft(2, '0')}'
        'E${parsed.episode.toString().padLeft(2, '0')}';
    final name = episodeNameFromLabel(meta.episodeLabel);
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => DetailScreen(entry: entry)),
      ),
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: width,
                height: width * 9 / 16,
                child: stillImage(meta, fit: BoxFit.cover) ??
                    Container(
                      color: t.ink2,
                      child: Icon(Icons.play_circle_outline,
                          color: t.ash, size: 36),
                    ),
              ),
            ),
            const SizedBox(height: 6),
            Text.rich(
              TextSpan(children: [
                TextSpan(
                  text: marker,
                  style: TextStyle(
                    fontFamily: wiMonoFamily,
                    fontFamilyFallback: wiMonoFallback,
                    fontSize: 11.5,
                    color: t.copper,
                  ),
                ),
                TextSpan(
                  text: '  ${name ?? 'Episode ${parsed.episode}'}',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: t.bone,
                  ),
                ),
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (meta.airDate != null) ...[
              const SizedBox(height: 2),
              Text(
                formatAirDate(meta.airDate!),
                style: TextStyle(fontSize: 10.5, color: t.ash),
              ),
            ],
            if (meta.overview != null) ...[
              const SizedBox(height: 4),
              Text(
                meta.overview!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style:
                    TextStyle(fontSize: 11, height: 1.4, color: t.boneDim),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
