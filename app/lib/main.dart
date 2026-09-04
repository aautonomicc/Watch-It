import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:url_launcher/url_launcher.dart';

import 'models/media_list.dart';
import 'screens/album_screen.dart';
import 'screens/artist_screen.dart';
import 'screens/batch_upload_screen.dart' show offerBatchResume;
import 'screens/detail_screen.dart';
import 'screens/search_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/show_screen.dart';
import 'screens/terms_screen.dart';
import 'services/app_settings.dart';
import 'services/connectivity.dart';
import 'services/download_foreground.dart';
import 'services/media_session.dart';
import 'services/now_playing.dart';
import 'services/download_manager.dart';
import 'services/embedded_client.dart';
import 'services/channel_service.dart';
import 'services/favourites.dart';
import 'services/home_rows.dart';
import 'services/home_sections.dart';
import 'services/library_store.dart';
import 'services/licenses.dart';
import 'services/metadata.dart';
import 'services/metadata_service.dart';
import 'services/network_events.dart';
import 'services/network_pause.dart';
import 'services/metadata_seeder.dart';
import 'services/my_watch_sync.dart';
import 'services/rootmap_seeder.dart';
import 'services/season_grouping.dart';
import 'services/terms.dart';
import 'services/update_check.dart';
import 'services/watch_state.dart';
import 'services/x0x_cellular.dart';
import 'theme/tokens.dart';
import 'widgets/brand_mark.dart';
import 'widgets/download_badge.dart';
import 'widgets/channel_avatar.dart';
import 'widgets/channel_badge.dart';
import 'widgets/downloads_indicator.dart';
import 'widgets/library_drawer.dart';
import 'widgets/messenger.dart';
import 'widgets/poster_cards.dart';
import 'widgets/tmdb_nudge.dart';
import 'widgets/watch_progress.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  // Statically linked Rust crates (self_encryption is GPL-3.0) and the
  // native media libs aren't in Flutter's registry — add them so the
  // Settings licenses page is the complete combined-work notice.
  registerNativeLicenses();
  // Start the embedded Autonomi client early so the network bootstrap
  // (tens of seconds) overlaps with browsing instead of delaying playback.
  // Awaited: it must receive the app data dir (ant-core's $HOME on
  // Android) before any other code path can lazily start it without one.
  await EmbeddedClient.start();
  // Re-apply a persisted network pause before the first dial gets far:
  // a user who paused the app expects it to stay quiet across restarts.
  unawaited(NetworkPause.instance.start());
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
  // Android: music keeps playing with the screen off via the
  // mediaPlayback foreground service, with controls + track info in the
  // notification shade and on the lock screen (no-op elsewhere).
  MediaSessionBridge.instance.bind(NowPlaying.instance);
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
  // Bundled TMDB metadata + artwork for the seed catalog: a fresh
  // keyless install shows posters/descriptions without a TMDB key.
  // Gap-fill (existing rows/files win) behind a one-time flag.
  unawaited(seedBundledMetadata());
  // Desktop update check-and-notify: ≤once/24h against GitHub releases,
  // behind the Settings → About toggle; a newer tag shows a quiet
  // snackbar and a Settings row. Silent on failure/offline.
  UpdateCheck.instance.addListener(() {
    final tag = UpdateCheck.instance.availableTag;
    if (tag == null) return;
    final url = UpdateCheck.instance.releaseUrl;
    wiMessengerKey.currentState?.showSnackBar(SnackBar(
      content: Text('Update available: $tag'),
      duration: const Duration(seconds: 8),
      action: url == null
          ? null
          : SnackBarAction(
              label: 'View',
              onPressed: () => launchUrl(Uri.parse(url)),
            ),
    ));
  });
  unawaited(UpdateCheck.instance.maybeCheck());
  // My W@tch background sync: publishes this device's lists/viewpoints
  // into the link store and merges the other devices' changes, every 30s
  // while linked (a silent no-op otherwise).
  MyWatchSync.instance.start();
  // Channels auto-update: follows subscribed channels' signed heads and
  // imports newer manifests (a silent no-op with no subscriptions).
  ChannelService.instance.start();
  // Mobile-data gates for the x0x agents (Settings → Network → Mobile
  // data): pause My W@tch / Channels on cellular when set to Wi-Fi
  // only, resume when Wi-Fi returns. A no-op with the default
  // everything-allowed settings.
  X0xCellularGate.instance.start();
  // Colour scheme (dark default / light / system) before the first frame
  // so the app never flashes the wrong theme.
  wiThemeMode.value = await AppSettings.themeMode();
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

/// Lets HomeScreen reload when a pushed page pops back to it — routes can
/// be pushed from the library drawer, which can't reach the home state.
final RouteObserver<ModalRoute<void>> wiRouteObserver =
    RouteObserver<ModalRoute<void>>();

class WatchItApp extends StatelessWidget {
  const WatchItApp({super.key});

  @override
  Widget build(BuildContext context) {
    // themeMode picks between the pair: dark (default) keeps the app's
    // original look, light uses the light token set, system follows the
    // OS. The notifier flips live from Settings → Appearance.
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: wiThemeMode,
      builder: (context, mode, _) => MaterialApp(
        title: 'W@tch',
        debugShowCheckedModeBanner: false,
        // App-wide messenger so background work (download auto-resume)
        // can report its outcome whatever screen is on top.
        scaffoldMessengerKey: wiMessengerKey,
        navigatorObservers: [wiRouteObserver],
        theme: wiTheme(WiTokens.light, brightness: Brightness.light),
        darkTheme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        themeMode: mode,
        home: const TermsGate(child: HomeScreen()),
      ),
    );
  }
}

/// First-launch gate: holds the app on the Terms of Use & Disclaimer
/// until the current [kTermsVersion] has been accepted (re-shown after a
/// terms bump). Everything behind it — including the network client
/// started in main() — keeps warming up; only the UI waits.
class TermsGate extends StatefulWidget {
  const TermsGate({super.key, required this.child});

  final Widget child;

  @override
  State<TermsGate> createState() => _TermsGateState();
}

class _TermsGateState extends State<TermsGate> {
  int? _acceptedVersion;

  @override
  void initState() {
    super.initState();
    AppSettings.termsAcceptedVersion().then((v) {
      if (mounted) setState(() => _acceptedVersion = v);
    });
  }

  Future<void> _accept() async {
    await AppSettings.setTermsAccepted(kTermsVersion);
    if (mounted) setState(() => _acceptedVersion = kTermsVersion);
  }

  @override
  Widget build(BuildContext context) {
    final accepted = _acceptedVersion;
    // One frame of blank scaffold while the pref loads (local read).
    if (accepted == null) return const Scaffold(body: SizedBox.shrink());
    if (accepted >= kTermsVersion) return widget.child;
    return TermsScreen(onAccept: _accept);
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with RouteAware {
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
    // A background My W@tch sync can add/remove list entries under us.
    MyWatchSync.revision.addListener(_reload);
    // A channel auto-update can replace a channel list under us.
    ChannelService.revision.addListener(_reload);
    // Wall cards badge their download state — have the queue loaded.
    unawaited(DownloadManager.instance.ensureLoaded());
    // A crash or shutdown can leave a batch upload cut short — once per
    // launch, offer to continue it (and sweep finished batch records).
    // A silent no-op on mobile or with nothing interrupted.
    unawaited(offerBatchResume(context));
    _reload();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    wiRouteObserver.subscribe(this, ModalRoute.of(context)!);
  }

  @override
  void dispose() {
    wiRouteObserver.unsubscribe(this);
    WatchStateStore.instance.removeListener(_reloadRows);
    MyWatchSync.revision.removeListener(_reload);
    ChannelService.revision.removeListener(_reload);
    super.dispose();
  }

  /// A pushed page popped back to home. Pages can change the library,
  /// watch states, downloads, or settings (the drawer's Media/Settings
  /// pages push without going through the _open* helpers below) — reload.
  @override
  void didPopNext() {
    unawaited(_reload());
  }

  Future<void> _reload() async {
    await LibraryStore.ensureDefaults();
    // The hearted addresses behind the Favourites row must be in before
    // the first build settles.
    await FavouritesStore.instance.ensureLoaded();
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

  // Reloading on return is didPopNext's job — no _reload() here.
  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  Future<void> _openSearch() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SearchScreen(lists: _lists)),
    );
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

  /// An album card opens the album page: cover art + tracklist.
  Future<void> _openAlbum(HomeAlbum group) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => AlbumScreen(group: group)),
    );
  }

  /// An artist card opens the artist page: their albums as tiles.
  Future<void> _openArtist(HomeArtist group) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ArtistScreen(group: group)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    // Lists unchecked in Settings → My Media stay out of the wall.
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
      // Left drawer for hopping straight to a list's page. Flutter would
      // put the drawer hamburger in `leading` — search claims that slot
      // instead, and the drawer opens from the menu action on the far
      // right (same pattern as ListHomeScreen).
      drawer: const WiLibraryDrawer(),
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        leading: IconButton(
          tooltip: 'Search',
          icon: Icon(Icons.search, color: t.boneDim),
          onPressed: _openSearch,
        ),
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
          const DownloadsIndicator(),
          Builder(
            builder: (context) => IconButton(
              tooltip: 'Browse lists',
              icon: Icon(Icons.menu, color: t.boneDim),
              onPressed: () => Scaffold.of(context).openDrawer(),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
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
                ? _EmptyState(
                    tokens: t,
                    variant: _lists.isNotEmpty
                        ? _EmptyVariant.allHidden
                        : _EmptyVariant.empty)
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
      listenable: Listenable.merge([
        MetadataService.instance,
        DownloadManager.instance,
        FavouritesStore.instance,
      ]),
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
          HomeEntry() && final item => PosterCard(
              entry: item.entry,
              versions: item.allVersions,
              tokens: t,
              onTap: () => _openEntry(item.entry),
            ),
          HomeShow() && final group => ShowCard(
              group: group,
              tokens: t,
              onTap: () => _openShow(group),
            ),
          HomeAlbum() && final album => AlbumCard(
              group: album,
              tokens: t,
              onTap: () => _openAlbum(album),
            ),
          HomeArtist() && final artist => ArtistCard(
              group: artist,
              tokens: t,
              onTap: () => _openArtist(artist),
            ),
          // groupShows never yields bare seasons.
          HomeSeason() => const SizedBox.shrink(),
        },
      ),
    );
  }

  Widget _posterWall(WiTokens t, List<MediaList> lists) {
    // Computed here (not in _reload) so the rows appear, update, and
    // vanish live as downloads finish or hearts are toggled — this
    // builder already re-runs on every DownloadManager and
    // FavouritesStore notification.
    final downloads = downloadedItems(lists);
    final favourites = favouriteItems(lists);
    final listsById = {for (final l in lists) l.id: l};
    // _sections is still empty on the first frame (before _reload lands);
    // reconciling against nothing yields the default order either way.
    final sections = _sections.isNotEmpty
        ? _sections
        : reconcileHomeSections(const [], lists);
    final children = <Widget>[];
    for (final section in sections) {
      if (section.isSpecial) {
        if (!section.visible) continue;
        children.addAll(switch (section.id) {
          kSectionContinue => _continueSection(t, _continue),
          kSectionFavourites => favourites.isEmpty
              ? const <Widget>[]
              : [_sectionTitle(t, 'Favourites'), _itemsRow(t, favourites)],
          kSectionDownloads => downloads.isEmpty
              ? const <Widget>[]
              : [_sectionTitle(t, 'Downloads'), _itemsRow(t, downloads)],
          _ => _recent.isEmpty
              ? const <Widget>[]
              : [
                  _sectionTitle(t, 'Recently Added'),
                  _itemsRow(t, _recent)
                ],
        });
      } else if (section.visible) {
        // Sections whose list is hidden or was deleted after the last
        // reconcile render nothing.
        children.addAll(_listSection(t, listsById[section.listId]));
      }
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: children,
    );
  }

  List<Widget> _continueSection(WiTokens t, List<ContinueItem> items) {
    if (items.isEmpty) return const [];
    return [
      _sectionTitle(t, 'Continue Watching'),
      SizedBox(
        height: 232,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: items.length,
          separatorBuilder: (_, _) => const SizedBox(width: 12),
          itemBuilder: (context, i) => _ContinueCard(
            item: items[i],
            tokens: t,
            onTap: () => _openEntry(items[i].entry),
          ),
        ),
      ),
    ];
  }

  List<Widget> _listSection(WiTokens t, MediaList? list) {
    if (list == null) return const [];
    return [
      // Channel rows are badged amber — public content is visibly not
      // "your" list even where it renders like one.
      if (list.isChannel)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              // The channel's mini avatar — identity beside the badge
              // (podcasts-icon fallback when the channel has none).
              ChannelAvatar(memberName: list.channelAvatar, size: 18),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  list.title,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: t.bone,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const ChannelBadge(),
            ],
          ),
        )
      else
        _sectionTitle(t, list.title),
      if (list.entries.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Empty list — fill it with "Add to library" in '
            'Settings → My Media.',
            style: TextStyle(fontSize: 12, color: t.ash),
          ),
        )
      else
        _itemsRow(t, groupShows(list.entries)),
    ];
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
                                  : parsed.isAudio
                                      ? Icons.music_note
                                      : Icons.movie_outlined,
                              color: t.ash,
                              size: 40),
                        ),
                    if (progress != null && progress > 0)
                      watchProgressBar(t, progress),
                    // Music badge: a track resumed here is "continue
                    // listening" — tell it from video at a glance.
                    if (parsed.isAudio)
                      Positioned(
                        top: 5,
                        left: 5,
                        child: Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.65),
                            shape: BoxShape.circle,
                          ),
                          child:
                              Icon(Icons.music_note, size: 13, color: t.accent),
                        ),
                      ),
                    // Aggregated across the title's quality tiers — a
                    // downloaded 1080p copy badges the card even when
                    // the resume point is on the 480p upload.
                    ?versionsDownloadBadge(t, item.allVersions),
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

enum _EmptyVariant {
  /// No media anywhere.
  empty,

  /// Lists exist but every one is unchecked in Settings → My Media.
  allHidden,
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.tokens, this.variant = _EmptyVariant.empty});

  final WiTokens tokens;
  final _EmptyVariant variant;

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    final (title, hint) = switch (variant) {
      _EmptyVariant.empty => (
          'Your library is empty',
          'Use "Add to library" in Settings → My Media to get started.',
        ),
      _EmptyVariant.allHidden => (
          'All your lists are hidden',
          'Enable a list in Settings → My Media to show it here.',
        ),
    };
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.play_circle_outline, size: 64, color: t.accent),
          const SizedBox(height: 16),
          Text(
            title,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: t.bone,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            hint,
            style: TextStyle(fontSize: 12, color: t.ash),
          ),
        ],
      ),
    );
  }
}
