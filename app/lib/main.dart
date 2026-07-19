import 'package:flutter/material.dart';

import 'models/media_list.dart';
import 'screens/settings_screen.dart';
import 'services/library_store.dart';
import 'theme/tokens.dart';

void main() {
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
    final lists = await LibraryStore.load();
    if (mounted) setState(() => _lists = lists);
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Text(
          'watch-it',
          style: TextStyle(
            fontFamily: wiMonoFamily,
            fontFamilyFallback: wiMonoFallback,
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: t.bone,
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
      body: _lists.isEmpty ? _EmptyState(tokens: t) : _libraryView(t),
    );
  }

  Widget _libraryView(WiTokens t) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        for (final list in _lists) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
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
            ),
          for (final entry in list.entries)
            ListTile(
              dense: true,
              leading: Icon(Icons.movie_outlined, color: t.copper, size: 20),
              title: Text(entry.name,
                  style: TextStyle(color: t.boneDim, fontSize: 13)),
            ),
        ],
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.tokens});

  final WiTokens tokens;

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
            'Your library is empty',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: t.bone,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Create a media list in Settings to get started.',
            style: TextStyle(fontSize: 12, color: t.ash),
          ),
        ],
      ),
    );
  }
}
