import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../models/media_list.dart';
import '../services/app_settings.dart';
import '../services/connectivity.dart';
import '../services/download_manager.dart';
import '../services/favourites.dart';
import '../services/home_rows.dart';
import '../services/library_store.dart';
import '../services/metadata.dart';
import '../services/metadata_service.dart';
import '../services/embedded_client.dart';
import '../services/network_policy.dart';
import '../services/season_grouping.dart' show VersionKeys;
import '../services/watch_state.dart';
import '../theme/tokens.dart';
import '../widgets/detail_header.dart';
import '../widgets/messenger.dart' show wiMessengerKey;
import '../widgets/watch_progress.dart';
import 'edit_details_screen.dart';
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
  /// The version currently shown: the picker's selection, else the entry
  /// the navigation passed in. Everything on the page — play, resume
  /// point, download, file info — keys off this.
  MediaEntry get entry => _selected ?? widget.entry;

  MediaEntry? _selected;

  /// Every upload of this title held in the library (same parsed lookup
  /// key, different addresses), in library order — the version picker's
  /// options. Length < 2 hides the picker. Discovered from the loaded
  /// library so every navigation path (wall card, search, Continue
  /// Watching) gets the picker without passing versions around.
  List<MediaEntry> _versions = const [];

  WatchState? _state;
  MediaEntry? _next;
  List<MediaList> _lists = const [];

  /// File size/format shown on the page — starts from the entry the
  /// navigation passed in, upgraded from the library copy (which may
  /// have learned more since) and the `/resolve` backfill.
  int? _sizeBytes;
  String? _videoInfo;

  @override
  void initState() {
    super.initState();
    // No data-map warm needed: every entry's map arrived at import time
    // (datamap-first model) — playback reads it from the local store.
    unawaited(DownloadManager.instance.ensureLoaded());
    unawaited(FavouritesStore.instance.ensureLoaded());
    unawaited(_loadState());
  }

  static String _normalize(String address) =>
      address.toLowerCase().replaceFirst('0x', '');

  /// All uploads of [entry]'s title across the enabled lists (same
  /// parsed lookup key, duplicate addresses dropped), in library order.
  /// [entry] itself is prepended when the library no longer holds it.
  /// Empty for episodes — shows fold by season, not by version.
  List<MediaEntry> _versionsFor(List<MediaList> lists) {
    final parsed = parseMediaName(entry.name);
    if (parsed.isEpisode) return const [];
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
        final p = parseMediaName(e.name);
        if (p.isEpisode || keys.keyFor(p) != key) continue;
        if (seen.add(_normalize(e.address))) found.add(e);
      }
    }
    if (!seen.contains(_normalize(entry.address))) found.insert(0, entry);
    return found;
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
      _versions = _versionsFor(lists);
      // The library's copy of this entry may know more than the object
      // the navigation passed in (size backfilled earlier, format
      // learned on a previous playback).
      final addr = entry.address.toLowerCase();
      _sizeBytes ??= entry.sizeBytes;
      _videoInfo ??= entry.videoInfo;
      for (final l in lists) {
        for (final e in l.entries) {
          if (e.address.toLowerCase() == addr) {
            _sizeBytes ??= e.sizeBytes;
            _videoInfo ??= e.videoInfo;
          }
        }
      }
    });
    unawaited(_fillSizeFromResolve());
  }

  /// Backfill the exact file size for entries that predate the size
  /// column: `GET /resolve` reads it off the locally stored root map
  /// (no network traffic), and the result is persisted for every list
  /// entry holding this address.
  Future<void> _fillSizeFromResolve() async {
    if (_sizeBytes != null) return;
    final base = EmbeddedClient.baseUrl();
    if (base == null) return;
    try {
      final res =
          await http.get(Uri.parse('$base/resolve/${entry.address}'));
      if (res.statusCode != 200) return;
      final size =
          (jsonDecode(res.body) as Map<String, dynamic>)['size'] as int?;
      if (size == null || size <= 0) return;
      await LibraryStore.noteEntryInfo(entry.address, sizeBytes: size);
      if (mounted) setState(() => _sizeBytes = size);
    } catch (_) {
      // Size stays unknown — the page just omits the line.
    }
  }

  /// `480p H.264 · 570 MB`, or null while nothing is known yet.
  String? get _fileInfoLine => formatInfoLine(MediaEntry(
        name: entry.name,
        address: entry.address,
        sizeBytes: _sizeBytes,
        videoInfo: _videoInfo,
      ));

  /// Switch the page to another upload of the same title: resume point,
  /// download state, and file info all reload for the picked version.
  void _selectVersion(MediaEntry version) {
    if (_normalize(version.address) == _normalize(entry.address)) return;
    setState(() {
      _selected = version;
      _state = null;
      _sizeBytes = version.sizeBytes;
      _videoInfo = version.videoInfo;
    });
    unawaited(_loadState());
  }

  /// The picker option label for a version: its format/size line, else a
  /// positional fallback for entries nothing is known about yet.
  String _versionLabel(MediaEntry version, int index) =>
      formatInfoLine(version) ?? 'Version ${index + 1}';

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

  /// Dropdown over [_versions], labeled by each upload's format/size
  /// line (`480p H.264 · 570 MB`). Only rendered with 2+ versions.
  Widget _versionPicker(WiTokens t) {
    final current = _normalize(entry.address);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.video_file_outlined, size: 15, color: t.ash),
        const SizedBox(width: 6),
        DropdownButton<String>(
          value: current,
          isDense: true,
          underline: const SizedBox.shrink(),
          dropdownColor: t.ink2,
          iconEnabledColor: t.boneDim,
          style: TextStyle(fontSize: 12.5, color: t.boneDim),
          items: [
            for (final (i, v) in _versions.indexed)
              DropdownMenuItem(
                value: _normalize(v.address),
                child: Text(_versionLabel(v, i)),
              ),
          ],
          onChanged: (addr) {
            if (addr == null) return;
            for (final v in _versions) {
              if (_normalize(v.address) == addr) {
                _selectVersion(v);
                return;
              }
            }
          },
        ),
      ],
    );
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
        FavouritesStore.instance,
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
        actions: [
          // Edit details: user-authored title/description/artwork — the
          // way in for files TMDB doesn't know. The editor writes the
          // metadata cache; MetadataService notifies and this page's
          // ListenableBuilder repaints with the new details.
          IconButton(
            tooltip: 'Edit details',
            icon: Icon(Icons.edit_outlined, color: t.boneDim, size: 20),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                  builder: (_) => EditDetailsScreen(entry: entry)),
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
              entryPosterImage(meta, fit: BoxFit.cover),
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
                // Format and exact size of this specific upload — what
                // tells two copies of the same title apart. With more
                // than one upload of the title in the library the line
                // becomes a dropdown that switches the page between them.
                if (_versions.length > 1) ...[
                  const SizedBox(height: 6),
                  _versionPicker(t),
                ] else if (_fileInfoLine != null) ...[
                  const SizedBox(height: 4),
                  Text(_fileInfoLine!,
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
                    // Heart the version this page currently shows; the home
                    // screen's Favourites row picks it up. Per-address on
                    // purpose — with two uploads of one title the user
                    // hearts the copy they actually want.
                    IconButton(
                      tooltip: FavouritesStore.instance.isFavourite(entry.address)
                          ? 'Remove from Favourites'
                          : 'Add to Favourites',
                      icon: Icon(
                        FavouritesStore.instance.isFavourite(entry.address)
                            ? Icons.favorite
                            : Icons.favorite_border,
                        color: FavouritesStore.instance.isFavourite(entry.address)
                            ? t.accent
                            : t.boneDim,
                      ),
                      onPressed: () => unawaited(
                          FavouritesStore.instance.toggle(entry.address)),
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
          sectionLabel(t, 'FILE'),
          const SizedBox(height: 6),
          Text(entry.name,
              style: TextStyle(fontSize: 12.5, color: t.boneDim)),
          if (_fileInfoLine != null) ...[
            const SizedBox(height: 4),
            Text(_fileInfoLine!,
                style: TextStyle(fontSize: 12, color: t.ash)),
          ],
        ],
      ),
    );
  }
}
