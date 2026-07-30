import 'package:flutter/material.dart';

import '../models/media_list.dart';
import '../services/library_store.dart';
import '../theme/tokens.dart';
import 'settings_screen.dart' show promptForText;

/// Edit one media list: rename, delete, add/remove entries
/// (file name + XOR address).
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

  Future<void> _addEntry() async {
    final list = _list;
    if (list == null) return;
    final entry = await _promptForEntry(context);
    if (entry == null) return;
    await _update(list.copyWith(entries: [...list.entries, entry]));
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addEntry,
        backgroundColor: t.accent,
        foregroundColor: t.ink,
        icon: const Icon(Icons.add),
        label: const Text('Add entry'),
      ),
      body: list == null
          ? const Center(child: CircularProgressIndicator())
          : list.entries.isEmpty
              ? Center(
                  child: Text(
                    'No entries yet.\nAdd a file name and its XOR address.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: t.ash),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: list.entries.length,
                  separatorBuilder: (_, _) =>
                      Divider(height: 1, color: t.line),
                  itemBuilder: (context, i) {
                    final e = list.entries[i];
                    return ListTile(
                      title: Text(e.name,
                          style: TextStyle(color: t.bone, fontSize: 14)),
                      subtitle: Text(
                        e.address,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: wiMonoFamily,
                          fontFamilyFallback: wiMonoFallback,
                          fontSize: 11,
                          color: t.ash,
                        ),
                      ),
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

Future<MediaEntry?> _promptForEntry(BuildContext context) {
  final nameController = TextEditingController();
  final addressController = TextEditingController();
  return showDialog<MediaEntry>(
    context: context,
    builder: (context) {
      final t = WiTokens.of(context);
      return StatefulBuilder(
        builder: (context, setState) {
          final address = addressController.text.trim();
          final addressOk = address.isEmpty || looksLikeXorAddress(address);
          return AlertDialog(
            backgroundColor: t.ink2,
            title: Text('Add entry',
                style: TextStyle(color: t.bone, fontSize: 16)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  autofocus: true,
                  style: TextStyle(color: t.bone),
                  decoration: InputDecoration(
                    labelText: 'File name',
                    labelStyle: TextStyle(color: t.ash),
                    hintText: 'The Movie (2024) {imdb-tt1234567} - [1080p].mkv',
                    hintStyle: TextStyle(color: t.ash),
                  ),
                ),
                TextField(
                  controller: addressController,
                  onChanged: (_) => setState(() {}),
                  style: TextStyle(
                    color: t.bone,
                    fontFamily: wiMonoFamily,
                    fontFamilyFallback: wiMonoFallback,
                    fontSize: 13,
                  ),
                  decoration: InputDecoration(
                    labelText: 'XOR address',
                    labelStyle: TextStyle(color: t.ash),
                    errorText:
                        addressOk ? null : 'Expected 64 hex characters',
                    errorStyle: TextStyle(color: t.rust),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text('Cancel', style: TextStyle(color: t.ash)),
              ),
              TextButton(
                onPressed: () {
                  final name = nameController.text.trim();
                  final addr = addressController.text.trim();
                  if (name.isEmpty || !looksLikeXorAddress(addr)) return;
                  Navigator.of(context)
                      .pop(MediaEntry(name: name, address: addr));
                },
                child: Text('Add', style: TextStyle(color: t.accent)),
              ),
            ],
          );
        },
      );
    },
  );
}
