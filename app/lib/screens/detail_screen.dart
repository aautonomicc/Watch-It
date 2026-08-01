import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_list.dart';
import '../services/app_settings.dart';
import '../services/connectivity.dart';
import '../services/download_manager.dart';
import '../services/home_rows.dart';
import '../services/library_store.dart';
import '../services/metadata.dart';
import '../services/metadata_service.dart';
import '../services/embedded_client.dart';
import '../services/network_policy.dart';
import '../services/watch_state.dart';
import '../theme/tokens.dart';
import '../widgets/detail_header.dart';
import '../widgets/messenger.dart' show wiMessengerKey;
import '../widgets/watch_progress.dart';
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
    // No data-map warm needed: every entry's map arrived at import time
    // (datamap-first model) — playback reads it from the local store.
    unawaited(DownloadManager.instance.ensureLoaded());
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

  /// Playback source for [e]: the downloaded file when one is complete
  /// on disk, else the embedded client's stream URL. Also used for
  /// episodes chained by the player's Up-next flow.
  ({String url, bool local})? _sourceFor(MediaEntry e) {
    final local = DownloadManager.instance.localPathIfDone(e);
    if (local != null) return (url: local, local: true);
    final url = streamUrl(EmbeddedClient.baseUrl(), e);
    return url == null ? null : (url: url, local: false);
  }

  /// Apply the pause-downloads-on-playback preference before streaming
  /// starts. Returns true when downloads were paused for this playback
  /// (the caller resumes them when the player closes). "Remember my
  /// choice" on the prompt writes the preference for next time.
  Future<bool> _maybePauseDownloads(BuildContext context) async {
    final pref = await AppSettings.pauseDownloadsOnPlay();
    switch (pref) {
      case PauseDownloadsOnPlay.always:
        return DownloadManager.instance.pauseAllForPlayback();
      case PauseDownloadsOnPlay.never:
        return false;
      case PauseDownloadsOnPlay.ask:
        break;
    }
    if (!context.mounted) return false;
    final t = WiTokens.of(context);
    var remember = false;
    final pause = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: t.ink2,
          title: Text('Pause downloads while playing?',
              style: TextStyle(color: t.bone, fontSize: 16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Streaming and downloading share the network connection. '
                'Pausing downloads gives playback the full bandwidth; '
                'they resume automatically when the player closes.',
                style: TextStyle(color: t.boneDim, fontSize: 13),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                value: remember,
                onChanged: (v) =>
                    setDialogState(() => remember = v ?? false),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                activeColor: t.accent,
                title: Text('Remember my choice',
                    style: TextStyle(color: t.boneDim, fontSize: 13)),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('Keep downloading',
                  style: TextStyle(color: t.ash)),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text('Pause downloads',
                  style: TextStyle(color: t.accent)),
            ),
          ],
        ),
      ),
    );
    if (pause == null) return false; // dismissed — leave downloads running
    if (remember) {
      await AppSettings.setPauseDownloadsOnPlay(pause
          ? PauseDownloadsOnPlay.always
          : PauseDownloadsOnPlay.never);
    }
    if (!pause) return false;
    return DownloadManager.instance.pauseAllForPlayback();
  }

  Future<void> _play(BuildContext context, {bool fromStart = false}) async {
    final source = _sourceFor(entry);
    final url = source?.url;
    if (!context.mounted) return;
    if (source == null || url == null) {
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
                child: Text('OK', style: TextStyle(color: t.accent)),
              ),
            ],
          );
        },
      );
      return;
    }
    // Mobile-data policy (Settings → Network): streamed playback may be
    // blocked on cellular, or ask first — once per session.
    if (!source.local) {
      final gate = await streamingGateNow();
      if (gate == StreamingGate.block) {
        wiMessengerKey.currentState?.showSnackBar(const SnackBar(
            content: Text("You're on mobile data — streaming is set to "
                'Wi-Fi only (Settings → Network)')));
        return;
      }
      if (gate == StreamingGate.ask) {
        if (!context.mounted) return;
        if (await _confirmCellularStreaming(context) != true) return;
        CellularStreamingConsent.granted = true;
      }
    }
    if (!context.mounted) return;
    // A downloaded file plays locally and competes with nothing; only
    // streamed playback may pause active downloads (per the preference).
    var pausedForPlayback = false;
    if (!source.local && DownloadManager.instance.hasActive) {
      pausedForPlayback = await _maybePauseDownloads(context);
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
          isLocal: source.local,
          resumeFrom: resumeFrom,
          nextFor: (e) => nextEpisode(lists, e),
          sourceFor: _sourceFor,
          bufferSizeMb: bufferSizeMb,
        ),
      ),
    );
    if (pausedForPlayback) {
      final resumed = await DownloadManager.instance.resumeAfterPlayback();
      if (resumed) {
        wiMessengerKey.currentState?.showSnackBar(
            const SnackBar(content: Text('Downloads resumed')));
      }
    }
    // Refresh the Resume button with the position playback stopped at.
    await _loadState();
  }

  /// Once-per-session confirmation for streaming over mobile data
  /// (the Ask policy in Settings → Network).
  Future<bool?> _confirmCellularStreaming(BuildContext context) {
    final t = WiTokens.of(context);
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: t.ink2,
        title: Text("You're on mobile data",
            style: TextStyle(color: t.bone, fontSize: 16)),
        content: Text(
          'Streaming uses your mobile-data allowance (a movie can be '
          'several GB). Stream anyway? You will not be asked again '
          'until the app restarts.',
          style: TextStyle(color: t.boneDim, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel', style: TextStyle(color: t.ash)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Stream anyway', style: TextStyle(color: t.accent)),
          ),
        ],
      ),
    );
  }

  /// Download button action by state: start, pause, resume/retry, or
  /// (when done) offer to remove the downloaded file.
  Future<void> _onDownloadPressed(DownloadTask? task) async {
    final manager = DownloadManager.instance;
    switch (task?.status) {
      case null:
        await manager.enqueue(entry);
      case DownloadStatus.queued || DownloadStatus.downloading:
        await manager.pause(entry.address);
      case DownloadStatus.paused || DownloadStatus.error:
        await manager.resume(entry.address);
      case DownloadStatus.done:
        if (!mounted) return;
        final t = WiTokens.of(context);
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: t.ink2,
            title: Text('Remove download?',
                style: TextStyle(color: t.bone, fontSize: 16)),
            content: Text(
              'The downloaded file is deleted from this device and '
              'playback goes back to streaming. The file stays on '
              'Autonomi.',
              style: TextStyle(color: t.boneDim, fontSize: 13),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text('Cancel', style: TextStyle(color: t.ash)),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text('Remove', style: TextStyle(color: t.rust)),
              ),
            ],
          ),
        );
        if (confirmed == true) await manager.remove(entry.address);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild when the TMDB match for this entry lands in the cache,
    // this entry's download changes state, or connectivity flips.
    return ListenableBuilder(
      listenable: Listenable.merge([
        MetadataService.instance,
        DownloadManager.instance,
        ConnectivityMonitor.instance,
      ]),
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final t = WiTokens.of(context);
    final meta = MetadataService.instance.metadataFor(entry);
    final task = DownloadManager.instance.taskFor(entry.address);
    final downloaded = task?.status == DownloadStatus.done;
    final offline = ConnectivityMonitor.instance.offline;
    // Offline, only downloaded titles can play; browsing stays open.
    final playBlocked = offline && !downloaded;
    // Offline the download button still allows the local actions —
    // pausing a queued/running task, removing a finished one — but not
    // the ones that need the network (start, resume, retry).
    final downloadBlocked = offline &&
        (task == null ||
            task.status == DownloadStatus.paused ||
            task.status == DownloadStatus.error);
    final (downloadIcon, downloadLabel) = switch (task?.status) {
      null => (Icons.download_outlined, 'Download'),
      DownloadStatus.queued => (Icons.pause, 'Queued'),
      DownloadStatus.downloading => (
          Icons.pause,
          task!.progress != null
              ? 'Downloading ${(task.progress! * 100).round()}%'
              : 'Downloading'
        ),
      DownloadStatus.paused => (Icons.play_arrow, 'Resume download'),
      DownloadStatus.error => (Icons.refresh, 'Retry download'),
      DownloadStatus.done => (Icons.download_done, 'Downloaded'),
    };
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
              overlay: (_state != null &&
                      _state!.resumable &&
                      _state!.progress > 0)
                  ? watchProgressBar(t, _state!.progress)
                  : null,
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
                          color: t.accent, size: 16),
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
                      onPressed:
                          playBlocked ? null : () => _play(context),
                      style: FilledButton.styleFrom(
                        backgroundColor: t.accent,
                        foregroundColor: t.ink,
                      ),
                      icon: const Icon(Icons.play_arrow),
                      label: Text(_state?.resumable ?? false
                          ? 'Resume · ${positionLabel(_state!.positionMs)}'
                          : 'Play'),
                    ),
                    if (_state?.resumable ?? false)
                      TextButton(
                        onPressed: playBlocked
                            ? null
                            : () => _play(context, fromStart: true),
                        child: Text('Start over',
                            style: TextStyle(color: t.boneDim)),
                      ),
                    OutlinedButton.icon(
                      onPressed: downloadBlocked
                          ? null
                          : () => _onDownloadPressed(task),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: downloaded ? t.accent : t.bone,
                        side: BorderSide(
                            color: downloaded ? t.accent : t.ash),
                      ),
                      icon: Icon(downloadIcon, size: 18),
                      label: Text(downloadLabel),
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
                if (playBlocked) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(Icons.cloud_off_outlined,
                          size: 15, color: t.rust),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Offline — this title is not downloaded, so it '
                          'cannot play until the connection is back.',
                          style:
                              TextStyle(fontSize: 11.5, color: t.boneDim),
                        ),
                      ),
                    ],
                  ),
                ],
                if (task != null && !downloaded) ...[
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: SizedBox(
                      height: 4,
                      child: LinearProgressIndicator(
                        value: task.progress,
                        backgroundColor: t.ink2,
                        color: t.accent,
                      ),
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    task.status == DownloadStatus.error
                        ? 'Download failed — ${task.error ?? 'unknown error'}'
                        : downloadSizeLabel(task),
                    style: TextStyle(
                        fontSize: 11,
                        color: task.status == DownloadStatus.error
                            ? t.rust
                            : t.boneDim),
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  downloaded
                      ? 'Downloaded — plays from this device, no network '
                          'needed.'
                      : 'Streams from Autonomi via the built-in client — '
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
          sectionLabel(t, 'ADDRESS'),
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
