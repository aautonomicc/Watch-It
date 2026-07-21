import 'package:flutter/material.dart';

import '../models/media_list.dart';
import '../services/app_settings.dart';
import '../services/metadata_service.dart';
import '../services/embedded_client.dart';
import '../theme/tokens.dart';
import 'player_screen.dart';

/// Movie detail: artwork, description, and playback.
class DetailScreen extends StatelessWidget {
  const DetailScreen({super.key, required this.entry});

  final MediaEntry entry;

  Future<void> _play(BuildContext context) async {
    final url = streamUrl(EmbeddedClient.baseUrl(), entry);
    if (!context.mounted) return;
    if (url == null) {
      showDialog<void>(
        context: context,
        builder: (context) {
          final t = WiTokens.of(context);
          return AlertDialog(
            backgroundColor: t.ink2,
            title: Text('Client unavailable',
                style: TextStyle(color: t.bone, fontSize: 16)),
            content: Text(
              'The built-in Autonomi client could not start on this '
              'platform, so streaming is not available.',
              style: TextStyle(color: t.boneDim, fontSize: 13),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text('OK', style: TextStyle(color: t.copper)),
              ),
            ],
          );
        },
      );
      return;
    }
    final meta = MetadataService.instance.metadataFor(entry);
    final bufferSizeMb = await AppSettings.bufferSizeMb();
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          url: url,
          title: meta.title,
          bufferSizeMb: bufferSizeMb,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild when the TMDB match for this entry lands in the cache.
    return ListenableBuilder(
      listenable: MetadataService.instance,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final t = WiTokens.of(context);
    final meta = MetadataService.instance.metadataFor(entry);
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 140,
                  height: 210,
                  child: posterImage(meta, fit: BoxFit.cover) ??
                      Container(
                        color: t.ink2,
                        child: Icon(Icons.movie_outlined,
                            color: t.ash, size: 48),
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
                    if (meta.episodeLabel != null) ...[
                      const SizedBox(height: 4),
                      Text(meta.episodeLabel!,
                          style: TextStyle(fontSize: 13, color: t.boneDim)),
                    ],
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
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () => _play(context),
                      style: FilledButton.styleFrom(
                        backgroundColor: t.copper,
                        foregroundColor: t.ink,
                      ),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Play'),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Streams from Autonomi via the built-in client — '
                      'first start can take a minute while it connects '
                      'and fetches chunks.',
                      style: TextStyle(fontSize: 11, color: t.ash),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (meta.overview != null)
            Text(
              meta.overview!,
              style: TextStyle(fontSize: 13.5, height: 1.5, color: t.boneDim),
            )
          else
            Text(
              'No description yet — artwork and descriptions are matched '
              'from TMDB by file name. Set a TMDB API key in Settings and '
              'name files like the examples in the app\'s naming guide.',
              style: TextStyle(fontSize: 12.5, color: t.ash),
            ),
          const SizedBox(height: 24),
          Text(
            'XOR ADDRESS',
            style: TextStyle(
              fontSize: 10,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w700,
              color: t.ash,
            ),
          ),
          const SizedBox(height: 6),
          SelectableText(
            entry.address,
            style: TextStyle(
              fontFamily: wiMonoFamily,
              fontFamilyFallback: wiMonoFallback,
              fontSize: 11.5,
              color: t.boneDim,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'FILE NAME',
            style: TextStyle(
              fontSize: 10,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w700,
              color: t.ash,
            ),
          ),
          const SizedBox(height: 6),
          Text(entry.name,
              style: TextStyle(fontSize: 12.5, color: t.boneDim)),
        ],
      ),
    );
  }
}
