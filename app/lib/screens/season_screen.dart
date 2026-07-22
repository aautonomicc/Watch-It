import 'package:flutter/material.dart';

import '../models/media_list.dart';
import '../services/metadata.dart';
import '../services/metadata_service.dart';
import '../services/season_grouping.dart';
import '../theme/tokens.dart';
import 'detail_screen.dart';

/// One season of a show: season artwork header, then its episodes with
/// TMDB episode names and `SxxEyy` markers. Tapping an episode opens the
/// regular detail screen for playback.
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
    // Any episode's match carries the show title, season artwork, and
    // category; the first is as good as any.
    final meta = MetadataService.instance.metadataFor(group.episodes.first);
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 110,
                  height: 165,
                  child: posterImage(meta, fit: BoxFit.cover) ??
                      Container(
                        color: t.ink2,
                        child: Icon(Icons.live_tv_outlined,
                            color: t.ash, size: 40),
                      ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      meta.title,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: t.bone,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text('Season ${group.season}',
                        style: TextStyle(fontSize: 13, color: t.boneDim)),
                    const SizedBox(height: 4),
                    Text('$count ${count == 1 ? 'episode' : 'episodes'}',
                        style: TextStyle(fontSize: 12, color: t.ash)),
                    if (meta.category != null) ...[
                      const SizedBox(height: 4),
                      Text(meta.category!,
                          style: TextStyle(fontSize: 12, color: t.ash)),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          for (final entry in group.episodes)
            _EpisodeTile(entry: entry, tokens: t),
        ],
      ),
    );
  }
}

class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile({required this.entry, required this.tokens});

  final MediaEntry entry;
  final WiTokens tokens;

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    final meta = MetadataService.instance.metadataFor(entry);
    final parsed = parseMediaName(entry.name);
    final marker = 'S${parsed.season.toString().padLeft(2, '0')}'
        'E${parsed.episode.toString().padLeft(2, '0')}';
    final name =
        episodeNameFromLabel(meta.episodeLabel) ?? 'Episode ${parsed.episode}';
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(Icons.play_circle_outline, color: t.copper),
      title: Text(name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 14, color: t.bone)),
      subtitle: Text(marker,
          style: TextStyle(
            fontFamily: wiMonoFamily,
            fontFamilyFallback: wiMonoFallback,
            fontSize: 11.5,
            color: t.boneDim,
          )),
      trailing: Icon(Icons.chevron_right, color: t.ash),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => DetailScreen(entry: entry)),
      ),
    );
  }
}
