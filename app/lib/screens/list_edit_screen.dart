import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../models/media_list.dart';
import '../services/datamap_import.dart';
import '../services/library_store.dart';
import '../services/list_import.dart' show ListImportException;
import '../theme/tokens.dart';
import 'settings_screen.dart' show promptForText;

/// Edit one media list: rename, delete, remove entries, add entries from
/// `.datamap` files (the output of a private `ant file upload`).
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

  /// Multi-select `.datamap` picker; each file becomes one entry (its
  /// address derived offline by the embedded client). Duplicates of
  /// addresses already in the list are skipped.
  Future<void> _addEntry() async {
    final list = _list;
    if (list == null) return;
    final List<XFile> files;
    try {
      files = await openFiles(acceptedTypeGroups: [
        const XTypeGroup(label: 'Data maps', extensions: ['datamap']),
      ]);
    } catch (e) {
      _showSnack('Could not open the file picker: $e');
      return;
    }
    if (files.isEmpty) return;
    final entries = <MediaEntry>[];
    var failed = 0;
    for (final file in files) {
      try {
        entries.add(
            await entryFromDatamapFile(file.name, await file.readAsBytes()));
      } on ListImportException {
        failed++;
      } catch (_) {
        failed++;
      }
    }
    final have = list.entries.map((e) => e.address).toSet();
    final fresh = entries.where((e) => have.add(e.address)).toList();
    final duplicates = entries.length - fresh.length;
    if (fresh.isNotEmpty) {
      await _update(list.copyWith(entries: [...list.entries, ...fresh]));
    }
    final notes = [
      if (fresh.isNotEmpty)
        'Added ${fresh.length} ${fresh.length == 1 ? 'entry' : 'entries'}',
      if (duplicates > 0) '$duplicates already in the list',
      if (failed > 0)
        '$failed ${failed == 1 ? 'file' : 'files'} not readable as a '
            'data map',
    ];
    if (notes.isNotEmpty) _showSnack(notes.join(' · '));
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
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
        label: const Text('Add .datamap files'),
      ),
      body: list == null
          ? const Center(child: CircularProgressIndicator())
          : list.entries.isEmpty
              ? Center(
                  child: Text(
                    'No entries yet.\nAdd the .datamap files a private '
                    '"ant file upload" produced.',
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

