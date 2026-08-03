import 'package:flutter/material.dart';

import '../models/media_list.dart';
import '../services/library_store.dart';
import '../theme/tokens.dart';
import 'settings_screen.dart' show promptForText;

/// Edit one media list: rename, delete, remove entries. Media is added
/// on the Media page ("Add to library"), which can also create lists —
/// this screen only curates what an import put in the library.
class ListEditScreen extends StatefulWidget {
  const ListEditScreen({super.key, required this.listId});

  final String listId;

  @override
  State<ListEditScreen> createState() => _ListEditScreenState();
}

class _ListEditScreenState extends State<ListEditScreen> {
  List<MediaList>? _lists;

  MediaList? get _list {
    final lists = _lists;
    if (lists == null) return null;
    for (final l in lists) {
      if (l.id == widget.listId) return l;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    LibraryStore.load().then((lists) {
      if (mounted) setState(() => _lists = lists);
    });
  }

  Future<void> _update(MediaList updated) async {
    final lists = List<MediaList>.of(_lists ?? []);
    final i = lists.indexWhere((l) => l.id == updated.id);
    if (i < 0) return;
    lists[i] = updated;
    await LibraryStore.save(lists);
    if (mounted) setState(() => _lists = lists);
  }

  Future<void> _rename() async {
    final list = _list;
    if (list == null) return;
    final title = await promptForText(
      context,
      title: 'Rename list',
      hint: 'List title',
      initial: list.title,
    );
    if (title == null || title.trim().isEmpty) return;
    await _update(list.copyWith(title: title.trim()));
  }

  Future<void> _deleteList() async {
    final list = _list;
    if (list == null) return;
    final t = WiTokens.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: t.ink2,
        title: Text('Delete "${list.title}"?',
            style: TextStyle(color: t.bone, fontSize: 16)),
        content: Text(
          'The list and its ${list.entries.length} entries will be removed. '
          'Content on Autonomi is unaffected.',
          style: TextStyle(color: t.boneDim, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel', style: TextStyle(color: t.ash)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Delete', style: TextStyle(color: t.rust)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final lists = List<MediaList>.of(_lists ?? [])
      ..removeWhere((l) => l.id == list.id);
    await LibraryStore.save(lists);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _removeEntry(int index) async {
    final list = _list;
    if (list == null) return;
    final entries = List<MediaEntry>.of(list.entries)..removeAt(index);
    await _update(list.copyWith(entries: entries));
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final list = _list;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Text(list?.title ?? '',
            style: TextStyle(color: t.bone, fontSize: 18)),
        actions: [
          IconButton(
            tooltip: 'Rename list',
            icon: Icon(Icons.edit_outlined, color: t.boneDim),
            onPressed: _rename,
          ),
          IconButton(
            tooltip: 'Delete list',
            icon: Icon(Icons.delete_outline, color: t.rust),
            onPressed: _deleteList,
          ),
        ],
      ),
      body: list == null
          ? const Center(child: CircularProgressIndicator())
          : list.entries.isEmpty
              ? Center(
                  child: Text(
                    'No entries yet.\nUse "Add to library" on the Media '
                    'page\nand pick this list.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: t.ash),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: list.entries.length,
                  separatorBuilder: (_, _) =>
                      Divider(height: 1, color: t.line),
                  itemBuilder: (context, i) {
                    final e = list.entries[i];
                    return ListTile(
                      title: Text(e.name,
                          style: TextStyle(color: t.bone, fontSize: 14)),
                      trailing: IconButton(
                        tooltip: 'Remove entry',
                        icon: Icon(Icons.close, size: 18, color: t.ash),
                        onPressed: () => _removeEntry(i),
                      ),
                    );
                  },
                ),
    );
  }
}

