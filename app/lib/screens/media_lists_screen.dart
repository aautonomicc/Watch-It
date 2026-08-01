import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart' show SharePlus, ShareParams;

import '../models/media_list.dart';
import '../services/bundle.dart';
import '../services/datamap_import.dart';
import '../services/library_store.dart';
import '../services/list_import.dart';
import '../services/metadata_service.dart';
import '../theme/tokens.dart';
import 'list_edit_screen.dart';
import 'settings_screen.dart' show promptForText;

/// Manage media lists: create, show/hide on the home screen, open for
/// editing, rename, delete.
class MediaListsScreen extends StatefulWidget {
  const MediaListsScreen({super.key, this.importBase});

  /// Embedded-server URL override for datamap/bundle imports (tests);
  /// null means the real embedded client.
  final String? importBase;

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

  /// Add media to the library: loose `.datamap` files (a private
  /// `ant file upload` writes one per file) or a `.watch-list` bundle,
  /// local or downloaded from the network by address.
  Future<void> _importList() async {
    final t = WiTokens.of(context);
    final source = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        backgroundColor: t.ink2,
        title: Text('Add to library',
            style: TextStyle(color: t.bone, fontSize: 16)),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('datamaps'),
            child: Row(children: [
              Icon(Icons.note_add_outlined, color: t.accent, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                    'Add .datamap files\nFrom a private "ant file upload"',
                    style: TextStyle(color: t.bone, fontSize: 14)),
              ),
            ]),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('local'),
            child: Row(children: [
              Icon(Icons.folder_open, color: t.accent, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text('Import .watch-list bundle\nLists with artwork '
                    'and instant-play data',
                    style: TextStyle(color: t.bone, fontSize: 14)),
              ),
            ]),
          ),
        ],
      ),
    );
    switch (source) {
      case 'datamaps':
        await _importDatamapFiles();
      case 'local':
        await _importFromLocalFile();
    }
  }

  /// Multi-select `.datamap` picker → one entry per file, added to a
  /// list the user names (existing titles merge via the clash dialog).
  Future<void> _importDatamapFiles() async {
    final List<XFile> files;
    try {
      files = await openFiles(acceptedTypeGroups: [
        const XTypeGroup(label: 'Data maps', extensions: ['datamap']),
      ]);
    } catch (e) {
      _showError('Could not open the file picker: $e');
      return;
    }
    if (files.isEmpty || !mounted) return;
    final title = await promptForText(
      context,
      title: 'Add to which list?',
      hint: 'List title',
      initial: 'Imported',
    );
    if (title == null || title.trim().isEmpty) return;
    final named = <({String name, Uint8List bytes})>[];
    for (final file in files) {
      try {
        named.add((name: file.name, bytes: await file.readAsBytes()));
      } catch (_) {
        _showError('Could not read "${file.name}".');
      }
    }
    await _importDatamaps(named, listTitle: title.trim());
  }

  /// Import [files] as datamap entries into [listTitle]. Each file's
  /// address is derived offline by the embedded client; unreadable files
  /// are skipped and reported.
  Future<void> _importDatamaps(
    List<({String name, Uint8List bytes})> files, {
    required String listTitle,
  }) async {
    final entries = <MediaEntry>[];
    var failed = 0;
    for (final file in files) {
      try {
        entries.add(await entryFromDatamapFile(file.name, file.bytes,
            base: widget.importBase));
      } on ListImportException {
        failed++;
      }
    }
    if (entries.isEmpty) {
      _showError('No data maps could be imported'
          '${failed > 0 ? ' ($failed unreadable)' : ''}.');
      return;
    }
    await _applyImportedLists(
      [ParsedMediaList(title: listTitle, entries: entries)],
      extraNotes: [
        if (failed > 0)
          '$failed ${failed == 1 ? 'file' : 'files'} skipped (not a '
              'data map)',
      ],
    );
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
      if (await file.length() > kMaxBundleBytes) {
        _showError('"${file.name}" is too large to be a bundle.');
        return;
      }
    } catch (_) {
      // Some pickers cannot report a size up front; readAsBytes below
      // is the real gate then.
    }
    final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (_) {
      _showError('Could not read "${file.name}".');
      return;
    }
    await _finishImportBytes(bytes, file.name);
  }

  /// Route picked/downloaded bytes: zip magic → bundle; a loose
  /// `.datamap` file still imports (the picker filter is advisory);
  /// anything else — including the removed plain-text list format — is
  /// refused with a pointer at bundles.
  Future<void> _finishImportBytes(Uint8List bytes, String? name) async {
    if (looksLikeZip(bytes)) {
      await _importBundle(bytes, fileName: name);
      return;
    }
    if (name != null && mediaNameFromDatamapFileName(name) != null) {
      if (!mounted) return;
      final title = await promptForText(
        context,
        title: 'Add to which list?',
        hint: 'List title',
        initial: 'Imported',
      );
      if (title == null || title.trim().isEmpty) return;
      await _importDatamaps([(name: name, bytes: bytes)],
          listTitle: title.trim());
      return;
    }
    _showError('${name == null ? 'That file' : '"$name"'} is not a '
        '.watch-list bundle or .datamap file. Plain-text lists are no '
        'longer supported — ask for a bundle instead.');
  }

  /// Full bundle import: parse, ask about history, then convert every
  /// member and line into datamap-backed entries (a v1 bundle's legacy
  /// entries fetch their maps here, behind a progress dialog) and merge
  /// the resulting lists into the library.
  Future<void> _importBundle(Uint8List bytes, {String? fileName}) async {
    final ParsedBundle bundle;
    try {
      bundle = parseBundle(bytes);
    } on ListImportException catch (e) {
      _showError(e.message);
      return;
    }

    // Members no list claims land in a default list named after the
    // bundle file (minus its extension, whatever the picker delivered);
    // a network-fetched bundle has no file name — ask.
    var defaultTitle =
        fileName?.replaceFirst(RegExp(r'\.[^.]+$'), '').trim();
    if ((defaultTitle == null || defaultTitle.isEmpty) &&
        bundle.datamapMembers.isNotEmpty) {
      if (!mounted) return;
      defaultTitle = (await promptForText(
        context,
        title: 'List name for this bundle',
        hint: 'List title',
        initial: 'Imported',
      ))
          ?.trim();
      if (defaultTitle == null || defaultTitle.isEmpty) return;
    }

    var importHistory = true;
    if (bundle.history.isNotEmpty) {
      if (!mounted) return;
      final choice = await _promptBundleImportOptions(bundle);
      if (choice == null) return; // whole import cancelled
      importHistory = choice;
    }

    if (!mounted) return;
    final t = WiTokens.of(context);
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => Dialog(
        backgroundColor: t.ink2,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: t.accent),
              const SizedBox(height: 18),
              Text('Importing…',
                  style: TextStyle(fontSize: 13, color: t.boneDim)),
            ],
          ),
        ),
      ),
    ));
    BundleImportResult? result;
    try {
      result = await importBundleEntries(
        bundle,
        base: widget.importBase,
        defaultListTitle: defaultTitle ?? 'Imported',
      );
    } on ListImportException catch (e) {
      _showError(e.message);
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
    if (result == null) return;

    await _applyImportedLists(
      result.lists,
      bundle: bundle,
      importHistory: importHistory,
      extraNotes: [
        if (result.datamapsInvalid > 0)
          '${result.datamapsInvalid} unreadable data '
              '${result.datamapsInvalid == 1 ? 'map' : 'maps'} skipped',
        if (result.refsMissing > 0)
          '${result.refsMissing} listed ${result.refsMissing == 1 ? 'file' : 'files'} '
              'missing from the bundle',
        if (result.skippedLines.isNotEmpty)
          '${result.skippedLines.length} invalid '
              '${result.skippedLines.length == 1 ? 'line' : 'lines'} skipped',
      ],
    );
  }

  /// A bundle can carry the exporter's watch history — someone else's
  /// viewing state, so it is never applied silently. Returns the
  /// checkbox value, or null when the user cancels the whole import.
  Future<bool?> _promptBundleImportOptions(ParsedBundle bundle) async {
    final t = WiTokens.of(context);
    // Default ON: the exporter included it deliberately, and this dialog
    // is the explicit chance to opt out.
    var history = true;
    final entries = bundle.history.length;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: t.ink2,
          title: Text('This bundle also contains',
              style: TextStyle(color: t.bone, fontSize: 16)),
          contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CheckboxListTile(
                value: history,
                activeColor: t.accent,
                checkColor: t.ink,
                controlAffinity: ListTileControlAffinity.leading,
                onChanged: (v) =>
                    setDialogState(() => history = v ?? true),
                title: Text(
                    'Watch history ($entries '
                    '${entries == 1 ? 'entry' : 'entries'})',
                    style: TextStyle(color: t.bone, fontSize: 14)),
                subtitle: Text(
                    "The exporter's resume points and watched marks — "
                    'merged only where newer than yours',
                    style: TextStyle(color: t.ash, fontSize: 11.5)),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('Cancel', style: TextStyle(color: t.ash)),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text('Import', style: TextStyle(color: t.accent)),
            ),
          ],
        ),
      ),
    );
    if (go != true) return null;
    return history;
  }

  /// Merge freshly imported lists into the library (clash dialog per
  /// existing title), save, seed any bundle extras, and report what
  /// happened in one snackbar.
  Future<void> _applyImportedLists(
    List<ParsedMediaList> parsed, {
    ParsedBundle? bundle,
    bool importHistory = true,
    List<String> extraNotes = const [],
  }) async {
    var lists = List<MediaList>.of(_lists ?? []);
    var idBase = DateTime.now().microsecondsSinceEpoch;
    final importedTitles = <String>[];
    final createdIds = <String>{};
    var merged = 0, added = 0, duplicates = 0, listsSkipped = 0;
    for (final list in parsed) {
      final i = lists.indexWhere(
          (l) => l.title.toLowerCase() == list.title.toLowerCase());
      if (i < 0) {
        final id = '${idBase++}';
        lists.add(MediaList(
          id: id,
          title: list.title,
          entries: list.entries,
        ));
        createdIds.add(id);
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
        final id = '${idBase++}';
        lists.add(MediaList(
          id: id,
          title: title,
          entries: list.entries,
        ));
        createdIds.add(id);
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
    if (bundle != null) {
      // library.json applies only to the lists this import created —
      // existing lists are never reordered, hidden, or re-enabled.
      lists = applyLibraryPrefs(lists, createdIds, bundle.libraryPrefs);
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
      ...extraNotes,
    ].join(', ');
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('$what — $added '
          '${added == 1 ? 'entry' : 'entries'}'
          '${notes.isEmpty ? '' : ' ($notes)'}'),
    ));
    if (bundle == null) return;
    // Seed the caches from the bundle's optional members. Existing local
    // state wins throughout.
    if (bundle.hasSeedableExtras) {
      final seeded =
          await seedBundle(bundle, importHistory: importHistory);
      final parts = [
        if (seeded.metadataSeeded > 0)
          '${seeded.metadataSeeded} metadata '
              '${seeded.metadataSeeded == 1 ? 'entry' : 'entries'}',
        if (seeded.postersSeeded > 0)
          '${seeded.postersSeeded} '
              '${seeded.postersSeeded == 1 ? 'poster' : 'posters'}',
        if (seeded.historyMerged > 0)
          '${seeded.historyMerged} watch-history '
              '${seeded.historyMerged == 1 ? 'entry' : 'entries'}',
      ];
      if (parts.isNotEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('From the bundle: ${parts.join(', ')}')));
      }
      MetadataService.instance.notifyExternalSeed();
    }
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
            child: Text('Merge', style: TextStyle(color: t.accent)),
          ),
        ],
      ),
    );
  }

  /// Per-list export: the two-step dialog over just this list.
  Future<void> _export(MediaList list) async {
    if (list.entries.isEmpty) {
      _showError('"${list.title}" is empty — nothing to export.');
      return;
    }
    await _exportFlow([list], library: false, baseName: list.title);
  }

  /// Whole-library export: every list, including hidden ones (it's a
  /// backup), in home-screen order; a bundle adds library.json so a
  /// fresh-device import restores order and visibility too.
  Future<void> _exportLibrary() async {
    final lists = _lists ?? [];
    final withEntries =
        [for (final l in lists) if (l.entries.isNotEmpty) l];
    if (withEntries.isEmpty) {
      _showError('Your library is empty — nothing to export.');
      return;
    }
    await _exportFlow(withEntries, library: true, baseName: 'W@tch library');
  }

  /// Export dialog (docs/BUNDLE-FORMAT.md): a `.watch-list` bundle is
  /// the only format — its `.datamap` members *are* the entries, so
  /// there is no maps checkbox and no plain-text option (a text list
  /// without the maps would be unplayable, and a hex list would recreate
  /// the public-address format this app no longer supports).
  Future<void> _exportFlow(
    List<MediaList> lists, {
    required bool library,
    required String baseName,
  }) async {
    final t = WiTokens.of(context);
    var safe = baseName.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_').trim();
    if (safe.isEmpty) safe = 'media-list';

    var includeHistory = false; // shared lists shouldn't leak viewing habits
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: t.ink2,
          title: Text(library ? 'Export library' : 'Export list',
              style: TextStyle(color: t.bone, fontSize: 16)),
          contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Text(
                  'Exports a .watch-list bundle: the data maps plus '
                  'artwork and descriptions. Anyone with the bundle can '
                  'play its titles — share it as privately as the '
                  'content deserves.',
                  style: TextStyle(color: t.boneDim, fontSize: 12.5),
                ),
              ),
              CheckboxListTile(
                value: includeHistory,
                activeColor: t.accent,
                checkColor: t.ink,
                controlAffinity: ListTileControlAffinity.leading,
                onChanged: (v) =>
                    setDialogState(() => includeHistory = v ?? false),
                title: Text('Include watch history',
                    style: TextStyle(color: t.bone, fontSize: 14)),
                subtitle: Text(
                    'Resume points and watched marks — for migrating to '
                    'a new device, not for sharing',
                    style: TextStyle(color: t.ash, fontSize: 11.5)),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('Cancel', style: TextStyle(color: t.ash)),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text('Export', style: TextStyle(color: t.accent)),
            ),
          ],
        ),
      ),
    );
    if (go != true || !mounted) return;

    final entries = [for (final l in lists) ...l.entries];
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    ));
    BundleBuildResult? result;
    try {
      result = await buildBundle(
        lists,
        BundleExportOptions(
          includeHistory: includeHistory,
          includeLibrary: library,
        ),
        base: widget.importBase,
      );
    } catch (e) {
      _showError('Export failed: $e');
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
    if (result == null || !mounted) return;
    await _deliverExport(
      result.bytes,
      fileName: '$safe.watch-list',
      mimeType: 'application/zip',
      typeLabel: 'W@tch bundle',
      extension: 'watch-list',
      entryCount: entries.length,
      // ~200MB through the share sheet is unreliable; the SAF save
      // dialog handles it, so bundles use it on every platform.
      shareOnMobile: false,
      note: result.entriesMissingMap > 0
          ? '${result.entriesMissingMap} '
              '${result.entriesMissingMap == 1 ? 'entry' : 'entries'} '
              'skipped — data map missing, re-import them first'
          : null,
    );
  }

  /// Hand the exported bytes to the user: the system share sheet on
  /// mobile when [shareOnMobile] (plain text lists), else a save-file
  /// dialog (SAF on mobile — reliable for large bundles).
  Future<void> _deliverExport(
    Uint8List bytes, {
    required String fileName,
    required String mimeType,
    required String typeLabel,
    required String extension,
    required int entryCount,
    required bool shareOnMobile,
    String? note,
  }) async {
    try {
      if (shareOnMobile && (Platform.isAndroid || Platform.isIOS)) {
        await SharePlus.instance.share(ShareParams(
          files: [XFile.fromData(bytes, mimeType: mimeType)],
          fileNameOverrides: [fileName],
        ));
        return;
      }
      final location = await getSaveLocation(
        suggestedName: fileName,
        acceptedTypeGroups: [
          XTypeGroup(label: typeLabel, extensions: [extension]),
        ],
      );
      if (location == null) return; // save dialog cancelled
      await XFile.fromData(bytes, mimeType: mimeType, name: fileName)
          .saveTo(location.path);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Exported $entryCount '
            '${entryCount == 1 ? 'entry' : 'entries'} to '
            '${location.path}${note == null ? '' : ' ($note)'}'),
      ));
    } catch (e) {
      _showError('Export failed: $e');
    }
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
            tooltip: 'Add to library',
            icon: Icon(Icons.download_outlined, color: t.bone),
            onPressed: _importList,
          ),
          IconButton(
            tooltip: 'Export library',
            icon: Icon(Icons.upload_outlined, color: t.bone),
            onPressed: _exportLibrary,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createList,
        backgroundColor: t.accent,
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
                      activeColor: t.accent,
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
                        'export' => _export(list),
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
                          value: 'export',
                          child: Text('Export',
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
