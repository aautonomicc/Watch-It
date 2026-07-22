import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../models/media_list.dart';
import '../services/app_settings.dart';
import '../services/library_store.dart';
import '../services/embedded_client.dart';
import '../services/metadata_service.dart';
import '../theme/tokens.dart';
import 'media_lists_screen.dart';

/// Settings: library, streaming, metadata, and about sections.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  List<MediaList>? _lists;
  ClientHealth? _health;
  String? _version;
  Timer? _healthTimer;
  int _bufferSizeMb = AppSettings.defaultBufferSizeMb;
  TmdbKeySource _tmdbKeySource = TmdbKeySource.none;

  @override
  void initState() {
    super.initState();
    _reload();
    _loadVersion();
    _scheduleHealthPoll();
  }

  @override
  void dispose() {
    _healthTimer?.cancel();
    super.dispose();
  }

  /// Keep the status tile live: fast poll while connecting, relaxed once
  /// ready (localhost call, so polling is cheap).
  void _scheduleHealthPoll() {
    _healthTimer = Timer(
      Duration(seconds: _health?.state == 'ready' ? 15 : 3),
      () async {
        await _refreshHealth();
        if (mounted && _health?.state != 'unavailable') _scheduleHealthPoll();
      },
    );
  }

  Future<void> _reload() async {
    final lists = await LibraryStore.load();
    final health = await EmbeddedClient.health();
    final bufferSizeMb = await AppSettings.bufferSizeMb();
    final tmdbKeySource = await AppSettings.tmdbKeySource();
    if (mounted) {
      setState(() {
        _lists = lists;
        _health = health;
        _bufferSizeMb = bufferSizeMb;
        _tmdbKeySource = tmdbKeySource;
      });
    }
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() => _version = '${info.version} (build ${info.buildNumber})');
      }
    } catch (_) {
      // Platform channel unavailable (tests, bare desktop builds).
    }
  }

  Future<void> _refreshHealth() async {
    final health = await EmbeddedClient.health();
    if (mounted) setState(() => _health = health);
  }

  Future<void> _pickBufferSize() async {
    final t = WiTokens.of(context);
    final picked = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        backgroundColor: t.ink2,
        title: Text('Buffer size',
            style: TextStyle(color: t.bone, fontSize: 16)),
        children: [
          RadioGroup<int>(
            groupValue: _bufferSizeMb,
            onChanged: (v) => Navigator.of(context).pop(v),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final mb in AppSettings.bufferSizeOptionsMb)
                  RadioListTile<int>(
                    value: mb,
                    activeColor: t.copper,
                    title: Text(
                      '$mb MB'
                      '${mb == AppSettings.defaultBufferSizeMb ? '  ·  default' : ''}',
                      style: TextStyle(color: t.bone, fontSize: 14),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked == null) return;
    await AppSettings.setBufferSizeMb(picked);
    if (mounted) setState(() => _bufferSizeMb = picked);
  }

  /// The key in use is never prefilled or displayed — only where it came
  /// from — so the bundled key can't be copied out of the app.
  Future<void> _editTmdbApiKey() async {
    final entered = await promptForText(
      context,
      title: 'TMDB API key',
      hint: _tmdbKeySource == TmdbKeySource.user
          ? 'New key (leave empty to remove yours)'
          : 'API key or read access token',
    );
    if (entered == null) return;
    // An empty save only means something when a user key exists to remove.
    if (entered.trim().isEmpty && _tmdbKeySource != TmdbKeySource.user) {
      return;
    }
    await AppSettings.setTmdbApiKey(entered);
    // Re-run matching with the new credential (also clears cached misses).
    await MetadataService.instance.reset();
    final source = await AppSettings.tmdbKeySource();
    if (mounted) setState(() => _tmdbKeySource = source);
  }

  Future<void> _openMediaLists() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const MediaListsScreen()),
    );
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final lists = _lists;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Text('Settings', style: TextStyle(color: t.bone, fontSize: 18)),
      ),
      body: lists == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                  child: Text(
                    'LIBRARY',
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w700,
                      color: t.ash,
                    ),
                  ),
                ),
                ListTile(
                  leading: Icon(Icons.video_library_outlined, color: t.copper),
                  title: Text('Media Lists',
                      style: TextStyle(color: t.bone, fontSize: 15)),
                  subtitle: Text(
                    lists.isEmpty
                        ? 'No lists yet'
                        : '${lists.length} '
                            '${lists.length == 1 ? 'list' : 'lists'} · '
                            '${lists.where((l) => l.enabled).length} shown '
                            'on home',
                    style: TextStyle(color: t.ash, fontSize: 12),
                  ),
                  trailing: Icon(Icons.chevron_right, color: t.ash),
                  onTap: _openMediaLists,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 28, 16, 8),
                  child: Text(
                    'STREAMING',
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w700,
                      color: t.ash,
                    ),
                  ),
                ),
                ListTile(
                  leading: Icon(Icons.cloud_outlined, color: t.copper),
                  title: Text('Built-in Autonomi client',
                      style: TextStyle(color: t.bone, fontSize: 15)),
                  subtitle: Text(
                    _health?.label ?? 'Checking…',
                    style: TextStyle(color: t.ash, fontSize: 12),
                  ),
                  trailing: Icon(Icons.refresh, color: t.ash, size: 18),
                  onTap: _refreshHealth,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Text(
                    'Playback streams through the Autonomi client embedded '
                    'in the app — nothing to set up. Tap to refresh the '
                    'connection status.',
                    style: TextStyle(fontSize: 11.5, color: t.ash),
                  ),
                ),
                ListTile(
                  leading: Icon(Icons.memory_outlined, color: t.copper),
                  title: Text('Buffer size',
                      style: TextStyle(color: t.bone, fontSize: 15)),
                  subtitle: Text(
                    '$_bufferSizeMb MB',
                    style: TextStyle(color: t.ash, fontSize: 12),
                  ),
                  trailing: Icon(Icons.chevron_right, color: t.ash),
                  onTap: _pickBufferSize,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Text(
                    'How much video the player keeps in memory while '
                    'streaming. Larger buffers ride out slow patches of the '
                    'network but use more RAM (the same amount again is kept '
                    'behind the play position for instant rewind). Takes '
                    'effect the next time you press Play.',
                    style: TextStyle(fontSize: 11.5, color: t.ash),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 28, 16, 8),
                  child: Text(
                    'METADATA',
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w700,
                      color: t.ash,
                    ),
                  ),
                ),
                ListTile(
                  leading: Icon(Icons.image_search_outlined, color: t.copper),
                  title: Text('TMDB API key',
                      style: TextStyle(color: t.bone, fontSize: 15)),
                  subtitle: Text(
                    switch (_tmdbKeySource) {
                      TmdbKeySource.user => 'Using your key',
                      TmdbKeySource.bundled => 'Using the built-in key',
                      TmdbKeySource.none =>
                        'Not set — titles come from file names only',
                    },
                    style: TextStyle(color: t.ash, fontSize: 12),
                  ),
                  trailing: Icon(Icons.chevron_right, color: t.ash),
                  onTap: _editTmdbApiKey,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Text(
                    'Artwork, descriptions, and categories are matched from '
                    'TMDB using each entry\'s file name, then cached on this '
                    'device. To use your own key, create a free one at '
                    'themoviedb.org (Settings → API) and paste either the '
                    'API key or the read access token here — it overrides '
                    'the built-in key and is never displayed.',
                    style: TextStyle(fontSize: 11.5, color: t.ash),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 28, 16, 8),
                  child: Text(
                    'ABOUT',
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w700,
                      color: t.ash,
                    ),
                  ),
                ),
                ListTile(
                  leading: Icon(Icons.play_circle_outline, color: t.copper),
                  title: Text(
                    'watch-it',
                    style: TextStyle(
                      fontFamily: wiMonoFamily,
                      fontFamilyFallback: wiMonoFallback,
                      fontWeight: FontWeight.w700,
                      color: t.bone,
                      fontSize: 15,
                    ),
                  ),
                  subtitle: Text(
                    'Media player for the Autonomi network. Client-only: '
                    'your library is a set of lists you hold on this '
                    'device — no server, no accounts, no telemetry.',
                    style: TextStyle(color: t.ash, fontSize: 12),
                  ),
                ),
                ListTile(
                  leading: Icon(Icons.info_outline, color: t.copper),
                  title: Text('Version',
                      style: TextStyle(color: t.bone, fontSize: 15)),
                  subtitle: Text(
                    _version ?? 'Unknown',
                    style: TextStyle(color: t.ash, fontSize: 12),
                  ),
                ),
                const SizedBox(height: 80),
              ],
            ),
    );
  }
}

/// Single-field text prompt used for list titles and renames.
Future<String?> promptForText(
  BuildContext context, {
  required String title,
  required String hint,
  String initial = '',
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) {
      final t = WiTokens.of(context);
      return AlertDialog(
        backgroundColor: t.ink2,
        title: Text(title, style: TextStyle(color: t.bone, fontSize: 16)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: t.bone),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: t.ash),
          ),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Cancel', style: TextStyle(color: t.ash)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: Text('Save', style: TextStyle(color: t.copper)),
          ),
        ],
      );
    },
  );
}
