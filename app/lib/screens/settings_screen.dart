import 'package:flutter/material.dart';

import '../models/media_list.dart';
import '../services/library_store.dart';
import '../services/embedded_client.dart';
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

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final lists = await LibraryStore.load();
    final health = await EmbeddedClient.health();
    if (mounted) {
      setState(() {
        _lists = lists;
        _health = health;
      });
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
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 80),
                  child: Text(
                    'Playback streams through the Autonomi client embedded '
                    'in the app — nothing to set up. Tap to refresh the '
                    'connection status.',
                    style: TextStyle(fontSize: 11.5, color: t.ash),
                  ),
                ),
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
