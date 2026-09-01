import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:watchit_upload/watchit_upload.dart' hide MediaProbe;

import '../models/media_list.dart';
import '../services/app_settings.dart';
import '../services/batch_upload.dart';
import '../services/library_store.dart';
import '../services/publish_api.dart';
import '../theme/tokens.dart';
import 'publish_screen.dart' show pickTargetLists, addEntriesToLists;
import 'settings_screen.dart' show promptForText;
import 'wallet_screen.dart';

/// Batch upload with auto-matching — the upload CLI's prepare/upload
/// pipeline as a desktop screen. Pick files or a whole folder; every
/// file is hashed (already-uploaded content is skipped for free via the
/// shared ledger), classified with ffprobe, matched against
/// MusicBrainz/TMDB, and renamed to its canonical W@tch name. Uncertain
/// matches wait for one look; then the whole batch uploads unattended,
/// paid from the app wallet, and ends with a .watch-list bundle.
class BatchUploadScreen extends StatefulWidget {
  const BatchUploadScreen({
    super.key,
    this.apiBase,
    this.apiToken,
    this.workDirProvider,
    this.configDir,
  });

  /// Test overrides for the embedded server base URL / auth token.
  final String? apiBase;
  final String? apiToken;

  /// Test override: where the batch's manifest/datamaps/bundle live.
  final Future<Directory> Function(String listName)? workDirProvider;

  /// Test override for the CLI-config/ledger directory.
  final Directory? configDir;

  @override
  State<BatchUploadScreen> createState() => _BatchUploadScreenState();
}

class _BatchUploadScreenState extends State<BatchUploadScreen> {
  late final PublishApi _api =
      PublishApi(base: widget.apiBase, token: widget.apiToken);
  final BatchUploadSession _session = BatchUploadSession.instance;

  final List<String> _paths = [];

  /// The batch's target list — names the .watch-list bundle and is the
  /// done page's add-to-library default. Defaults to "Music" when the
  /// picked files are mostly audio, else "My uploads"; a manual pick
  /// from the dropdown sticks.
  String _list = 'My uploads';
  bool _listChosen = false;
  List<String> _libraryLists = [];
  WalletStatus? _wallet;

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSession);
    _loadWallet();
    _loadLists();
  }

  @override
  void dispose() {
    _session.removeListener(_onSession);
    super.dispose();
  }

  Future<void> _loadLists() async {
    final lists = await LibraryStore.load();
    if (!mounted) return;
    setState(() {
      _libraryLists = [
        for (final l in lists)
          if (!l.isChannel) l.title,
      ];
    });
  }

  /// Re-derive the default list from what's picked so far: a batch
  /// that's mostly audio files lands in "Music".
  void _updateDefaultList() {
    if (_listChosen) return;
    _list = defaultBatchList(_paths, fallback: _list);
  }

  void _onSession() {
    if (mounted) setState(() {});
  }

  Future<void> _loadWallet() async {
    try {
      final status = await _api.walletStatus();
      if (mounted) setState(() => _wallet = status);
    } catch (_) {
      if (mounted) {
        setState(() => _wallet = const WalletStatus(configured: false));
      }
    }
  }

  Future<void> _pickFiles() async {
    final files = await openFiles(acceptedTypeGroups: [
      const XTypeGroup(label: 'Media files', extensions: [
        'mp4', 'mkv', 'webm', 'avi', 'mov', 'm4v', 'mpg', 'ts',
        'mp3', 'flac', 'm4a', 'ogg', 'oga', 'opus', 'wav', 'aac',
      ]),
      const XTypeGroup(label: 'All files'),
    ]);
    if (files.isEmpty || !mounted) return;
    setState(() {
      for (final f in files) {
        if (!_paths.contains(f.path)) _paths.add(f.path);
      }
      _updateDefaultList();
    });
  }

  Future<void> _pickFolder() async {
    final dir = await getDirectoryPath();
    if (dir == null || !mounted) return;
    setState(() {
      if (!_paths.contains(dir)) _paths.add(dir);
      _updateDefaultList();
    });
  }

  Future<Directory> _workDir(String listName) async {
    if (widget.workDirProvider != null) {
      return widget.workDirProvider!(listName);
    }
    final support = await getApplicationSupportDirectory();
    final slug = listName
        .replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_')
        .trim()
        .replaceAll(' ', '-');
    return Directory(p.join(support.path, 'batch_uploads',
        slug.isEmpty ? 'batch' : slug));
  }

  Future<void> _start() async {
    if (_paths.isEmpty || !_session.idle) return;
    final listName = _list.trim().isEmpty ? 'My uploads' : _list.trim();
    final tmdbKey = await AppSettings.tmdbApiKey();
    final workDir = await _workDir(listName);
    if (!mounted) return;
    await _session.startPrepare(
      api: _api,
      paths: List.of(_paths),
      listName: listName,
      workDir: workDir,
      tmdbKey: tmdbKey,
      ffprobeBin: locateFfprobeBin(),
      configDir: widget.configDir,
    );
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Text('Batch upload',
            style: TextStyle(color: t.bone, fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: switch (_session.stage) {
          BatchStage.idle => _setupChildren(t),
          BatchStage.preparing => _preparingChildren(t),
          BatchStage.review => _reviewChildren(t),
          BatchStage.uploading => _uploadingChildren(t),
          BatchStage.done => _doneChildren(t),
        },
      ),
    );
  }

  // ── setup ────────────────────────────────────────────────────────────

  List<Widget> _setupChildren(WiTokens t) {
    return [
      Text(
        'Upload a folder of media with automatic naming and metadata: '
        'each file is matched against MusicBrainz (music) or TMDB '
        '(movies and shows), renamed to its canonical W@tch name, and '
        'uploaded in one unattended batch. Files you already uploaded — '
        'here or with the CLI — are recognized by content and never '
        'paid for twice.',
        style: TextStyle(color: t.boneDim, fontSize: 13, height: 1.4),
      ),
      const SizedBox(height: 8),
      Text(
        'Uploads are private and permanent, paid once in ANT from your '
        'wallet. Matching itself is free — you review everything before '
        'anything is paid.',
        style: TextStyle(color: t.ash, fontSize: 12, height: 1.4),
      ),
      const SizedBox(height: 16),
      Row(
        children: [
          OutlinedButton.icon(
            onPressed: _pickFiles,
            icon: const Icon(Icons.insert_drive_file_outlined, size: 18),
            label: const Text('Add files'),
          ),
          const SizedBox(width: 10),
          OutlinedButton.icon(
            onPressed: _pickFolder,
            icon: const Icon(Icons.folder_outlined, size: 18),
            label: const Text('Add a folder'),
          ),
        ],
      ),
      if (_paths.isNotEmpty) ...[
        const SizedBox(height: 12),
        for (final path in _paths)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              FileSystemEntity.isDirectorySync(path)
                  ? Icons.folder_outlined
                  : Icons.insert_drive_file_outlined,
              color: t.accent,
              size: 20,
            ),
            title: Text(path,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: t.bone, fontSize: 13)),
            trailing: IconButton(
              tooltip: 'Remove',
              icon: Icon(Icons.close, color: t.ash, size: 18),
              onPressed: () => setState(() => _paths.remove(path)),
            ),
          ),
        const SizedBox(height: 8),
        _listDropdown(t),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _start,
          icon: const Icon(Icons.auto_awesome),
          label: const Text('Match and prepare'),
        ),
      ],
    ];
  }

  /// Sentinel dropdown value for "Create a new list…".
  static const _kNewList = ' new-list';

  /// Target-list picker: every library list plus the "Music" and
  /// "My uploads" defaults, and a create-new entry. Music batches
  /// default to "Music" (created on add when it doesn't exist yet).
  Widget _listDropdown(WiTokens t) {
    final options = <String>{..._libraryLists, 'Music', 'My uploads', _list}
        .toList();
    return DropdownButtonFormField<String>(
      // Keyed by the selection: the default flips (e.g. to "Music") as
      // files are picked, and a FormField would otherwise keep showing
      // its first initialValue.
      key: ValueKey(_list),
      initialValue: _list,
      decoration: const InputDecoration(
        labelText: 'Add to list',
        helperText: 'Where the uploads land in your library — also names '
            'the .watch-list bundle. New lists are created on add.',
      ),
      dropdownColor: t.ink2,
      style: TextStyle(color: t.bone, fontSize: 14),
      items: [
        for (final title in options)
          DropdownMenuItem(value: title, child: Text(title)),
        const DropdownMenuItem(
            value: _kNewList, child: Text('Create a new list…')),
      ],
      onChanged: (v) async {
        if (v == null) return;
        if (v == _kNewList) {
          final title = await promptForText(
            context,
            title: 'New list',
            hint: 'e.g. Holiday videos',
          );
          final trimmed = title?.trim() ?? '';
          if (trimmed.isNotEmpty && mounted) {
            setState(() {
              _list = trimmed;
              _listChosen = true;
            });
          } else if (mounted) {
            // Re-render so the dropdown snaps back off the sentinel.
            setState(() {});
          }
          return;
        }
        setState(() {
          _list = v;
          _listChosen = true;
        });
      },
    );
  }

  // ── preparing ────────────────────────────────────────────────────────

  List<Widget> _preparingChildren(WiTokens t) {
    final confirm = _session.pendingConfirm;
    return [
      Text(
        'Matching files · ${_session.prepareDone} of '
        '${_session.prepareTotal}',
        style: TextStyle(
            color: t.bone, fontSize: 16, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      LinearProgressIndicator(
        value: _session.prepareTotal == 0
            ? null
            : _session.prepareDone / _session.prepareTotal,
        backgroundColor: t.ink2,
      ),
      const SizedBox(height: 8),
      if (confirm == null && _session.currentFile != null)
        Text(_session.currentFile!,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: t.boneDim, fontSize: 13)),
      if (confirm != null) ...[
        const SizedBox(height: 12),
        _confirmCard(t, confirm),
      ],
      const SizedBox(height: 12),
      _countsLine(t),
      const SizedBox(height: 16),
      TextButton(
        onPressed: () {
          _session.clear();
        },
        child: Text('Cancel', style: TextStyle(color: t.ash)),
      ),
    ];
  }

  Widget _countsLine(WiTokens t) {
    final parts = [
      if (_session.readyCount > 0) '${_session.readyCount} ready',
      if (_session.dedupCount > 0)
        '${_session.dedupCount} already uploaded',
      if (_session.attentionCount > 0)
        '${_session.attentionCount} need attention',
      if (_session.skippedCount > 0) '${_session.skippedCount} skipped',
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    return Text(parts.join(' · '),
        style: TextStyle(color: t.ash, fontSize: 12));
  }

  // ── confirm card ─────────────────────────────────────────────────────

  Widget _confirmCard(WiTokens t, BatchConfirm confirm) {
    final outcome = confirm.outcome;
    final art = outcome.artBytes;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.ink2,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.accent),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(outcome.matched ? 'CONFIRM MATCH' : 'NO MATCH FOUND',
              style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w700,
                  color: t.accent)),
          const SizedBox(height: 8),
          Text(p.basename(confirm.path),
              style: TextStyle(color: t.boneDim, fontSize: 12)),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (art != null) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Image.memory(Uint8List.fromList(art),
                      width: 72, fit: BoxFit.contain),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (outcome.note != null)
                      Text(outcome.note!,
                          style: TextStyle(color: t.bone, fontSize: 14)),
                    if (outcome.name != null) ...[
                      const SizedBox(height: 4),
                      Text('→ ${outcome.name}',
                          style: TextStyle(
                              color: t.boneDim,
                              fontSize: 12,
                              fontFamily: wiMonoFamily,
                              fontFamilyFallback: wiMonoFallback)),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (confirm.mbHits != null) _mbHitList(t, confirm),
          if (confirm.tmdbHits != null) _tmdbHitList(t, confirm),
          const SizedBox(height: 12),
          if (confirm.busy)
            const LinearProgressIndicator()
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (outcome.matched)
                  FilledButton(
                    onPressed: _session.confirmAccept,
                    child: const Text('Use this match'),
                  ),
                OutlinedButton(
                  onPressed: () => _manualSearchDialog(confirm),
                  child: const Text('Search…'),
                ),
                OutlinedButton(
                  onPressed: () => _pasteIdDialog(confirm),
                  child: const Text('Paste ID…'),
                ),
                OutlinedButton(
                  onPressed: () => _manualEntryDialog(confirm),
                  child: const Text('Enter details…'),
                ),
                OutlinedButton(
                  onPressed: () => _session.confirmToggleType(),
                  child: Text(outcome.type == 'music'
                      ? 'Treat as video'
                      : 'Treat as music'),
                ),
                TextButton(
                  onPressed: _session.confirmReject,
                  child: Text('No match',
                      style: TextStyle(color: t.rust)),
                ),
                TextButton(
                  onPressed: _session.confirmSkip,
                  child:
                      Text('Skip file', style: TextStyle(color: t.ash)),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _mbHitList(WiTokens t, BatchConfirm confirm) {
    final hits = confirm.mbHits!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        if (hits.isEmpty)
          Text('No results.', style: TextStyle(color: t.ash, fontSize: 12)),
        for (final hit in hits)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(
              '${hit.artist} — ${hit.title}'
              '${hit.year != null ? ' (${hit.year})' : ''}',
              style: TextStyle(color: t.bone, fontSize: 13),
            ),
            onTap: () => _session.confirmPickMb(hit.mbid),
          ),
      ],
    );
  }

  Widget _tmdbHitList(WiTokens t, BatchConfirm confirm) {
    final hits = confirm.tmdbHits!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        if (hits.isEmpty)
          Text('No results.', style: TextStyle(color: t.ash, fontSize: 12)),
        for (final hit in hits)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(
              '${hit.title}${hit.year != null ? ' (${hit.year})' : ''} '
              '· ${hit.mediaType}',
              style: TextStyle(color: t.bone, fontSize: 13),
            ),
            onTap: () => _session.confirmPickTmdb(hit.tmdbId,
                tv: hit.mediaType == 'tv'),
          ),
      ],
    );
  }

  Future<void> _manualSearchDialog(BatchConfirm confirm) async {
    final t = WiTokens.of(context);
    if (confirm.outcome.type == 'music') {
      final artist = TextEditingController(
          text: '${confirm.outcome.sidecarDefaults['artist'] ?? ''}');
      final album = TextEditingController(
          text: '${confirm.outcome.sidecarDefaults['album'] ?? ''}');
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: t.ink2,
          title: Text('Search MusicBrainz',
              style: TextStyle(color: t.bone, fontSize: 16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                  controller: artist,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Artist')),
              TextField(
                  controller: album,
                  decoration: const InputDecoration(labelText: 'Album')),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text('Cancel', style: TextStyle(color: t.ash))),
            TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text('Search', style: TextStyle(color: t.accent))),
          ],
        ),
      );
      if (ok == true && artist.text.trim().isNotEmpty) {
        await _session.confirmSearchMusic(
            artist.text.trim(), album.text.trim());
      }
      return;
    }
    final title = TextEditingController(
        text: '${confirm.outcome.sidecarDefaults['title'] ?? ''}');
    final year = TextEditingController(
        text: '${confirm.outcome.sidecarDefaults['year'] ?? ''}');
    var tv = confirm.outcome.sidecarDefaults['season'] != null;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: t.ink2,
          title: Text('Search TMDB',
              style: TextStyle(color: t.bone, fontSize: 16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                  controller: title,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Title')),
              TextField(
                  controller: year,
                  decoration:
                      const InputDecoration(labelText: 'Year (optional)')),
              CheckboxListTile(
                value: tv,
                contentPadding: EdgeInsets.zero,
                title: Text('TV show',
                    style: TextStyle(color: t.bone, fontSize: 14)),
                onChanged: (v) =>
                    setDialogState(() => tv = v ?? false),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text('Cancel', style: TextStyle(color: t.ash))),
            TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text('Search', style: TextStyle(color: t.accent))),
          ],
        ),
      ),
    );
    if (ok == true && title.text.trim().isNotEmpty) {
      await _session.confirmSearchVideo(title.text.trim(),
          year: int.tryParse(year.text.trim()), tv: tv);
    }
  }

  Future<void> _pasteIdDialog(BatchConfirm confirm) async {
    final t = WiTokens.of(context);
    final raw = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: t.ink2,
        title:
            Text('Paste an ID', style: TextStyle(color: t.bone, fontSize: 16)),
        content: TextField(
          controller: raw,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'ID or URL',
            helperText: 'MusicBrainz release, IMDb tt…, or '
                'tmdb movie:N / tv:N',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('Cancel', style: TextStyle(color: t.ash))),
          TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text('Use', style: TextStyle(color: t.accent))),
        ],
      ),
    );
    if (ok == true && raw.text.trim().isNotEmpty) {
      final recognized = await _session.confirmPasteId(raw.text.trim());
      if (!recognized) _snack('Not a recognizable ID');
    }
  }

  Future<void> _manualEntryDialog(BatchConfirm confirm) async {
    final t = WiTokens.of(context);
    final defaults = confirm.outcome.sidecarDefaults;
    var music = confirm.outcome.type == 'music';
    final title = TextEditingController(text: '${defaults['title'] ?? ''}');
    final year = TextEditingController(text: '${defaults['year'] ?? ''}');
    final artist =
        TextEditingController(text: '${defaults['artist'] ?? ''}');
    final album = TextEditingController(text: '${defaults['album'] ?? ''}');
    final track = TextEditingController(text: '${defaults['track'] ?? ''}');
    final season =
        TextEditingController(text: '${defaults['season'] ?? ''}');
    final episode =
        TextEditingController(text: '${defaults['episode'] ?? ''}');
    final description = TextEditingController();
    String? artPath;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: t.ink2,
          title: Text('Enter details',
              style: TextStyle(color: t.bone, fontSize: 16)),
          content: SizedBox(
            width: 380,
            child: ListView(
              shrinkWrap: true,
              children: [
                Text(
                  'For content not in any database — home videos, personal '
                  'recordings, unreleased work. The details travel in the '
                  'list bundle so every device shows them.',
                  style: TextStyle(color: t.ash, fontSize: 12, height: 1.4),
                ),
                const SizedBox(height: 10),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(
                        value: false,
                        label: Text('Video'),
                        icon: Icon(Icons.movie_outlined, size: 16)),
                    ButtonSegment(
                        value: true,
                        label: Text('Music'),
                        icon: Icon(Icons.music_note_outlined, size: 16)),
                  ],
                  selected: {music},
                  onSelectionChanged: (sel) =>
                      setDialogState(() => music = sel.first),
                ),
                if (music) ...[
                  TextField(
                      controller: artist,
                      decoration:
                          const InputDecoration(labelText: 'Artist')),
                  TextField(
                      controller: album,
                      decoration: const InputDecoration(labelText: 'Album')),
                  TextField(
                      controller: title,
                      decoration:
                          const InputDecoration(labelText: 'Track title')),
                  TextField(
                      controller: track,
                      decoration:
                          const InputDecoration(labelText: 'Track number')),
                ] else ...[
                  TextField(
                      controller: title,
                      decoration: const InputDecoration(labelText: 'Title')),
                  TextField(
                      controller: season,
                      decoration: const InputDecoration(
                          labelText: 'Season (optional)')),
                  TextField(
                      controller: episode,
                      decoration: const InputDecoration(
                          labelText: 'Episode (optional)')),
                ],
                TextField(
                    controller: year,
                    decoration:
                        const InputDecoration(labelText: 'Year (optional)')),
                TextField(
                    controller: description,
                    maxLines: 3,
                    decoration: const InputDecoration(
                        labelText: 'Description (optional)')),
                const SizedBox(height: 12),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: () async {
                        final file = await openFile(acceptedTypeGroups: [
                          const XTypeGroup(label: 'Images', extensions: [
                            'jpg', 'jpeg', 'png', 'webp',
                          ]),
                        ]);
                        if (file != null) {
                          setDialogState(() => artPath = file.path);
                        }
                      },
                      icon: const Icon(Icons.image_outlined, size: 16),
                      label: Text(artPath == null
                          ? 'Artwork from file…'
                          : 'Change artwork…'),
                    ),
                    if (artPath != null) ...[
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(p.basename(artPath!),
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: t.boneDim, fontSize: 12)),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text('Cancel', style: TextStyle(color: t.ash))),
            TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text('Save', style: TextStyle(color: t.accent))),
          ],
        ),
      ),
    );
    if (ok != true) return;
    if (title.text.trim().isEmpty) {
      _snack(music ? 'A track title is needed' : 'A title is needed');
      return;
    }
    await _session.confirmManual(Sidecar(
      type: music ? 'music' : 'video',
      title: title.text.trim(),
      year: int.tryParse(year.text.trim()),
      artist: artist.text.trim().isEmpty ? null : artist.text.trim(),
      album: album.text.trim().isEmpty ? null : album.text.trim(),
      track: int.tryParse(track.text.trim()),
      season: int.tryParse(season.text.trim()),
      episode: int.tryParse(episode.text.trim()),
      description:
          description.text.trim().isEmpty ? null : description.text.trim(),
      art: artPath,
    ));
  }

  // ── review ───────────────────────────────────────────────────────────

  List<Widget> _reviewChildren(WiTokens t) {
    final ready = _session.readyCount;
    final total = _session.estimatedTotalAtto;
    final wallet = _wallet;
    return [
      Text('Ready to upload',
          style: TextStyle(
              color: t.bone, fontSize: 16, fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      _countsLine(t),
      if (_session.prepareError != null) ...[
        const SizedBox(height: 8),
        Text('Prepare stopped early: ${_session.prepareError}',
            style: TextStyle(color: t.rust, fontSize: 12)),
      ],
      if (_session.attentionCount > 0) ...[
        const SizedBox(height: 8),
        Text(
          'Files needing attention are left out of this upload — they '
          'stay in the batch folder\'s manifest and can be fixed in '
          'another pass.',
          style: TextStyle(color: t.ash, fontSize: 12, height: 1.4),
        ),
      ],
      const SizedBox(height: 12),
      ..._entryTiles(t),
      const SizedBox(height: 12),
      if (total != null)
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: t.ink2,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: t.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$ready ${ready == 1 ? 'upload' : 'uploads'} · estimated '
                'cost ≈${formatUnits(total)} ANT (+ gas)',
                style: TextStyle(
                    color: t.bone,
                    fontSize: 15,
                    fontWeight: FontWeight.w600),
              ),
              if (_session.balances != null) ...[
                const SizedBox(height: 4),
                Text(
                  'Wallet: ${formatUnits(_session.balances!.antAtto)} ANT · '
                  '${formatUnits(_session.balances!.ethWei)} ETH',
                  style: TextStyle(color: t.boneDim, fontSize: 12),
                ),
              ],
              const SizedBox(height: 4),
              Text(
                'Scaled from one live network quote; each file is quoted '
                'and paid at live prices, so the total can differ.',
                style: TextStyle(color: t.ash, fontSize: 12, height: 1.4),
              ),
            ],
          ),
        )
      else if (_session.estimateError != null)
        Row(
          children: [
            Expanded(
              child: Text('Estimate failed: ${_session.estimateError}',
                  style: TextStyle(color: t.rust, fontSize: 13)),
            ),
            TextButton(
              onPressed: _session.refreshEstimate,
              child: Text('Retry', style: TextStyle(color: t.accent)),
            ),
          ],
        )
      else if (ready > 0)
        Row(
          children: [
            const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 10),
            Text('Getting a storage quote…',
                style: TextStyle(color: t.ash, fontSize: 13)),
          ],
        ),
      const SizedBox(height: 12),
      if (wallet != null && !wallet.configured)
        Row(
          children: [
            Icon(Icons.account_balance_wallet_outlined,
                color: t.rust, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text('No wallet set up yet — uploads need one.',
                  style: TextStyle(color: t.rust, fontSize: 13)),
            ),
            OutlinedButton(
              onPressed: () async {
                await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => WalletScreen(
                      apiBase: widget.apiBase, apiToken: widget.apiToken),
                ));
                await _loadWallet();
              },
              child: const Text('Set up wallet'),
            ),
          ],
        ),
      const SizedBox(height: 8),
      FilledButton.icon(
        onPressed: ready > 0 && (wallet?.configured ?? false)
            ? _session.startUpload
            : null,
        icon: const Icon(Icons.cloud_upload_outlined),
        label: Text(ready <= 1 ? 'Upload' : 'Upload $ready files'),
      ),
      const SizedBox(height: 8),
      TextButton(
        onPressed: _session.clear,
        child: Text('Discard batch', style: TextStyle(color: t.ash)),
      ),
    ];
  }

  List<Widget> _entryTiles(WiTokens t) {
    return [
      for (final e in _session.entries)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Icon(
                switch (e.status) {
                  'ready' => Icons.schedule,
                  'already-uploaded' => Icons.cloud_done_outlined,
                  'uploaded' => Icons.check_circle_outline,
                  'needs-attention' => Icons.help_outline,
                  'failed' => Icons.error_outline,
                  _ => Icons.remove_circle_outline,
                },
                size: 16,
                color: switch (e.status) {
                  'uploaded' || 'already-uploaded' => t.signalOk,
                  'failed' => t.rust,
                  'needs-attention' => t.rust,
                  'skipped' => t.ash,
                  _ => t.accent,
                },
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  e.name ?? p.basename(e.source),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: e.status == 'skipped' ? t.ash : t.boneDim,
                      fontSize: 13),
                ),
              ),
            ],
          ),
        ),
    ];
  }

  // ── uploading ────────────────────────────────────────────────────────

  List<Widget> _uploadingChildren(WiTokens t) {
    final job = _session.currentJob;
    final phase = job?.phase ?? 'starting';
    final total = job?.total ?? 0;
    final done = job?.done ?? 0;
    final label = switch (phase) {
      'starting' => 'Starting upload…',
      'encrypting' => 'Encrypting file…',
      'quoting' =>
        'Getting storage quotes${total > 0 ? ' ($done of $total)' : '…'}',
      'paying' => 'Paying for storage…',
      'storing' => 'Storing chunks${total > 0 ? ' ($done of $total)' : '…'}',
      _ => phase,
    };
    return [
      Text(
        'Uploading · ${(_session.uploadDone + 1).clamp(1, _session.uploadTotal == 0 ? 1 : _session.uploadTotal)} '
        'of ${_session.uploadTotal}',
        style: TextStyle(
            color: t.bone, fontSize: 16, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      LinearProgressIndicator(
        value: _session.uploadTotal == 0
            ? null
            : _session.uploadDone / _session.uploadTotal,
        backgroundColor: t.ink2,
      ),
      const SizedBox(height: 16),
      if (_session.currentUploadName != null)
        Text(_session.currentUploadName!,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: t.bone, fontSize: 14)),
      const SizedBox(height: 8),
      LinearProgressIndicator(
        value: phase == 'storing' && total > 0 ? done / total : null,
        backgroundColor: t.ink2,
      ),
      const SizedBox(height: 8),
      Text(label, style: TextStyle(color: t.boneDim, fontSize: 13)),
      const SizedBox(height: 8),
      Text(
        'You can leave this page — uploading continues and picks up here '
        'when you come back. Failures get one automatic retry at the '
        'end. Just keep W@tch open until it finishes.',
        style: TextStyle(color: t.ash, fontSize: 12),
      ),
      const SizedBox(height: 16),
      ..._entryTiles(t),
    ];
  }

  // ── done ─────────────────────────────────────────────────────────────

  List<Widget> _doneChildren(WiTokens t) {
    final uploaded = _session.uploadedEntries;
    final failed = _session.failedCount;
    final allGood = failed == 0 && _session.attentionCount == 0;
    return [
      Row(
        children: [
          Icon(
            allGood && uploaded.isNotEmpty
                ? Icons.check_circle_outline
                : Icons.info_outline,
            color: allGood && uploaded.isNotEmpty ? t.signalOk : t.rust,
            size: 28,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text('Batch finished',
                style: TextStyle(
                    color: t.bone,
                    fontSize: 18,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Text(
        '${_session.uploadedCount} uploaded · '
        '${_session.dedupCount} already on the network'
        '${failed > 0 ? ' · $failed failed' : ''}'
        '${_session.attentionCount > 0 ? ' · ${_session.attentionCount} needing attention' : ''}',
        style: TextStyle(color: t.boneDim, fontSize: 13),
      ),
      const SizedBox(height: 12),
      ..._entryTiles(t),
      const SizedBox(height: 12),
      if (_session.bundlePath != null)
        Text(
          'Bundle: ${_session.bundlePath}\nShare this .watch-list file to '
          'hand the whole batch to another device or person.',
          style: TextStyle(color: t.ash, fontSize: 12, height: 1.4),
        ),
      const SizedBox(height: 16),
      if (uploaded.isNotEmpty) ...[
        FilledButton.icon(
          onPressed: () => _addAllToLibrary(),
          icon: const Icon(Icons.video_library_outlined),
          label: Text('Add to "${_session.manifest?.listName ?? 'library'}"'),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () => _addAllToLibrary(pickLists: true),
          icon: const Icon(Icons.playlist_add),
          label: const Text('Add to other lists…'),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _saveBundleCopy,
          icon: const Icon(Icons.save_alt),
          label: const Text('Save bundle to…'),
        ),
        const SizedBox(height: 10),
      ],
      if (failed > 0)
        OutlinedButton.icon(
          onPressed: _session.retryFailed,
          icon: const Icon(Icons.refresh),
          label: Text('Retry $failed failed'),
        ),
      TextButton(
        onPressed: _session.clear,
        child: Text('Done', style: TextStyle(color: t.ash)),
      ),
    ];
  }

  /// Add the uploads to the library — straight into the batch's chosen
  /// list by default, or via the multi-list picker ([pickLists]).
  Future<void> _addAllToLibrary({bool pickLists = false}) async {
    final uploaded = _session.uploadedEntries;
    if (uploaded.isEmpty) return;
    List<String>? chosen;
    if (pickLists) {
      final lists = await LibraryStore.load();
      if (!mounted) return;
      chosen = await pickTargetLists(context, lists);
    } else {
      final list = _session.manifest?.listName.trim();
      chosen = [list == null || list.isEmpty ? 'My uploads' : list];
    }
    if (chosen == null || chosen.isEmpty) return;
    final entries = [
      for (final e in uploaded)
        MediaEntry(
          name: e.name!,
          address: e.address!,
          sizeBytes: e.sizeBytes,
        ),
    ];
    await addEntriesToLists(entries, chosen);
    _snack('Added ${entries.length} '
        '${entries.length == 1 ? 'title' : 'titles'} to '
        '${chosen.length == 1 ? chosen.first : '${chosen.length} lists'}');
  }

  Future<void> _saveBundleCopy() async {
    final bundle = _session.bundlePath;
    if (bundle == null) return;
    final dir = await getDirectoryPath();
    if (dir == null) return;
    try {
      final dest = p.join(dir, p.basename(bundle));
      File(bundle).copySync(dest);
      _snack('Saved ${p.basename(bundle)}');
    } catch (e) {
      _snack('Could not save the bundle: $e');
    }
  }
}

/// The default target list for a batch of [paths] (files or folders):
/// "Music" when the media files are mostly audio, else "My uploads".
/// [fallback] survives empty or unreadable picks.
String defaultBatchList(List<String> paths,
    {String fallback = 'My uploads'}) {
  try {
    final files = collectMediaFiles(paths);
    if (files.isEmpty) return fallback;
    final audio = files
        .where(
            (f) => kAudioExtensions.contains(p.extension(f).toLowerCase()))
        .length;
    return audio * 2 > files.length ? 'Music' : 'My uploads';
  } catch (_) {
    return fallback;
  }
}

/// The bundled ffprobe beside the executable (AppImage / Windows zip
/// ship one), falling back to PATH — FfmpegService's location rule.
String locateFfprobeBin() {
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final ext = Platform.isWindows ? '.exe' : '';
  final bundled = '$exeDir${Platform.pathSeparator}ffprobe$ext';
  return File(bundled).existsSync() ? bundled : 'ffprobe';
}
