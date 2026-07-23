import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_list.dart';
import '../services/app_settings.dart';
import '../services/datamap_prefetch.dart';
import '../services/home_rows.dart';
import '../services/library_store.dart';
import '../services/metadata.dart';
import '../services/metadata_service.dart';
import '../services/embedded_client.dart';
import '../services/watch_state.dart';
import '../theme/tokens.dart';
import '../widgets/detail_header.dart';
import 'player_screen.dart';

/// Movie/episode detail: big artwork with description and rating, and
/// playback — resuming from the stored watch position when one exists,
/// with a jump to the show's next episode for series.
class DetailScreen extends StatefulWidget {
  const DetailScreen({super.key, required this.entry});

  final MediaEntry entry;

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  MediaEntry get entry => widget.entry;

  WatchState? _state;
  MediaEntry? _next;
  List<MediaList> _lists = const [];

  @override
  void initState() {
    super.initState();
    // Warm the entry's data map in the background the moment its page
    // opens: resolving it is most of the pre-first-byte wait, so by the
    // time the user presses Play the file starts as fast as possible.
    // Once per address per session; a no-op when already stored.
    unawaited(DataMapPrefetcher.warm(entry));
    unawaited(_loadState());
  }

  /// Load the entry's resume point and, for episodes, the show's next
  /// episode (needs the library to know the sibling files).
  Future<void> _loadState() async {
    final lists = await LibraryStore.load();
    final state = await WatchStateStore.instance.stateFor(entry);
    if (!mounted) return;
    setState(() {
      _lists = lists;
      _state = state;
      _next = nextEpisode(lists, entry);
    });
  }

  Future<void> _play(BuildContext context, {bool fromStart = false}) async {
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
    final state = _state;
    final resumeFrom = !fromStart && state != null && state.resumable
        ? Duration(milliseconds: state.positionMs)
        : Duration.zero;
    final lists = _lists;
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          url: url,
          title: playerTitle(meta),
          entry: entry,
          resumeFrom: resumeFrom,
          nextFor: (e) => nextEpisode(lists, e),
          bufferSizeMb: bufferSizeMb,
        ),
      ),
    );
    // Refresh the Resume button with the position playback stopped at.
    await _loadState();
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
          DetailHeader(
            poster: headerArtwork(
              t,
              posterImage(meta, fit: BoxFit.cover),
              meta.episodeLabel != null
                  ? Icons.live_tv_outlined
                  : Icons.movie_outlined,
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
                if (meta.episodeLabel != null) ...[
                  const SizedBox(height: 4),
                  Text(meta.episodeLabel!,
                      style: TextStyle(fontSize: 13.5, color: t.boneDim)),
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
                // Air date matters on episode pages; a movie's release
                // date is already covered by the year line.
                if (meta.episodeLabel != null && meta.airDate != null) ...[
                  const SizedBox(height: 4),
                  Text('Aired ${formatAirDate(meta.airDate!)}',
                      style: TextStyle(fontSize: 12, color: t.ash)),
                ],
                if (meta.rating != null) ...[
                  const SizedBox(height: 10),
                  ratingLine(t, meta.rating!),
                ],
                if (_state?.completed ?? false) ...[
                  const SizedBox(height: 10),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle_outline,
                          color: t.copper, size: 16),
                      const SizedBox(width: 5),
                      Text('Watched',
                          style: TextStyle(fontSize: 12.5, color: t.boneDim)),
                    ],
                  ),
                ],
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed: () => _play(context),
                      style: FilledButton.styleFrom(
                        backgroundColor: t.copper,
                        foregroundColor: t.ink,
                      ),
                      icon: const Icon(Icons.play_arrow),
                      label: Text(_state?.resumable ?? false
                          ? 'Resume · ${positionLabel(_state!.positionMs)}'
                          : 'Play'),
                    ),
                    if (_state?.resumable ?? false)
                      TextButton(
                        onPressed: () => _play(context, fromStart: true),
                        child: Text('Start over',
                            style: TextStyle(color: t.boneDim)),
                      ),
                    if (_next != null)
                      OutlinedButton.icon(
                        onPressed: () => Navigator.of(context).pushReplacement(
                          MaterialPageRoute(
                              builder: (_) => DetailScreen(entry: _next!)),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: t.bone,
                          side: BorderSide(color: t.ash),
                        ),
                        icon: const Icon(Icons.skip_next, size: 18),
                        label: const Text('Next episode'),
                      ),
                  ],
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
          sectionLabel(t, 'XOR ADDRESS'),
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
          sectionLabel(t, 'FILE NAME'),
          const SizedBox(height: 6),
          Text(entry.name,
              style: TextStyle(fontSize: 12.5, color: t.boneDim)),
        ],
      ),
    );
  }
}
