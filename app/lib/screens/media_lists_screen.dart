import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart' show SharePlus, ShareParams;

import '../models/media_list.dart';
import '../services/bundle.dart';
import '../services/datamap_prefetch.dart';
import '../services/library_store.dart';
import '../services/list_import.dart';
import '../services/metadata_service.dart';
import '../services/prefetch_manager.dart';
import '../theme/tokens.dart';
import '../widgets/prefetch_dialog.dart';
import 'list_edit_screen.dart';
import 'settings_screen.dart' show promptForText;

/// Manage media lists: create, show/hide on the home screen, open for
/// editing, rename, delete.
class MediaListsScreen extends StatefulWidget {
  const MediaListsScreen({super.key, this.prefetchBase});

  /// Embedded-server URL override for the post-import data-map prefetch
  /// (tests); null means the real embedded client.
  final String? prefetchBase;

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
              Icon(Icons.folder_open, color: t.accent, size: 20),
              const SizedBox(width: 12),
              Text('Local file',
                  style: TextStyle(color: t.bone, fontSize: 14)),
            ]),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('network'),
            child: Row(children: [
              Icon(Icons.cloud_download_outlined, color: t.accent, size: 20),
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
      if (await file.length() > kMaxBundleBytes) {
        _showError('"${file.name}" is too large to be a media list or '
            'bundle.');
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
    Uint8List? bytes;
    try {
      bytes = await fetchBytesFromNetwork(address,
          base: widget.prefetchBase, maxBytes: kMaxBundleBytes);
    } on ListImportException catch (e) {
      _showError(e.message);
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
    if (bytes != null) await _finishImportBytes(bytes, 'downloaded file');
  }

  /// One Import path, no format question: zip magic → bundle, otherwise
  /// plain text (the `.watch-list` extension is cosmetic).
  Future<void> _finishImportBytes(Uint8List bytes, String name) async {
    if (looksLikeZip(bytes)) {
      final ParsedBundle bundle;
      try {
        bundle = parseBundle(bytes);
      } on ListImportException catch (e) {
        _showError(e.message);
        return;
      }
      var importRootMaps = true;
      var importHistory = true;
      if (bundle.rootMaps.isNotEmpty || bundle.history.isNotEmpty) {
        if (!mounted) return;
        final choice = await _promptBundleImportOptions(bundle);
        if (choice == null) return; // whole import cancelled
        importRootMaps = choice.rootMaps;
        importHistory = choice.history;
      }
      await _finishImport(bundle.listText,
          bundle: bundle,
          importRootMaps: importRootMaps,
          importHistory: importHistory);
      return;
    }
    if (bytes.length > kMaxListFileBytes) {
      _showError('"$name" is too large to be a media list.');
      return;
    }
    final String content;
    try {
      content = utf8.decode(bytes);
    } on FormatException {
      _showError('Could not read "$name" as a text file.');
      return;
    }
    await _finishImport(content);
  }

  /// A bundle can carry the exporter's watch history and resolved data
  /// maps. History is someone else's viewing state and maps prime the
  /// local store, so neither is applied silently — this dialog asks
  /// which to take, showing a row only for what the bundle actually
  /// contains. Returns null when the user cancels the whole import.
  Future<({bool rootMaps, bool history})?> _promptBundleImportOptions(
      ParsedBundle bundle) async {
    final t = WiTokens.of(context);
    // Default ON: the exporter included them deliberately, and this
    // dialog is the explicit chance to opt out.
    var rootMaps = true;
    var history = true;
    final maps = bundle.rootMaps.length;
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
              if (bundle.rootMaps.isNotEmpty)
                CheckboxListTile(
                  value: rootMaps,
                  activeColor: t.accent,
                  checkColor: t.ink,
                  controlAffinity: ListTileControlAffinity.leading,
                  onChanged: (v) =>
                      setDialogState(() => rootMaps = v ?? true),
                  title: Text(
                      'Data maps ($maps ${maps == 1 ? 'title' : 'titles'})',
                      style: TextStyle(color: t.bone, fontSize: 14)),
                  subtitle: Text(
                      'Instant first play — skipping just means a one-time '
                      'network resolve when a title first plays',
                      style: TextStyle(color: t.ash, fontSize: 11.5)),
                ),
              if (bundle.history.isNotEmpty)
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
    return (rootMaps: rootMaps, history: history);
  }

  Future<void> _finishImport(String content,
      {ParsedBundle? bundle,
      bool importRootMaps = true,
      bool importHistory = true}) async {
    final ParsedMediaListFile parsed;
    try {
      parsed = parseMediaListFile(content);
    } on ListImportException catch (e) {
      _showError(e.message);
      return;
    }
    var lists = List<MediaList>.of(_lists ?? []);
    var idBase = DateTime.now().microsecondsSinceEpoch;
    final importedTitles = <String>[];
    final importedEntries = <MediaEntry>[];
    final createdIds = <String>{};
    var merged = 0, added = 0, duplicates = 0, listsSkipped = 0;
    for (final list in parsed.lists) {
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
        importedEntries.addAll(list.entries);
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
        importedEntries.addAll(fresh);
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
        importedEntries.addAll(list.entries);
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
      if (parsed.skippedLines.isNotEmpty)
        '${parsed.skippedLines.length} invalid '
            '${parsed.skippedLines.length == 1 ? 'line' : 'lines'} skipped',
    ].join(', ');
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('$what — $added '
          '${added == 1 ? 'entry' : 'entries'}'
          '${notes.isEmpty ? '' : ' ($notes)'}'),
    ));
    if (bundle == null) {
      await _offerPrefetch(importedEntries);
      return;
    }
    // Seed the caches from the bundle's optional members. Existing local
    // state wins throughout; tampered root maps are rejected by the
    // embedded client's offline verification and resolve over the
    // network later instead.
    if (bundle.hasSeedableExtras) {
      final seeded = await seedBundle(bundle,
          base: widget.prefetchBase,
          importRootMaps: importRootMaps,
          importHistory: importHistory);
      final parts = [
        if (seeded.metadataSeeded > 0)
          '${seeded.metadataSeeded} metadata '
              '${seeded.metadataSeeded == 1 ? 'entry' : 'entries'}',
        if (seeded.postersSeeded > 0)
          '${seeded.postersSeeded} '
              '${seeded.postersSeeded == 1 ? 'poster' : 'posters'}',
        if (seeded.mapsStored > 0)
          '${seeded.mapsStored} instant-play '
              '${seeded.mapsStored == 1 ? 'map' : 'maps'}',
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
    // Only offer the data-map prefetch for entries the bundle did not
    // already cover (declined maps were never stored, so nothing is
    // covered then).
    final covered =
        importRootMaps ? bundle.rootMaps.keys.toSet() : <String>{};
    await _offerPrefetch([
      for (final e in importedEntries)
        if (!covered
            .contains(e.address.toLowerCase().replaceFirst('0x', '')))
          e,
    ]);
  }

  /// Offer to resolve the data maps of the just-imported entries so their
  /// first play starts fast. Declining costs nothing lasting: the embedded
  /// client saves each map the first time a title plays anyway.
  Future<void> _offerPrefetch(List<MediaEntry> entries) async {
    if (entries.isEmpty || !mounted) return;
    final prefetcher = DataMapPrefetcher(base: widget.prefetchBase);
    if (!prefetcher.available) return;
    final t = WiTokens.of(context);
    final n = entries.length;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: t.ink2,
        title: Text('Prefetch data maps?',
            style: TextStyle(color: t.bone, fontSize: 16)),
        content: Text(
          'Download the small data-map index for each of the $n imported '
          '${n == 1 ? 'file' : 'files'} now, so playback starts faster the '
          'first time you play them. If you skip this, each map is saved '
          'automatically the first time a title plays.',
          style: TextStyle(color: t.boneDim, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Skip', style: TextStyle(color: t.ash)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Prefetch', style: TextStyle(color: t.accent)),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    await startPrefetchWithProgress(context, entries,
        base: widget.prefetchBase);
  }

  /// App-bar action: prefetch the data maps of every entry in every list.
  /// Maps already stored resolve from disk in milliseconds, so this both
  /// resumes a cancelled prefetch and picks up files added since — only
  /// the missing maps cost network time. Reopens the progress dialog when
  /// a run is already going.
  Future<void> _prefetchAll() async {
    if (PrefetchManager.instance.running) {
      await watchPrefetch(context);
      return;
    }
    final entries = [
      for (final list in _lists ?? <MediaList>[]) ...list.entries,
    ];
    if (entries.isEmpty) {
      _showError('No entries to prefetch — your lists are empty.');
      return;
    }
    final prefetcher = DataMapPrefetcher(base: widget.prefetchBase);
    if (!prefetcher.available) {
      _showError('The built-in Autonomi client is not available.');
      return;
    }
    if (!mounted) return;
    final t = WiTokens.of(context);
    final n = entries.length;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: t.ink2,
        title: Text('Prefetch data maps?',
            style: TextStyle(color: t.bone, fontSize: 16)),
        content: Text(
          'Download the small data-map index for each of the $n '
          '${n == 1 ? 'file' : 'files'} in your lists, so first plays '
          'start faster. Files already prefetched are skipped almost '
          'instantly — running this again resumes a cancelled prefetch.',
          style: TextStyle(color: t.boneDim, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel', style: TextStyle(color: t.ash)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Prefetch', style: TextStyle(color: t.accent)),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    await startPrefetchWithProgress(context, entries,
        base: widget.prefetchBase);
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
    await _exportFlow(withEntries, library: true, baseName: 'watch-it library');
  }

  /// Two-step export dialog (docs/BUNDLE-FORMAT.md): plain `.txt` vs full
  /// `.watch-list` bundle, then the bundle's include options.
  Future<void> _exportFlow(
    List<MediaList> lists, {
    required bool library,
    required String baseName,
  }) async {
    final t = WiTokens.of(context);
    final format = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        backgroundColor: t.ink2,
        title: Text(library ? 'Export library' : 'Export list',
            style: TextStyle(color: t.bone, fontSize: 16)),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('txt'),
            child: Row(children: [
              Icon(Icons.description_outlined, color: t.accent, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text('List only (.txt)\nJust the addresses and file '
                    'names — small and universal',
                    style: TextStyle(color: t.bone, fontSize: 14)),
              ),
            ]),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('bundle'),
            child: Row(children: [
              Icon(Icons.inventory_2_outlined, color: t.accent, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text('Full bundle (.watch-list)\nAdds artwork, '
                    'descriptions and instant-play data for the receiver',
                    style: TextStyle(color: t.bone, fontSize: 14)),
              ),
            ]),
          ),
        ],
      ),
    );
    if (format == null || !mounted) return;
    var safe = baseName.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_').trim();
    if (safe.isEmpty) safe = 'media-list';
    if (format == 'txt') {
      final text = lists.map(serializeMediaList).join();
      await _deliverExport(
        utf8.encode(text),
        fileName: '$safe.txt',
        mimeType: 'text/plain',
        typeLabel: 'Text',
        extension: 'txt',
        entryCount: lists.fold(0, (n, l) => n + l.entries.length),
        shareOnMobile: true,
      );
      return;
    }

    // Step 2 — bundle include options.
    var includeHistory = false; // shared lists shouldn't leak viewing habits
    var includeRootMaps = true; // addresses are public in list.txt anyway
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: t.ink2,
          title: Text('Bundle contents',
              style: TextStyle(color: t.bone, fontSize: 16)),
          contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CheckboxListTile(
                value: includeRootMaps,
                activeColor: t.accent,
                checkColor: t.ink,
                controlAffinity: ListTileControlAffinity.leading,
                onChanged: (v) =>
                    setDialogState(() => includeRootMaps = v ?? true),
                title: Text('Include root maps',
                    style: TextStyle(color: t.bone, fontSize: 14)),
                subtitle: Text(
                    'Instant playback on import — skips the first-play '
                    'network resolve',
                    style: TextStyle(color: t.ash, fontSize: 11.5)),
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
    if (includeRootMaps) {
      // Entries never browsed/played have no cached metadata or root map
      // (a cold resolve is 20-30s per movie-sized title), so resolve them
      // now behind a cancellable progress pass. Cancel keeps the partial
      // bundle — missing members degrade gracefully on import.
      await _preResolveForExport(entries);
      if (!mounted) return;
    }

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
          includeRootMaps: includeRootMaps,
          includeLibrary: library,
        ),
        base: widget.prefetchBase,
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
      typeLabel: 'watch-it bundle',
      extension: 'watch-list',
      entryCount: entries.length,
      // ~200MB through the share sheet is unreliable; the SAF save
      // dialog handles it, so bundles use it on every platform.
      shareOnMobile: false,
      note: result.rootMapsMissing > 0
          ? '${result.rootMapsMissing} instant-play '
              '${result.rootMapsMissing == 1 ? 'map' : 'maps'} not '
              'included'
          : null,
    );
  }

  /// Resolve the data maps of [entries] before a bundle export, behind a
  /// modal `File X of N` progress dialog with Cancel. Maps already stored
  /// resolve from disk in milliseconds.
  Future<void> _preResolveForExport(List<MediaEntry> entries) async {
    final prefetcher = DataMapPrefetcher(base: widget.prefetchBase);
    if (!prefetcher.available) return;
    final t = WiTokens.of(context);
    final progress = ValueNotifier<(int, int, String)>(
        (0, entries.length, ''));
    var open = true;
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => Dialog(
        backgroundColor: t.ink2,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: t.accent),
              const SizedBox(height: 18),
              ValueListenableBuilder(
                valueListenable: progress,
                builder: (context, (int, int, String) p, _) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Preparing bundle — file ${p.$1} of ${p.$2}',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: t.bone,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      p.$3,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: t.ash),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: prefetcher.cancel,
                    child: Text('Cancel', style: TextStyle(color: t.ash)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ).then((_) => open = false));
    await prefetcher.run(entries,
        onProgress: (current, total, name) =>
            progress.value = (current, total, name));
    if (open && mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
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
            tooltip: 'Prefetch data maps',
            icon: Icon(Icons.downloading_outlined, color: t.bone),
            onPressed: _prefetchAll,
          ),
          IconButton(
            tooltip: 'Import list from file',
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
