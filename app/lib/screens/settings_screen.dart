import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../models/media_list.dart';
import '../services/app_settings.dart';
import '../services/library_store.dart';
import '../services/embedded_client.dart';
import '../services/metadata_service.dart';
import '../theme/tokens.dart';
import 'list_edit_screen.dart';

/// Settings: manage media lists (create, open for editing, delete).
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
  String _tmdbApiKey = '';

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
    final tmdbApiKey = await AppSettings.tmdbApiKey();
    if (mounted) {
      setState(() {
        _lists = lists;
        _health = health;
        _bufferSizeMb = bufferSizeMb;
        _tmdbApiKey = tmdbApiKey;
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

  Future<void> _createList() async {
    final title = await promptForText(
      context,
      title: 'New media list',
      hint: 'List title',
    );
    if (title == null || title.trim().isEmpty) return;
    final lists = List<MediaList>.of(_lists ?? []);
    lists.add(MediaList(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: title.trim(),
    ));
    await LibraryStore.save(lists);
    if (mounted) setState(() => _lists = lists);
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

  Future<void> _editTmdbApiKey() async {
    final entered = await promptForText(
      context,
      title: 'TMDB API key',
      hint: 'API key or read access token (empty to disable)',
      initial: _tmdbApiKey,
    );
    if (entered == null || entered.trim() == _tmdbApiKey) return;
    await AppSettings.setTmdbApiKey(entered);
    final key = await AppSettings.tmdbApiKey();
    // Re-run matching with the new credential (also clears cached misses).
    await MetadataService.instance.reset();
    if (mounted) setState(() => _tmdbApiKey = key);
  }

  Future<void> _openList(MediaList list) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ListEditScreen(listId: list.id)),
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createList,
        backgroundColor: t.copper,
        foregroundColor: t.ink,
        icon: const Icon(Icons.add),
        label: const Text('New list'),
      ),
      body: lists == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                  child: Text(
                    'MEDIA LISTS',
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w700,
                      color: t.ash,
                    ),
                  ),
                ),
                if (lists.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'No lists yet. Create one to start adding media.',
                      style: TextStyle(fontSize: 13, color: t.boneDim),
                    ),
                  ),
                for (final list in lists)
                  ListTile(
                    leading: Icon(Icons.video_library_outlined,
                        color: t.copper),
                    title: Text(list.title,
                        style: TextStyle(color: t.bone, fontSize: 15)),
                    subtitle: Text(
                      '${list.entries.length} '
                      '${list.entries.length == 1 ? 'entry' : 'entries'}',
                      style: TextStyle(color: t.ash, fontSize: 12),
                    ),
                    trailing: Icon(Icons.chevron_right, color: t.ash),
                    onTap: () => _openList(list),
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
                    _tmdbApiKey.isEmpty
                        ? 'Not set — titles come from file names only'
                        : 'Set (…${_tmdbApiKey.substring(_tmdbApiKey.length < 4 ? 0 : _tmdbApiKey.length - 4)})',
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
                    'device. Create a free API key at themoviedb.org '
                    '(Settings → API) and paste either the API key or the '
                    'read access token here.',
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
