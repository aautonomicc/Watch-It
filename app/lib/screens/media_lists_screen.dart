import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../models/media_list.dart';
import '../services/library_store.dart';
import '../services/list_import.dart';
import '../theme/tokens.dart';
import 'list_edit_screen.dart';
import 'settings_screen.dart' show promptForText;

/// Manage media lists: create, show/hide on the home screen, open for
/// editing, rename, delete.
class MediaListsScreen extends StatefulWidget {
  const MediaListsScreen({super.key});

  @override
  State<MediaListsScreen> createState() => _MediaListsScreenState();
}

class _MediaListsScreenState extends State<MediaListsScreen> {
  List<MediaList>? _lists;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final lists = await LibraryStore.load();
    if (mounted) setState(() => _lists = lists);
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

  /// Import lists from a text file: either a single list (first line is
  /// the list name) or several lists separated by `ListName="..."`
  /// markers; every other line is one `<xor address> <file name>` entry.
  Future<void> _importList() async {
    final t = WiTokens.of(context);
    final source = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        backgroundColor: t.ink2,
        title: Text('Import list from file',
            style: TextStyle(color: t.bone, fontSize: 16)),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('local'),
            child: Row(children: [
              Icon(Icons.folder_open, color: t.copper, size: 20),
              const SizedBox(width: 12),
              Text('Local file',
                  style: TextStyle(color: t.bone, fontSize: 14)),
            ]),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('network'),
            child: Row(children: [
              Icon(Icons.cloud_download_outlined, color: t.copper, size: 20),
              const SizedBox(width: 12),
              Text('Download from network (XOR address)',
                  style: TextStyle(color: t.bone, fontSize: 14)),
            ]),
          ),
        ],
      ),
    );
    if (source == 'local') {
      await _importFromLocalFile();
    } else if (source == 'network') {
      await _importFromNetwork();
    }
  }

  Future<void> _importFromLocalFile() async {
    final XFile? file;
    try {
      file = await openFile();
    } catch (e) {
      _showError('Could not open the file picker: $e');
      return;
    }
    if (file == null) return;
    try {
      if (await file.length() > kMaxListFileBytes) {
        _showError('"${file.name}" is too large to be a media list.');
        return;
      }
    } catch (_) {
      // Some pickers cannot report a size up front; readAsString below
      // is the real gate then.
    }
    final String content;
    try {
      content = await file.readAsString();
    } catch (_) {
      _showError('Could not read "${file.name}" as a text file.');
      return;
    }
    await _finishImport(content);
  }

  Future<void> _importFromNetwork() async {
    final address = await promptForText(
      context,
      title: 'Download list',
      hint: 'XOR address of the list file',
    );
    if (address == null || address.trim().isEmpty) return;
    if (!mounted) return;
    // Barrier while the file downloads; popped in the finally below.
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    ));
    String? content;
    try {
      content = await fetchListFromNetwork(address);
    } on ListImportException catch (e) {
      _showError(e.message);
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
    if (content != null) await _finishImport(content);
  }

  Future<void> _finishImport(String content) async {
    final ParsedMediaListFile parsed;
    try {
      parsed = parseMediaListFile(content);
    } on ListImportException catch (e) {
      _showError(e.message);
      return;
    }
    final lists = List<MediaList>.of(_lists ?? []);
    var idBase = DateTime.now().microsecondsSinceEpoch;
    final importedTitles = <String>[];
    var merged = 0, added = 0, duplicates = 0, listsSkipped = 0;
    for (final list in parsed.lists) {
      final i = lists.indexWhere(
          (l) => l.title.toLowerCase() == list.title.toLowerCase());
      if (i < 0) {
        lists.add(MediaList(
          id: '${idBase++}',
          title: list.title,
          entries: list.entries,
        ));
        importedTitles.add(list.title);
        added += list.entries.length;
        continue;
      }
      if (!mounted) return;
      final action = await _resolveNameClash(list.title);
      if (action == 'merge') {
        final existing = lists[i];
        final have = existing.entries.map((e) => e.address).toSet();
        final fresh =
            list.entries.where((e) => have.add(e.address)).toList();
        duplicates += list.entries.length - fresh.length;
        lists[i] = existing
            .copyWith(entries: [...existing.entries, ...fresh]);
        added += fresh.length;
        merged++;
      } else if (action == 'new') {
        final title = _uniqueTitle(list.title, lists);
        lists.add(MediaList(
          id: '${idBase++}',
          title: title,
          entries: list.entries,
        ));
        importedTitles.add(title);
        added += list.entries.length;
      } else {
        listsSkipped++;
      }
    }
    if (importedTitles.isEmpty && merged == 0) {
      _showError('Nothing imported.');
      return;
    }
    await LibraryStore.save(lists);
    if (!mounted) return;
    setState(() => _lists = lists);
    var what = importedTitles.length == 1 && merged == 0
        ? 'Imported "${importedTitles.single}"'
        : [
            if (importedTitles.isNotEmpty)
              'Imported ${importedTitles.length} '
                  '${importedTitles.length == 1 ? 'list' : 'lists'}',
            if (merged > 0)
              'merged into $merged existing '
                  '${merged == 1 ? 'list' : 'lists'}',
          ].join(', ');
    what = what[0].toUpperCase() + what.substring(1);
    final notes = [
      if (duplicates > 0)
        '$duplicates duplicate ${duplicates == 1 ? 'entry' : 'entries'} '
            'skipped',
      if (listsSkipped > 0)
        '$listsSkipped ${listsSkipped == 1 ? 'list' : 'lists'} skipped',
      if (parsed.skippedLines.isNotEmpty)
        '${parsed.skippedLines.length} invalid '
            '${parsed.skippedLines.length == 1 ? 'line' : 'lines'} skipped',
    ].join(', ');
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('$what — $added '
          '${added == 1 ? 'entry' : 'entries'}'
          '${notes.isEmpty ? '' : ' ($notes)'}'),
    ));
  }

  /// Ask what to do with an imported list whose name already exists:
  /// returns 'merge', 'new', or null to skip it.
  Future<String?> _resolveNameClash(String title) {
    final t = WiTokens.of(context);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: t.ink2,
        title: Text('"$title" already exists',
            style: TextStyle(color: t.bone, fontSize: 16)),
        content: Text(
          'Merge the imported entries into the existing list (duplicates '
          'are skipped), or create a new list with a numbered name?',
          style: TextStyle(color: t.boneDim, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(null),
            child: Text('Skip', style: TextStyle(color: t.ash)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('new'),
            child: Text('Create new', style: TextStyle(color: t.bone)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('merge'),
            child: Text('Merge', style: TextStyle(color: t.copper)),
          ),
        ],
      ),
    );
  }

  /// First of `title (2)`, `title (3)`, … not already taken in [lists].
  String _uniqueTitle(String title, List<MediaList> lists) {
    final taken = lists.map((l) => l.title.toLowerCase()).toSet();
    for (var n = 2;; n++) {
      final candidate = '$title ($n)';
      if (!taken.contains(candidate.toLowerCase())) return candidate;
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _setEnabled(MediaList list, bool enabled) async {
    final lists = List<MediaList>.of(_lists ?? []);
    final i = lists.indexWhere((l) => l.id == list.id);
    if (i < 0) return;
    lists[i] = list.copyWith(enabled: enabled);
    await LibraryStore.save(lists);
    if (mounted) setState(() => _lists = lists);
  }

  Future<void> _rename(MediaList list) async {
    final title = await promptForText(
      context,
      title: 'Rename list',
      hint: 'List title',
      initial: list.title,
    );
    if (title == null || title.trim().isEmpty) return;
    final lists = List<MediaList>.of(_lists ?? []);
    final i = lists.indexWhere((l) => l.id == list.id);
    if (i < 0) return;
    lists[i] = list.copyWith(title: title.trim());
    await LibraryStore.save(lists);
    if (mounted) setState(() => _lists = lists);
  }

  Future<void> _delete(MediaList list) async {
    final t = WiTokens.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: t.ink2,
        title: Text('Delete "${list.title}"?',
            style: TextStyle(color: t.bone, fontSize: 16)),
        content: Text(
          'The list and its ${list.entries.length} '
          '${list.entries.length == 1 ? 'entry' : 'entries'} will be '
          'removed. Content on Autonomi is unaffected.',
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
        title:
            Text('Media Lists', style: TextStyle(color: t.bone, fontSize: 18)),
        actions: [
          IconButton(
            tooltip: 'Import list from file',
            icon: Icon(Icons.download_outlined, color: t.bone),
            onPressed: _importList,
          ),
        ],
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
              padding: const EdgeInsets.only(bottom: 88),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    'Checked lists appear in your home library. Tap a list '
                    'to edit its entries.',
                    style: TextStyle(fontSize: 11.5, color: t.ash),
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
                    leading: Checkbox(
                      value: list.enabled,
                      activeColor: t.copper,
                      checkColor: t.ink,
                      side: BorderSide(color: t.ash),
                      onChanged: (v) => _setEnabled(list, v ?? true),
                    ),
                    title: Text(
                      list.title,
                      style: TextStyle(
                        color: list.enabled ? t.bone : t.ash,
                        fontSize: 15,
                      ),
                    ),
                    subtitle: Text(
                      '${list.entries.length} '
                      '${list.entries.length == 1 ? 'entry' : 'entries'}'
                      '${list.enabled ? '' : '  ·  hidden from home'}',
                      style: TextStyle(color: t.ash, fontSize: 12),
                    ),
                    trailing: PopupMenuButton<String>(
                      tooltip: 'List options',
                      icon: Icon(Icons.more_vert, color: t.ash),
                      color: t.ink2,
                      onSelected: (v) => switch (v) {
                        'rename' => _rename(list),
                        'delete' => _delete(list),
                        _ => null,
                      },
                      itemBuilder: (context) => [
                        PopupMenuItem(
                          value: 'rename',
                          child: Text('Rename',
                              style: TextStyle(color: t.bone, fontSize: 14)),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: Text('Delete',
                              style: TextStyle(color: t.rust, fontSize: 14)),
                        ),
                      ],
                    ),
                    onTap: () => _openList(list),
                  ),
              ],
            ),
    );
  }
}
