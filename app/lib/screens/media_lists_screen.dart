import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:path_provider/path_provider.dart'
    show getApplicationSupportDirectory;
import 'package:share_plus/share_plus.dart' show SharePlus, ShareParams;

import '../models/media_list.dart';
import '../services/android_saf.dart';
import '../services/app_settings.dart';
import '../services/bundle.dart';
import '../services/connectivity.dart';
import '../services/datamap_import.dart';
import '../services/default_list.dart';
import '../services/channel_service.dart';
import '../services/home_sections.dart';
import '../services/import_review.dart';
import '../services/library_store.dart';
import '../services/list_import.dart';
import '../services/metadata_service.dart';
import '../theme/tokens.dart';
import '../widgets/channel_avatar.dart';
import '../widgets/channel_badge.dart';
import 'import_review_screen.dart';
import 'list_edit_screen.dart';
import 'list_home_screen.dart';
import 'settings_screen.dart' show promptForText;

/// Manage the whole home library in one place: every home row — the
/// user's lists plus the built-in rows (Continue Watching, Favourites,
/// Downloads, Recently Added, shown in a lighter shade because they fill
/// themselves) — in home-screen order, with drag-to-reorder, show/hide
/// checkboxes, and per-list open/rename/export/delete. Lists are created
/// inside the import flow ("Add to library" → "Create new list") — the
/// one place media enters the app.
class MediaListsScreen extends StatefulWidget {
  const MediaListsScreen({super.key, this.importBase, this.importConfigDir});

  /// Embedded-server URL override for datamap/bundle imports (tests);
  /// null means the real embedded client.
  final String? importBase;

  /// Override for the import matcher's config/cache directory (tests,
  /// and platforms without a HOME); null means `~/.watchit-upload` —
  /// the MusicBrainz cache shared with the uploader and the CLI.
  final Directory? importConfigDir;

  @override
  State<MediaListsScreen> createState() => _MediaListsScreenState();
}

class _MediaListsScreenState extends State<MediaListsScreen> {
  List<MediaList>? _lists;

  /// The raw stored home-row order (`home_sections_v1`). The rendered
  /// rows come from reconciling this against the current lists at build
  /// time, so list edits elsewhere in this screen never leave the order
  /// stale.
  List<HomeSection> _stored = const [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final lists = await LibraryStore.load();
    final stored = await AppSettings.homeSections();
    if (mounted) {
      setState(() {
        _lists = lists;
        _stored = stored;
      });
    }
  }

  // onReorderItem delivers newIndex already adjusted for the removal.
  Future<void> _reorder(int oldIndex, int newIndex) async {
    final sections = reconcileHomeSections(_stored, _lists ?? const []);
    sections.insert(newIndex, sections.removeAt(oldIndex));
    setState(() => _stored = sections);
    await AppSettings.setHomeSections(sections);
  }

  /// Built-in rows keep their visibility in the stored section order
  /// itself (list rows use [MediaList.enabled] via [_setEnabled]).
  Future<void> _setSpecialVisible(HomeSection section, bool visible) async {
    final sections = reconcileHomeSections(_stored, _lists ?? const []);
    final i = sections.indexWhere((s) => s.id == section.id);
    if (i < 0) return;
    sections[i] = sections[i].copyWith(visible: visible);
    setState(() => _stored = sections);
    await AppSettings.setHomeSections(sections);
  }

  /// Add media to the library through one multi-select picker — the app
  /// works out what each picked file is instead of asking up front: zip
  /// content is a `.watch-list` bundle (extension never trusted), a
  /// `<name>.watch-list.datamap` file is the map of a bundle stored on
  /// the network (fetched, then imported like a local one), any other
  /// `<media file name>.datamap` file (private `ant file upload` output)
  /// becomes an entry, and anything else is skipped with a note. Mixed
  /// picks work; bundles import one by one, loose datamaps as one batch
  /// into the list(s) the user checks.
  Future<void> _importList() async {
    final List<XFile> files;
    try {
      files = await openFiles(acceptedTypeGroups: [
        const XTypeGroup(
            label: 'Library files', extensions: ['datamap', 'watch-list']),
        const XTypeGroup(label: 'All files'),
      ]);
    } catch (e) {
      _showError('Could not open the file picker: $e');
      return;
    }
    if (files.isEmpty || !mounted) return;

    final bundles = <({String name, Uint8List bytes})>[];
    final netBundles = <({String name, Uint8List bytes})>[];
    final datamaps = <({String name, Uint8List bytes})>[];
    final skipped = <String>[];
    for (final file in files) {
      try {
        if (await file.length() > kMaxBundleBytes) {
          skipped.add(file.name);
          continue;
        }
      } catch (_) {
        // Some pickers cannot report a size up front; the post-read
        // check below is the real gate then.
      }
      final Uint8List bytes;
      try {
        bytes = await file.readAsBytes();
      } catch (_) {
        _showError('Could not read "${file.name}".');
        continue;
      }
      if (bytes.length > kMaxBundleBytes) {
        skipped.add(file.name);
      } else if (looksLikeZip(bytes)) {
        bundles.add((name: file.name, bytes: bytes));
      } else if (isBundleDatamapName(file.name)) {
        netBundles.add((name: file.name, bytes: bytes));
      } else if (mediaNameFromDatamapFileName(file.name) != null) {
        datamaps.add((name: file.name, bytes: bytes));
      } else {
        skipped.add(file.name);
      }
    }

    if (bundles.isEmpty && netBundles.isEmpty && datamaps.isEmpty) {
      if (skipped.isNotEmpty) {
        _showError(skipped.length == 1 && files.length == 1
            ? '"${skipped.single}" is not a .watch-list bundle or '
                '.datamap file. Plain-text lists are no longer supported '
                '— ask for a bundle instead.'
            : 'None of the picked files are .watch-list bundles or '
                '.datamap files.');
      }
      return;
    }

    // Importing can need the network: a real ant upload of a file over
    // ~12 MB writes a shrunk map that expands over the network, and a
    // network-stored bundle always fetches. Warn up front while offline
    // instead of failing file by file — but don't block: local bundles
    // and previously imported maps work fully offline.
    if (netBundles.isNotEmpty || datamaps.isNotEmpty) {
      if (await ConnectivityMonitor.instance.refresh()) {
        if (!mounted) return;
        if (await _confirmOfflineImport() != true) return;
      }
    }

    final totalBundles = bundles.length + netBundles.length;
    var bundleN = 0;
    String? bundleLabel() =>
        totalBundles > 1 ? 'Bundle $bundleN of $totalBundles' : null;
    for (final bundle in bundles) {
      if (!mounted) return;
      bundleN++;
      await _importBundle(bundle.bytes,
          fileName: bundle.name, progressLabel: bundleLabel());
    }
    for (final bundle in netBundles) {
      if (!mounted) return;
      bundleN++;
      await _importNetworkBundle(bundle.name, bundle.bytes,
          progressLabel: bundleLabel());
    }
    final skippedNotes = [
      if (skipped.isNotEmpty)
        '${skipped.length} ${skipped.length == 1 ? 'file' : 'files'} '
            'skipped (not recognised)',
    ];
    if (datamaps.isNotEmpty) {
      if (!mounted) return;
      // Same type-driven default the batch uploader uses: the picker
      // pre-checks Music / TV Shows / Movies from the picked names
      // (media type is in the file name; the .datamap suffix strips).
      final titles = await _pickTargetLists(
          suggested: defaultListForNames([
        for (final d in datamaps)
          mediaNameFromDatamapFileName(d.name) ?? d.name,
      ], fallback: 'Imported'));
      if (titles == null || titles.isEmpty) return;
      await _importDatamaps(datamaps,
          listTitles: titles, extraNotes: skippedNotes);
    } else if (skippedNotes.isNotEmpty) {
      _showError('Done, but ${skippedNotes.single}.');
    }
  }

  /// Checkbox picker over the existing lists — hidden ones included
  /// (hidden ≠ deleted) — plus a "Create new list" button. Returns the
  /// chosen titles, or null on cancel. New titles are only pseudo-rows
  /// here; nothing is saved until the import confirms. An empty library
  /// skips the checklist and goes straight to the new-list prompt.
  /// [suggested] pre-checks that list (added as a pseudo-row when it
  /// doesn't exist yet) — the type-driven Music/TV Shows/Movies
  /// default; unticking it costs one tap.
  Future<List<String>?> _pickTargetLists({String? suggested}) async {
    final existing = _lists ?? [];
    if (existing.isEmpty) {
      final title = await promptForText(
        context,
        title: 'New media list',
        hint: 'List title',
        initial: suggested ?? 'Imported',
      );
      final trimmed = title?.trim();
      if (trimmed == null || trimmed.isEmpty) return null;
      return [trimmed];
    }
    final t = WiTokens.of(context);
    final rows = [
      for (final l in existing) (title: l.title, count: l.entries.length),
    ];
    final checked = <String>{}; // lowercased titles
    if (suggested != null) {
      if (!rows.any(
          (r) => r.title.toLowerCase() == suggested.toLowerCase())) {
        rows.add((title: suggested, count: 0));
      }
      checked.add(suggested.toLowerCase());
    }
    return showDialog<List<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: t.ink2,
          title: Text('Add to which lists?',
              style: TextStyle(color: t.bone, fontSize: 16)),
          contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final row in rows)
                        CheckboxListTile(
                          value:
                              checked.contains(row.title.toLowerCase()),
                          activeColor: t.accent,
                          checkColor: t.ink,
                          controlAffinity:
                              ListTileControlAffinity.leading,
                          onChanged: (v) => setDialogState(() {
                            final key = row.title.toLowerCase();
                            v == true
                                ? checked.add(key)
                                : checked.remove(key);
                          }),
                          title: Text(row.title,
                              style: TextStyle(
                                  color: t.bone, fontSize: 14)),
                          subtitle: Text(
                              '${row.count} '
                              '${row.count == 1 ? 'entry' : 'entries'}',
                              style: TextStyle(
                                  color: t.ash, fontSize: 11.5)),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () async {
                        final title = await promptForText(
                          context,
                          title: 'New media list',
                          hint: 'List title',
                        );
                        final trimmed = title?.trim();
                        if (trimmed == null || trimmed.isEmpty) return;
                        setDialogState(() {
                          // Duplicate of an existing or already-added
                          // row → just check that row.
                          if (!rows.any((r) =>
                              r.title.toLowerCase() ==
                              trimmed.toLowerCase())) {
                            rows.add((title: trimmed, count: 0));
                          }
                          checked.add(trimmed.toLowerCase());
                        });
                      },
                      child: Text('Create new list',
                          style: TextStyle(color: t.bone)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Cancel', style: TextStyle(color: t.ash)),
            ),
            TextButton(
              onPressed: checked.isEmpty
                  ? null
                  : () => Navigator.of(context).pop([
                        for (final row in rows)
                          if (checked.contains(row.title.toLowerCase()))
                            row.title,
                      ]),
              child: Text('Add',
                  style: TextStyle(
                      color: checked.isEmpty ? t.ash : t.accent)),
            ),
          ],
        ),
      ),
    );
  }

  /// Info dialog when an import that may need the network starts while
  /// the embedded client is offline. Warn, don't block: only shrunk maps
  /// (real ant uploads over ~12 MB) and network-stored bundles need
  /// peers; everything else imports offline. Returns true to continue.
  Future<bool?> _confirmOfflineImport() {
    final t = WiTokens.of(context);
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: t.ink2,
        title: Text('Not connected',
            style: TextStyle(color: t.bone, fontSize: 16)),
        content: Text(
          'The Autonomi network is not connected. Data maps of files '
          'over ~12 MB and network-stored bundles need the network to '
          'import, so those will fail until the connection is back. '
          'Small or previously imported maps still work offline.',
          style: TextStyle(color: t.boneDim, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel', style: TextStyle(color: t.ash)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Import anyway', style: TextStyle(color: t.accent)),
          ),
        ],
      ),
    );
  }

  /// Import [files] as datamap entries into every list in [listTitles]:
  /// derive each map's address behind a "File X of Y" progress dialog
  /// with Cancel (a shrunk map expands over the network, ~20s each),
  /// then hand the results to the match/review flow
  /// ([ImportReviewSession] + [ImportReviewScreen]) which sorts them
  /// music/video, renames clean matches to canonical W@tch names, and
  /// adds them to the checked lists. Failed files are skipped and
  /// reported — when every file fails, the first failure's own message
  /// says why (offline, not a data map, …).
  Future<void> _importDatamaps(
    List<({String name, Uint8List bytes})> files, {
    required List<String> listTitles,
    List<String> extraNotes = const [],
  }) async {
    final t = WiTokens.of(context);
    var cancelled = false;
    final progress = ValueNotifier<String>('');
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => Dialog(
        backgroundColor: t.ink2,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: t.accent),
              const SizedBox(height: 18),
              Text('Importing data maps…',
                  style: TextStyle(fontSize: 13, color: t.boneDim)),
              const SizedBox(height: 6),
              ValueListenableBuilder<String>(
                valueListenable: progress,
                builder: (context, text, _) => Text(text,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11.5, color: t.ash)),
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: () => cancelled = true,
                child: Text('Cancel', style: TextStyle(color: t.ash)),
              ),
            ],
          ),
        ),
      ),
    ));
    final entries = <MediaEntry>[];
    var failed = 0;
    var attempted = 0;
    String? firstError;
    try {
      for (final file in files) {
        if (cancelled) break;
        attempted++;
        progress.value = 'File $attempted of ${files.length}\n${file.name}';
        try {
          entries.add(await entryFromDatamapFile(file.name, file.bytes,
              base: widget.importBase));
        } on ListImportException catch (e) {
          failed++;
          firstError ??= e.message;
        }
      }
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
    if (!mounted) return;
    if (entries.isEmpty) {
      if (cancelled) return; // user's choice, nothing imported yet
      _showError(files.length == 1
          ? (firstError ?? 'No data maps could be imported.')
          : 'None of the ${files.length} data maps could be imported. '
              '${firstError ?? ''}');
      return;
    }
    // The imported maps now go through the same match/review flow as
    // uploads (2026-09-02 decision): clean matches auto-accept, the
    // rest get the confirm carousel, and the review screen adds the
    // results to the chosen lists itself.
    final session = ImportReviewSession.instance;
    if (!session.idle) {
      // A leftover review is still open — reopen it instead of losing
      // it; the just-picked maps are stored and re-import instantly.
      _showError('An earlier import review was still open — finish it, '
          'then add the new files again.');
    } else {
      final tmdbKey = await AppSettings.tmdbApiKey();
      final configDir = await _importMatcherConfigDir();
      if (!mounted) return;
      await session.start(
        files: [
          for (final e in entries)
            ImportCandidate(
                name: e.name, address: e.address, sizeBytes: e.sizeBytes),
        ],
        lists: listTitles,
        tmdbKey: tmdbKey,
        configDir: configDir,
      );
    }
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => const ImportReviewScreen()));
    await _reload();
    final notes = [
      if (failed > 0)
        '$failed ${failed == 1 ? 'file' : 'files'} skipped (not a '
            'data map)',
      if (cancelled && attempted < files.length)
        '${files.length - attempted} '
            '${files.length - attempted == 1 ? 'file' : 'files'} '
            'not imported (cancelled)',
      ...extraNotes,
    ];
    if (notes.isNotEmpty) _showError(notes.join(' · '));
  }

  /// Where the import matcher keeps its config and MusicBrainz cache:
  /// the real `~/.watchit-upload` on desktop (shared with the uploader
  /// and the CLI), an app-support subdirectory on phones (no HOME).
  Future<Directory?> _importMatcherConfigDir() async {
    if (widget.importConfigDir != null) return widget.importConfigDir;
    if (Platform.isAndroid || Platform.isIOS) {
      final support = await getApplicationSupportDirectory();
      return Directory('${support.path}/upload_config');
    }
    return null;
  }

  /// A `<name>.watch-list.datamap` pick: download the bundle the map
  /// points at through the embedded client (progress dialog with
  /// Cancel), then run the normal bundle import under the bundle's own
  /// file name — so its default list title and clash handling match a
  /// local import of the same bundle.
  Future<void> _importNetworkBundle(
      String fileName, Uint8List datamapBytes,
      {String? progressLabel}) async {
    final t = WiTokens.of(context);
    var cancelled = false;
    final progress = ValueNotifier<String>('Contacting the network…');
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => Dialog(
        backgroundColor: t.ink2,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: t.accent),
              const SizedBox(height: 18),
              Text('Fetching bundle…',
                  style: TextStyle(fontSize: 13, color: t.boneDim)),
              if (progressLabel != null) ...[
                const SizedBox(height: 6),
                Text(progressLabel,
                    style: TextStyle(fontSize: 11.5, color: t.ash)),
              ],
              const SizedBox(height: 6),
              ValueListenableBuilder<String>(
                valueListenable: progress,
                builder: (context, text, _) => Text(text,
                    style: TextStyle(fontSize: 11.5, color: t.ash)),
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: () => cancelled = true,
                child: Text('Cancel', style: TextStyle(color: t.ash)),
              ),
            ],
          ),
        ),
      ),
    ));
    String mb(int bytes) =>
        (bytes / (1024 * 1024)).toStringAsFixed(1);
    Uint8List? bytes;
    try {
      bytes = await fetchBundleByDatamap(
        datamapBytes,
        base: widget.importBase,
        onProgress: (received, total) => progress.value =
            '${mb(received)} of ${mb(total)} MB',
        isCancelled: () => cancelled,
      );
    } on BundleFetchCancelled {
      // User's choice — nothing to report.
    } on ListImportException catch (e) {
      _showError(e.message);
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
    if (bytes == null || !mounted) return;
    if (!looksLikeZip(bytes)) {
      _showError('"$fileName" resolved, but the file it points at is '
          'not a .watch-list bundle.');
      return;
    }
    await _importBundle(bytes,
        fileName: mediaNameFromDatamapFileName(fileName));
  }

  /// Full bundle import: parse, ask about history, then convert every
  /// member and line into datamap-backed entries (a v1 bundle's legacy
  /// entries fetch their maps here, behind a progress dialog) and merge
  /// the resulting lists into the library.
  Future<void> _importBundle(Uint8List bytes,
      {String? fileName, String? progressLabel}) async {
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
    if (bundle.historyCount > 0) {
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
              if (progressLabel != null) ...[
                const SizedBox(height: 6),
                Text(progressLabel,
                    style: TextStyle(fontSize: 11.5, color: t.ash)),
              ],
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
      memberAddresses: result.addressByMember,
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
    final entries = bundle.historyCount;
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
  /// happened in one snackbar. Titles in [mergeExisting] (lowercased)
  /// merge without the dialog — the user already picked those lists.
  Future<void> _applyImportedLists(
    List<ParsedMediaList> parsed, {
    ParsedBundle? bundle,
    bool importHistory = true,
    Map<String, String> memberAddresses = const {},
    Set<String> mergeExisting = const {},
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
      final action = mergeExisting.contains(list.title.toLowerCase())
          ? 'merge'
          : await _resolveNameClash(list.title);
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
      final seeded = await seedBundle(bundle,
          importHistory: importHistory, addressByMember: memberAddresses);
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
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text(
                  'Send the bundle like any file, or store it on '
                  'Autonomi: upload it with the ant app — ant file '
                  'upload "$safe.watch-list" — and share the small '
                  '.watch-list.datamap file that upload creates. Others '
                  'import that file straight into W@tch (don\'t rename '
                  'it).',
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
      // ~200MB through the share sheet is unreliable; a save dialog
      // (SAF Create-Document on Android, file_selector elsewhere)
      // handles it, so bundles use one on every platform.
      shareOnMobile: false,
      note: result.entriesMissingMap > 0
          ? '${result.entriesMissingMap} '
              '${result.entriesMissingMap == 1 ? 'entry' : 'entries'} '
              'skipped — data map missing, re-import them first'
          : null,
    );
  }

  /// Hand the exported bytes to the user: on Android the system's own
  /// Create-Document (SAF) dialog via [AndroidSaf] (file_selector_android
  /// implements no save dialog — getSaveLocation throws), the share
  /// sheet on mobile when [shareOnMobile] (small files only), else the
  /// file_selector save dialog.
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
      if (Platform.isAndroid) {
        final saved = await AndroidSaf.saveFile(bytes,
            fileName: fileName, mimeType: mimeType);
        if (saved == null || !mounted) return; // dialog cancelled
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Exported $entryCount '
              '${entryCount == 1 ? 'entry' : 'entries'} to '
              '"$saved"${note == null ? '' : ' ($note)'}'),
        ));
        return;
      }
      if (shareOnMobile && Platform.isIOS) {
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
    } on PlatformException catch (e) {
      // The Android SAF channel's error carries a readable message.
      _showError('Export failed: ${e.message ?? e.code}');
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
    // Channel lists are read-only mirrors of the channel's manifest —
    // they browse, they don't edit.
    await Navigator.of(context).push(
      list.isChannel
          ? MaterialPageRoute(builder: (_) => ListHomeScreen(list: list))
          : MaterialPageRoute(
              builder: (_) => ListEditScreen(listId: list.id)),
    );
    await _reload();
  }

  Future<void> _unsubscribeChannel(MediaList list) async {
    final t = WiTokens.of(context);
    // The user's OWN channel also lives here as an amber list — it has
    // no subscription to drop, and would only be recreated by the next
    // channel check. Point at the Channels screen instead.
    try {
      final view = await ChannelService.instance.syncView();
      if (view != null && view.ownPubkey == list.channelPubkey) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('This is your own channel — manage it from '
                  'the Channels page')));
        }
        return;
      }
    } on Exception {
      // Status unavailable — fall through to the normal unsubscribe.
    }
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: t.ink2,
        title: Text('Unsubscribe from "${list.title}"?',
            style: TextStyle(color: t.bone, fontSize: 16)),
        content: Text(
          'The channel\'s list disappears from your library and stops '
          'updating. You can re-add it any time with its code.',
          style: TextStyle(color: t.boneDim, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel', style: TextStyle(color: t.ash)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Unsubscribe', style: TextStyle(color: t.rust)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ChannelService.instance.unsubscribe(list.channelPubkey!);
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
        title: Text('My Media', style: TextStyle(color: t.bone, fontSize: 18)),
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
      body: lists == null
          ? const Center(child: CircularProgressIndicator())
          : ReorderableListView(
              buildDefaultDragHandles: false,
              onReorderItem: _reorder,
              padding: const EdgeInsets.only(bottom: 24),
              header: _header(t, lists),
              children: [
                for (final (i, section)
                    in reconcileHomeSections(_stored, lists).indexed)
                  section.isSpecial
                      ? _specialRow(t, i, section)
                      : _listRow(t, i, section, lists),
              ],
            ),
    );
  }

  Widget _header(WiTokens t, List<MediaList> lists) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Plain-English pointer at the point of import — the
        // picker itself can't explain what it accepts.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text(
            'Add to library (the download button above) takes '
            'any mix of: .datamap files made by uploading a '
            'video with the ant app, .watch-list bundles '
            'exported from W@tch, and a bundle\'s own '
            '.watch-list.datamap when the bundle is stored on '
            'Autonomi. The app works out which is which.',
            style: TextStyle(fontSize: 11.5, color: t.ash),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            'Rows appear on your home screen in this order — drag the '
            'handle to reorder, untick to hide. The lighter rows are '
            'built-in (they fill themselves); tap a list to edit its '
            'entries.',
            style: TextStyle(fontSize: 11.5, color: t.ash),
          ),
        ),
        if (lists.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'No lists yet. Use "Add to library" above — it creates '
              'lists as part of the import.',
              style: TextStyle(fontSize: 13, color: t.boneDim),
            ),
          ),
      ],
    );
  }

  /// A built-in home row (Continue Watching, Favourites, Downloads,
  /// Recently Added): rendered in a lighter shade — it is not an actual
  /// list, it fills itself — but still hideable and reorderable.
  Widget _specialRow(WiTokens t, int index, HomeSection section) {
    return ListTile(
      key: ValueKey(section.id),
      tileColor: t.ink2,
      leading: Checkbox(
        value: section.visible,
        activeColor: t.accent,
        checkColor: t.ink,
        side: BorderSide(color: t.ash),
        onChanged: (v) => _setSpecialVisible(section, v ?? true),
      ),
      title: Text(
        section.title,
        style: TextStyle(
          color: section.visible ? t.boneDim : t.ash,
          fontSize: 15,
        ),
      ),
      subtitle: Text(
        'Built-in row — fills itself'
        '${section.visible ? '' : '  ·  hidden from home'}',
        style: TextStyle(color: t.ash, fontSize: 12),
      ),
      trailing: ReorderableDragStartListener(
        index: index,
        child: Icon(Icons.drag_handle, color: t.ash),
      ),
    );
  }

  Widget _listRow(
      WiTokens t, int index, HomeSection section, List<MediaList> lists) {
    // Reconcile only emits sections for lists that exist.
    final list = lists.firstWhere((l) => l.id == section.listId);
    return ListTile(
      key: ValueKey(section.id),
      leading: Checkbox(
        value: list.enabled,
        activeColor: t.accent,
        checkColor: t.ink,
        side: BorderSide(color: t.ash),
        onChanged: (v) => _setEnabled(list, v ?? true),
      ),
      title: Row(
        children: [
          if (list.isChannel) ...[
            ChannelAvatar(memberName: list.channelAvatar, size: 20),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Text(
              list.title,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: list.enabled ? t.bone : t.ash,
                fontSize: 15,
              ),
            ),
          ),
          if (list.isChannel) ...[
            const SizedBox(width: 8),
            const ChannelBadge(),
          ],
        ],
      ),
      subtitle: Text(
        '${list.entries.length} '
        '${list.entries.length == 1 ? 'entry' : 'entries'}'
        '${list.isChannel ? '  ·  read-only, updates automatically' : ''}'
        '${list.enabled ? '' : '  ·  hidden from home'}',
        style: TextStyle(color: t.ash, fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Channel lists are managed by unsubscribing — never renamed,
          // exported, or deleted like an owned list.
          if (list.isChannel)
            PopupMenuButton<String>(
              tooltip: 'Channel options',
              icon: Icon(Icons.more_vert, color: t.ash),
              color: t.ink2,
              onSelected: (v) => switch (v) {
                'unsubscribe' => _unsubscribeChannel(list),
                _ => null,
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'unsubscribe',
                  child: Text('Unsubscribe',
                      style: TextStyle(color: t.rust, fontSize: 14)),
                ),
              ],
            )
          else
            PopupMenuButton<String>(
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
          ReorderableDragStartListener(
            index: index,
            child: Icon(Icons.drag_handle, color: t.ash),
          ),
        ],
      ),
      onTap: () => _openList(list),
    );
  }
}
