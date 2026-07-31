import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'models/media_list.dart';
import 'screens/detail_screen.dart';
import 'screens/search_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/show_screen.dart';
import 'services/app_settings.dart';
import 'services/connectivity.dart';
import 'services/download_foreground.dart';
import 'services/download_manager.dart';
import 'services/embedded_client.dart';
import 'services/home_rows.dart';
import 'services/home_sections.dart';
import 'services/library_store.dart';
import 'services/metadata.dart';
import 'services/metadata_service.dart';
import 'services/network_events.dart';
import 'services/rootmap_seeder.dart';
import 'services/season_grouping.dart';
import 'services/watch_state.dart';
import 'theme/tokens.dart';
import 'widgets/brand_mark.dart';
import 'widgets/download_badge.dart';
import 'widgets/downloads_indicator.dart';
import 'widgets/prefetch_dialog.dart';
import 'widgets/tmdb_nudge.dart';
import 'widgets/watch_progress.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  // Start the embedded Autonomi client early so the network bootstrap
  // (tens of seconds) overlaps with browsing instead of delaying playback.
  // Awaited: it must receive the app data dir (ant-core's $HOME on
  // Android) before any other code path can lazily start it without one.
  await EmbeddedClient.start();
  // Background online/offline tracking for Play gating and the Up-next
  // chain (browsing itself is never gated).
  ConnectivityMonitor.instance.start();
  // Downloads auto-pause on connection loss; wire them to auto-resume
  // when the connection is back, and to hold on mobile data when
  // Settings → Network says Wi-Fi only.
  DownloadManager.instance.bindConnectivity(ConnectivityMonitor.instance);
  DownloadManager.instance.bindNetwork(NetworkEvents.instance);
  // Android: keep transfers alive while backgrounded via the dataSync
  // foreground service + progress notification (no-op elsewhere).
  DownloadForegroundBridge.instance.bind(DownloadManager.instance);
  // Reconnect fast-paths: phone wake and OS network changes (cable
  // replug on Linux via NetworkManager) re-probe immediately and kick
  // the embedded client's reconnect supervisor instead of waiting for
  // the next poll/backoff round.
  WidgetsBinding.instance.addObserver(_LifecycleReconnector());
  NetworkEvents.instance.start();
  NetworkEvents.instance.addListener(() {
    if (NetworkEvents.instance.hasNetwork) {
      unawaited(ConnectivityMonitor.instance.onExternalNetworkEvent());
    } else {
      // Network fully gone: just refresh so gating flips fast — no point
      // dialling with no route.
      unawaited(ConnectivityMonitor.instance.refresh());
    }
  });
  // Bundled root data maps (the demo movie) seed the embedded client's
  // store so a fresh install skips the cold network resolve on first
  // play. Fire-and-forget: fully offline, idempotent, verified server-side.
  unawaited(seedBundledRootMaps());
  runApp(const WatchItApp());
}

/// On resume from background (phone wake), the QUIC sockets are often
/// dead but the client still reports ready+0 peers until the supervisor
/// notices — probe and kick right away so reconnection starts while the
/// user is still looking at the app.
class _LifecycleReconnector with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(ConnectivityMonitor.instance.onExternalNetworkEvent());
      // Also restart downloads the app itself parked (6h background
      // budget, connection loss while frozen).
      unawaited(DownloadManager.instance.onAppResumed());
    }
  }
}

class WatchItApp extends StatelessWidget {
  const WatchItApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'W@tch',
      debugShowCheckedModeBanner: false,
      // App-wide messenger so a background data-map prefetch can report
      // its outcome whatever screen is on top when it finishes.
      scaffoldMessengerKey: wiMessengerKey,
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<MediaList> _lists = [];
  List<ContinueItem> _continue = const [];
  List<HomeItem> _recent = const [];
  List<HomeSection> _sections = const [];
  bool _tmdbNudge = false;

  @override
  void initState() {
    super.initState();
    // Watch states change while a player is open on top of this screen —
    // refresh the Continue Watching row as they land.
    WatchStateStore.instance.addListener(_reloadRows);
    // Wall cards badge their download state — have the queue loaded.
    unawaited(DownloadManager.instance.ensureLoaded());
    _reload();
  }

  @override
  void dispose() {
    WatchStateStore.instance.removeListener(_reloadRows);
    super.dispose();
  }

  Future<void> _reload() async {
    await LibraryStore.ensureDefaults();
    final lists = await LibraryStore.load();
    final continueRow = await continueWatching(lists);
    // Re-checked on every reload so the banner disappears as soon as a
    // key is entered in Settings (returning from there reloads).
    final nudge = await shouldShowTmdbNudge();
    final sections =
        reconcileHomeSections(await AppSettings.homeSections(), lists);
    if (!mounted) return;
    setState(() {
      _lists = lists;
      _continue = continueRow;
      _recent = recentlyAdded(lists);
      _sections = sections;
      _tmdbNudge = nudge;
    });
  }

  Future<void> _reloadRows() async {
    final continueRow = await continueWatching(_lists);
    if (mounted) setState(() => _continue = continueRow);
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
    await _reload();
  }

  Future<void> _openSearch() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SearchScreen(lists: _lists)),
    );
    // Playing/downloading from a search result changes the home rows.
    await _reload();
  }

  Future<void> _openEntry(MediaEntry entry) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => DetailScreen(entry: entry)),
    );
  }

  /// A series card opens the show's page: big artwork + synopsis with
  /// every season of the show found in the list as tiles.
  Future<void> _openShow(HomeShow group) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ShowScreen(seasons: group.seasons),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    // Lists unchecked in Settings → Media Lists stay out of the wall.
    final visible = [
      for (final l in _lists)
        if (l.enabled) l,
    ];
    // Desktop/TV nicety: `/` or Ctrl+F opens search (the Focus node
    // gives the shortcuts somewhere to land when nothing else is
    // focused; SearchScreen is its own route, so typing there is safe).
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.slash): _openSearch,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _openSearch,
      },
      child: Focus(autofocus: true, child: _scaffold(t, visible)),
    );
  }

  Widget _scaffold(WiTokens t, List<MediaList> visible) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        // App-bar lockup: the launcher icon's bucket mark + wordmark.
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const BrandMark(height: 16),
            const SizedBox(width: 8),
            const BrandWordmark(fontSize: 18),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Search',
            icon: Icon(Icons.search, color: t.boneDim),
            onPressed: _openSearch,
          ),
          const DownloadsIndicator(),
          IconButton(
            tooltip: 'Settings',
            icon: Icon(Icons.settings_outlined, color: t.boneDim),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Column(
        children: [
          const NetworkStatusBar(),
          if (_tmdbNudge)
            TmdbNudgeBanner(
              onOpenSettings: _openSettings,
              onDismiss: () async {
                await AppSettings.setTmdbNudgeDismissed();
                if (mounted) setState(() => _tmdbNudge = false);
              },
            ),
          Expanded(
            child: visible.isEmpty
                ? _EmptyState(tokens: t, allHidden: _lists.isNotEmpty)
                : _libraryView(t, visible),
          ),
        ],
      ),
    );
  }

  Widget _libraryView(WiTokens t, List<MediaList> lists) {
    // Poster cards upgrade in place as TMDB matches land in the cache,
    // and re-badge as downloads progress.
    return ListenableBuilder(
      listenable: Listenable.merge(
          [MetadataService.instance, DownloadManager.instance]),
      builder: (context, _) => _posterWall(t, lists),
    );
  }

  Widget _sectionTitle(WiTokens t, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: t.bone,
        ),
      ),
    );
  }

  /// One horizontal shelf of wall items (a list's cards, or the Recently
  /// Added row). All episodes of one show — every season — fold into a
  /// single card that opens the show's page.
  Widget _itemsRow(WiTokens t, List<HomeItem> items) {
    return SizedBox(
      height: 232,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (context, i) => switch (items[i]) {
          HomeEntry(:final entry) => _PosterCard(
              entry: entry,
              tokens: t,
              onTap: () => _openEntry(entry),
            ),
          HomeShow() && final group => _ShowCard(
              group: group,
              tokens: t,
              onTap: () => _openShow(group),
            ),
          // groupShows never yields bare seasons.
          HomeSeason() => const SizedBox.shrink(),
        },
      ),
    );
  }

  Widget _posterWall(WiTokens t, List<MediaList> lists) {
    // Computed here (not in _reload) so the row appears, updates, and
    // vanishes live as downloads finish or are removed — this builder
    // already re-runs on every DownloadManager notification.
    final downloads = downloadedItems(lists);
    final listsById = {for (final l in lists) l.id: l};
    // _sections is still empty on the first frame (before _reload lands);
    // reconciling against nothing yields the default order either way.
    final sections = _sections.isNotEmpty
        ? _sections
        : reconcileHomeSections(const [], lists);
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        for (final section in sections)
          if (section.visible)
            ...switch (section.id) {
              kSectionContinue => _continueSection(t),
              kSectionDownloads => downloads.isEmpty
                  ? const <Widget>[]
                  : [_sectionTitle(t, 'Downloads'), _itemsRow(t, downloads)],
              kSectionRecent => _recent.isEmpty
                  ? const <Widget>[]
                  : [_sectionTitle(t, 'Recently Added'), _itemsRow(t, _recent)],
              // Sections whose list is hidden or was deleted after the
              // last reconcile render nothing.
              _ => _listSection(t, listsById[section.listId]),
            },
      ],
    );
  }

  List<Widget> _continueSection(WiTokens t) {
    if (_continue.isEmpty) return const [];
    return [
      _sectionTitle(t, 'Continue Watching'),
      SizedBox(
        height: 232,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: _continue.length,
          separatorBuilder: (_, _) => const SizedBox(width: 12),
          itemBuilder: (context, i) => _ContinueCard(
            item: _continue[i],
            tokens: t,
            onTap: () => _openEntry(_continue[i].entry),
          ),
        ),
      ),
    ];
  }

  List<Widget> _listSection(WiTokens t, MediaList? list) {
    if (list == null) return const [];
    return [
      _sectionTitle(t, list.title),
      if (list.entries.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Empty list — add entries in Settings.',
            style: TextStyle(fontSize: 12, color: t.ash),
          ),
        )
      else
        _itemsRow(t, groupShows(list.entries)),
    ];
  }
}

/// Slim banner under the app bar showing the embedded Autonomi client's
/// connection state and peer count, refreshed on a timer (fast while
/// connecting, relaxed once ready — the poll is a localhost call).
class NetworkStatusBar extends StatefulWidget {
  const NetworkStatusBar({super.key});

  @override
  State<NetworkStatusBar> createState() => _NetworkStatusBarState();
}

class _NetworkStatusBarState extends State<NetworkStatusBar> {
  ClientHealth? _health;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _poll();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    final health = await EmbeddedClient.health();
    if (!mounted) return;
    setState(() => _health = health);
    if (health.state == 'unavailable') return; // no native library; stop
    _timer = Timer(
      Duration(seconds: health.state == 'ready' ? 15 : 3),
      _poll,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final h = _health;
    if (h == null || h.state == 'unavailable') return const SizedBox.shrink();
    final (color, text) = switch (h.state) {
      'ready' => (
          const Color(0xff4caf50),
          'Autonomi network: connected · ${h.peers} '
              '${h.peers == 1 ? 'peer' : 'peers'}',
        ),
      'connecting' => (
          t.accent,
          h.message == null
              ? 'Autonomi network: connecting…'
                  '${h.attempts > 1 ? ' (attempt ${h.attempts})' : ''}'
              : 'Autonomi network: connecting (attempt ${h.attempts}) — '
                  '${h.message}',
        ),
      _ => (const Color(0xffe57373), 'Autonomi network: error'),
    };
    return Container(
      width: double.infinity,
      color: t.ink2,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: t.boneDim),
            ),
          ),
        ],
      ),
    );
  }
}

class _PosterCard extends StatelessWidget {
  const _PosterCard({
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

/// Continue Watching card: the poster with a progress bar along its
/// bottom edge for a partially watched file, or a "Next up" tag for the
/// episode after a finished one. Tap opens the detail page (which offers
/// Resume / Play).
class _ContinueCard extends StatelessWidget {
  const _ContinueCard({
    required this.item,
    required this.tokens,
    required this.onTap,
  });

  final ContinueItem item;
  final WiTokens tokens;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    final entry = item.entry;
    final meta = MetadataService.instance.metadataFor(entry);
    final parsed = parseMediaName(entry.name);
    final marker = parsed.isEpisode
        ? 'S${parsed.season.toString().padLeft(2, '0')}'
            'E${parsed.episode.toString().padLeft(2, '0')}'
        : null;
    final state = item.state;
    final progress = state != null && state.resumable ? state.progress : null;
    final subtitle = [
      if (item.isNextUp) 'Next up',
      ?marker,
      if (!item.isNextUp)
        state?.remainingLabel ?? (progress != null ? 'In progress' : null),
    ].nonNulls.join(' · ');
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
                          child: Icon(
                              marker != null
                                  ? Icons.live_tv_outlined
                                  : Icons.movie_outlined,
                              color: t.ash,
                              size: 40),
                        ),
                    if (progress != null && progress > 0)
                      watchProgressBar(t, progress),
                    ?entryDownloadBadge(t, entry),
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
            if (subtitle.isNotEmpty)
              Text(
                subtitle,
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

/// A whole show folded into one wall card: the show's main poster with
/// its name and season/episode counts underneath. Tap opens the show
/// page, which lists the seasons.
class _ShowCard extends StatelessWidget {
  const _ShowCard({
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

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.tokens, this.allHidden = false});

  final WiTokens tokens;

  /// Lists exist but every one is unchecked in Settings → Media Lists.
  final bool allHidden;

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.play_circle_outline, size: 64, color: t.accent),
          const SizedBox(height: 16),
          Text(
            allHidden ? 'All your lists are hidden' : 'Your library is empty',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: t.bone,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            allHidden
                ? 'Enable a list in Settings → Media Lists to show it here.'
                : 'Create a media list in Settings to get started.',
            style: TextStyle(fontSize: 12, color: t.ash),
          ),
        ],
      ),
    );
  }
}
