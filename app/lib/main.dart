import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'models/media_list.dart';
import 'screens/detail_screen.dart';
import 'screens/settings_screen.dart';
import 'services/embedded_client.dart';
import 'services/library_store.dart';
import 'services/metadata_service.dart';
import 'theme/tokens.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  // Start the embedded Autonomi client early so the network bootstrap
  // (tens of seconds) overlaps with browsing instead of delaying playback.
  // Awaited: it must receive the app data dir (ant-core's $HOME on
  // Android) before any other code path can lazily start it without one.
  await EmbeddedClient.start();
  runApp(const WatchItApp());
}

class WatchItApp extends StatelessWidget {
  const WatchItApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'watch-it',
      debugShowCheckedModeBanner: false,
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

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    await LibraryStore.ensureDefaults();
    final lists = await LibraryStore.load();
    if (mounted) setState(() => _lists = lists);
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
    await _reload();
  }

  Future<void> _openEntry(MediaEntry entry) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => DetailScreen(entry: entry)),
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
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        // App-bar lockup: the launcher icon's copper [>] mark + wordmark.
        title: Text.rich(
          TextSpan(
            style: TextStyle(
              fontFamily: wiMonoFamily,
              fontFamilyFallback: wiMonoFallback,
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: t.bone,
            ),
            children: [
              TextSpan(text: '[>] ', style: TextStyle(color: t.copper)),
              const TextSpan(text: 'watch-it'),
            ],
          ),
        ),
        actions: [
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
    // Poster cards upgrade in place as TMDB matches land in the cache.
    return ListenableBuilder(
      listenable: MetadataService.instance,
      builder: (context, _) => _posterWall(t, lists),
    );
  }

  Widget _posterWall(WiTokens t, List<MediaList> lists) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        for (final list in lists) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              list.title,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: t.bone,
              ),
            ),
          ),
          if (list.entries.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Empty list — add entries in Settings.',
                style: TextStyle(fontSize: 12, color: t.ash),
              ),
            )
          else
            SizedBox(
              height: 232,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: list.entries.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, i) => _PosterCard(
                  entry: list.entries[i],
                  tokens: t,
                  onTap: () => _openEntry(list.entries[i]),
                ),
              ),
            ),
        ],
      ],
    );
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
          t.copper,
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
                child: posterImage(meta, fit: BoxFit.cover) ??
                    Container(
                      color: t.ink2,
                      child:
                          Icon(Icons.movie_outlined, color: t.ash, size: 40),
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
          Icon(Icons.play_circle_outline, size: 64, color: t.copper),
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
