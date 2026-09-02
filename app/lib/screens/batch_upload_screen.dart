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
import '../services/ffmpeg.dart' show FfmpegService;
import '../services/library_store.dart';
import '../services/publish_plan.dart' as plan;
import '../services/publish_api.dart';
import '../theme/tokens.dart';
import 'publish_screen.dart' show pickTargetLists;
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
    this.batchRootProvider,
  });

  /// Test overrides for the embedded server base URL / auth token.
  final String? apiBase;
  final String? apiToken;

  /// Test override: where the batch's manifest/datamaps/bundle live.
  final Future<Directory> Function(String listName)? workDirProvider;

  /// Test override for the CLI-config/ledger directory.
  final Directory? configDir;

  /// Test override for the earlier-batches root the needs-attention
  /// scan reads (`<support>/batch_uploads` normally).
  final Future<Directory> Function()? batchRootProvider;

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
  List<PreviousBatch> _previous = [];
  bool _showFinished = false;
  bool _rights = false;
  late BatchStage _lastStage = _session.stage;

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSession);
    _loadWallet();
    _loadLists();
    _loadAttention();
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

  Future<Directory> _batchRoot() async => widget.batchRootProvider != null
      ? widget.batchRootProvider!()
      : Directory(p.join(
          (await getApplicationSupportDirectory()).path, 'batch_uploads'));

  /// Earlier batches — every work dir with a manifest, attention counts
  /// included.
  Future<void> _loadAttention() async {
    try {
      final batches = await scanPreviousBatches(await _batchRoot());
      if (mounted) setState(() => _previous = batches);
    } catch (_) {
      // No support dir (tests) — nothing to surface.
    }
  }

  /// Re-run prepare over one earlier batch's needs-attention files, in
  /// its own work dir under its original list — the files re-match and
  /// raise their confirm cards again.
  Future<void> _reviewAttention(PreviousBatch batch) async {
    if (!_session.idle) return;
    final tmdbKey = await AppSettings.tmdbApiKey();
    if (!mounted) return;
    await _session.startPrepare(
      api: _api,
      paths: batch.attentionSources,
      listName: batch.listName,
      workDir: batch.workDir,
      tmdbKey: tmdbKey,
      ffprobeBin: locateFfprobeBin(),
      configDir: widget.configDir,
      ffmpeg: FfmpegService(),
    );
  }

  /// Continue an interrupted batch: reopen it at its review page —
  /// already-uploaded files are skipped, the rest upload from there.
  Future<void> _continueBatch(PreviousBatch batch) async {
    if (!_session.idle) return;
    await _session.resumeBatch(
      api: _api,
      workDir: batch.workDir,
      ffprobeBin: locateFfprobeBin(),
      configDir: widget.configDir,
      ffmpeg: FfmpegService(),
    );
  }

  /// Dismiss: stop surfacing the batch's needs-attention files (they
  /// flip to skipped in its manifest; ledger and bundle untouched).
  void _dismissBatch(PreviousBatch batch) {
    try {
      dismissBatch(batch);
    } catch (_) {}
    _loadAttention();
  }

  /// Delete a batch's records after a confirm — manifest, datamaps,
  /// bundle, artwork, encode leftovers. Uploaded files stay on the
  /// network and in the shared ledger (never re-paid) unless the
  /// "also forget" opt-in is ticked, which drops the batch's hashes
  /// from the ledger too — the full "make the app forget" action.
  Future<void> _deleteBatch(PreviousBatch batch) async {
    final t = WiTokens.of(context);
    var forget = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: t.ink2,
          title: Text('Delete this batch\'s records?',
              style: TextStyle(color: t.bone, fontSize: 16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Removes only the batch\'s own records — its manifest, '
                'saved bundle, and working files — freeing their disk '
                'space. Anything already added to your library stays '
                'there, files already uploaded stay on the network, and '
                'they are still recognized — never paid for twice.',
                style:
                    TextStyle(color: t.boneDim, fontSize: 13, height: 1.4),
              ),
              if (batch.uploadedShas.isNotEmpty) ...[
                const SizedBox(height: 8),
                CheckboxListTile(
                  value: forget,
                  onChanged: (v) =>
                      setDialogState(() => forget = v ?? false),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(
                      batch.uploadedShas.length == 1
                          ? 'Also forget this upload'
                          : 'Also forget these '
                              '${batch.uploadedShas.length} uploads',
                      style: TextStyle(color: t.bone, fontSize: 13)),
                  subtitle: Text(
                    'Removes them from the upload history, so putting '
                    'the same files through a new batch uploads — and '
                    'pays — again. What\'s already on the network stays '
                    'there either way; this only makes this app forget.',
                    style: TextStyle(
                        color: t.boneDim, fontSize: 12, height: 1.35),
                  ),
                ),
              ],
            ],
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
      ),
    );
    if (confirmed != true || !mounted) return;
    if (forget) forgetUploads(batch, configDir: widget.configDir);
    deleteBatch(batch);
    await _loadAttention();
  }

  void _onSession() {
    if (!mounted) return;
    // A batch rewrites its manifest as files are decided/uploaded — a
    // one-shot initState scan left the earlier-batches card stale until
    // the screen was reopened. Re-scan (and refresh the list options a
    // finished batch may have created) on every stage change, so the
    // setup page is current the moment the session returns to it.
    if (_session.stage != _lastStage) {
      _lastStage = _session.stage;
      _loadAttention();
      _loadLists();
    }
    setState(() {});
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

  /// A FRESH work dir per batch (list slug + start timestamp) — sharing
  /// one dir per list made a new batch inherit the previous batch's
  /// manifest: stale counts, and worse, its leftover `ready` files
  /// joining this batch's estimate and paid upload.
  Future<Directory> _workDir(String listName) async {
    if (widget.workDirProvider != null) {
      return widget.workDirProvider!(listName);
    }
    final support = await getApplicationSupportDirectory();
    return Directory(
        p.join(support.path, 'batch_uploads', batchDirName(listName)));
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
      ffmpeg: FfmpegService(),
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
        // "Batch" is pipeline jargon — to the user this is just the
        // upload, whether it's one file or a folder.
        title: Text('Upload',
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
        'uploaded in one unattended pass. Music is reviewed one whole '
        'album at a time, not track by track. Files you already '
        'uploaded — here or with the CLI — are recognized by content '
        'and never paid for twice.',
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
      if (_previous.isNotEmpty) ...[
        const SizedBox(height: 16),
        _previousUploadsCard(t),
      ],
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
        ..._listPicker(t),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _start,
          icon: const Icon(Icons.auto_awesome),
          label: const Text('Match and prepare'),
        ),
      ],
    ];
  }

  /// Earlier batches as a management list: unfinished batches (files
  /// needing attention, or an upload that was cut short) with Continue
  /// / Review / Dismiss / Delete. Fully finished batches are records,
  /// not work — they hide behind a one-line Show toggle instead of
  /// piling up (Delete stays reachable there to clear the history;
  /// library entries and network uploads are never touched).
  Widget _previousUploadsCard(WiTokens t) {
    final unfinished = [for (final b in _previous) if (!b.finished) b];
    final finished = [for (final b in _previous) if (b.finished) b];
    final total =
        _previous.fold(0, (n, b) => n + b.attentionSources.length);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.ink2,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(total > 0 ? Icons.help_outline : Icons.history,
                  color: total > 0 ? t.rust : t.ash, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  total > 0
                      ? '$total ${total == 1 ? 'file' : 'files'} from '
                          'earlier uploads still '
                          '${total == 1 ? 'needs' : 'need'} attention'
                      : 'Previous uploads',
                  style: TextStyle(
                      color: t.bone,
                      fontSize: 14,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final batch in unfinished) _previousBatchRow(t, batch),
          if (_showFinished)
            for (final batch in finished) _previousBatchRow(t, batch),
          if (finished.isNotEmpty)
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${finished.length} finished '
                    '${finished.length == 1 ? 'batch' : 'batches'} '
                    'kept as upload records',
                    style: TextStyle(color: t.ash, fontSize: 12),
                  ),
                ),
                TextButton(
                  onPressed: () =>
                      setState(() => _showFinished = !_showFinished),
                  child: Text(_showFinished ? 'Hide' : 'Show',
                      style: TextStyle(color: t.ash)),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _previousBatchRow(WiTokens t, PreviousBatch batch) {
    final counts = [
      for (final status in const [
        'uploaded',
        'already-uploaded',
        'ready',
        'needs-attention',
        'failed',
        'skipped',
      ])
        if ((batch.counts[status] ?? 0) > 0)
          '${batch.counts[status]} ${switch (status) {
            'already-uploaded' => 'already uploaded',
            'needs-attention' => batch.counts[status] == 1
                ? 'needs attention'
                : 'need attention',
            _ => status,
          }}',
    ].join(' · ');
    final date = batch.created;
    final when = date == null
        ? null
        : '${date.year}-${date.month.toString().padLeft(2, '0')}-'
            '${date.day.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${batch.listName}${when != null ? ' · $when' : ''}',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.boneDim, fontSize: 13),
                ),
                if (counts.isNotEmpty)
                  Text(counts,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: t.ash, fontSize: 12)),
              ],
            ),
          ),
          if (batch.interrupted)
            OutlinedButton(
              onPressed: () => _continueBatch(batch),
              child: const Text('Continue'),
            ),
          if (batch.needsAttention) ...[
            OutlinedButton(
              onPressed: () => _reviewAttention(batch),
              child: const Text('Review'),
            ),
            TextButton(
              onPressed: () => _dismissBatch(batch),
              child: Text('Dismiss', style: TextStyle(color: t.ash)),
            ),
          ],
          IconButton(
            tooltip: 'Delete batch',
            icon: Icon(Icons.delete_outline, color: t.ash, size: 18),
            onPressed: () => _deleteBatch(batch),
          ),
        ],
      ),
    );
  }

  /// Target-list choice, done-page button style (no dropdown): the
  /// filled button shows where the batch will land, the outlined one
  /// changes it. Music batches default to "Music" (created on add when
  /// it doesn't exist yet).
  List<Widget> _listPicker(WiTokens t) {
    return [
      Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          FilledButton.tonalIcon(
            onPressed: _chooseList,
            icon: const Icon(Icons.video_library_outlined, size: 18),
            label: Text('Add to "$_list"'),
          ),
          OutlinedButton.icon(
            onPressed: _chooseList,
            icon: const Icon(Icons.playlist_add, size: 18),
            label: const Text('Choose another list…'),
          ),
        ],
      ),
      const SizedBox(height: 6),
      Text(
        'Where the uploads land in your library — also names the '
        '.watch-list bundle. New lists are created on add.',
        style: TextStyle(color: t.ash, fontSize: 12, height: 1.4),
      ),
    ];
  }

  Future<void> _chooseList() async {
    final t = WiTokens.of(context);
    final options =
        <String>{..._libraryLists, 'Music', 'My uploads', _list}.toList();
    final picked = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        backgroundColor: t.ink2,
        title: Text('Add to list',
            style: TextStyle(color: t.bone, fontSize: 16)),
        children: [
          for (final title in options)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(title),
              child: Row(
                children: [
                  Icon(
                    title == _list
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: 18,
                    color: title == _list ? t.accent : t.ash,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(title,
                        style: TextStyle(color: t.bone, fontSize: 14)),
                  ),
                ],
              ),
            ),
          SimpleDialogOption(
            onPressed: () async {
              final title = await promptForText(
                context,
                title: 'New list',
                hint: 'e.g. Holiday videos',
              );
              final trimmed = title?.trim() ?? '';
              if (context.mounted) {
                Navigator.of(context)
                    .pop(trimmed.isEmpty ? null : trimmed);
              }
            },
            child: Row(
              children: [
                Icon(Icons.add, size: 18, color: t.accent),
                const SizedBox(width: 10),
                Text('Create a new list…',
                    style: TextStyle(color: t.accent, fontSize: 14)),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked != null && picked.trim().isNotEmpty && mounted) {
      setState(() {
        _list = picked.trim();
        _listChosen = true;
      });
    }
  }

  // ── preparing ────────────────────────────────────────────────────────

  List<Widget> _preparingChildren(WiTokens t) {
    final confirm = _session.pendingConfirm;
    final albumConfirm = _session.pendingAlbumConfirm;
    final reviewing = _session.reviewingMatches;
    final decided = switch (_session.confirmables.elementAtOrNull(
        _session.confirmIndex)) {
      final BatchConfirm c => c.decided,
      final AlbumConfirm a => a.decided,
      _ => false,
    };
    return [
      if (reviewing) ...[
        // Carousel over everything that needed eyes: ←/→ revisit
        // earlier cards, answering a decided one replaces the earlier
        // answer (mistakes stay fixable).
        Row(
          children: [
            IconButton(
              tooltip: 'Previous',
              onPressed: _session.confirmIndex > 0
                  ? _session.confirmPrevious
                  : null,
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Text(
                'Review matches · ${_session.confirmIndex + 1} of '
                '${_session.confirmables.length}',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: t.bone,
                    fontSize: 16,
                    fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              tooltip: 'Next',
              onPressed:
                  _session.confirmIndex < _session.confirmables.length - 1
                      ? _session.confirmNext
                      : null,
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        if (decided) ...[
          const SizedBox(height: 4),
          Text(
            'Already answered — a new choice replaces the earlier one.',
            style: TextStyle(color: t.ash, fontSize: 12),
          ),
        ],
      ] else ...[
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
        if (confirm == null &&
            albumConfirm == null &&
            _session.currentFile != null)
          Text(_session.currentFile!,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: t.boneDim, fontSize: 13)),
      ],
      if (confirm != null) ...[
        const SizedBox(height: 12),
        _confirmCard(t, confirm),
      ],
      if (albumConfirm != null) ...[
        const SizedBox(height: 12),
        _albumConfirmCard(t, albumConfirm),
      ],
      if (reviewing && _session.undecidedConfirmCount == 0) ...[
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _session.finishConfirms,
          icon: const Icon(Icons.done_all),
          label: const Text('Back to summary'),
        ),
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
      if (_session.uploadedCount > 0)
        '${_session.uploadedCount} uploaded',
      if (_session.dedupCount > 0)
        '${_session.dedupCount} already uploaded',
      if (_session.attentionCount > 0)
        '${_session.attentionCount} need attention',
      if (_session.failedCount > 0) '${_session.failedCount} failed',
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

  // ── album confirm card ───────────────────────────────────────────────

  /// One card for a whole album: the release decision applies to every
  /// track, so a rip is reviewed in one look instead of track by track.
  Widget _albumConfirmCard(WiTokens t, AlbumConfirm confirm) {
    final album = confirm.album;
    final art = album?.artBytes;
    final placed =
        confirm.outcomes.where((o) => o?.matched ?? false).length;
    final total = confirm.tracks.length;
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
          Text(album != null ? 'CONFIRM ALBUM MATCH' : 'NO ALBUM MATCH',
              style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w700,
                  color: t.accent)),
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
                    if (confirm.albumLine != null)
                      Text(confirm.albumLine!,
                          style: TextStyle(color: t.bone, fontSize: 14)),
                    if (album == null)
                      Text(
                          'These files look like one album, but no '
                          'release matched. Search MusicBrainz, paste a '
                          'release ID, or enter the details once for all '
                          'of them.',
                          style: TextStyle(
                              color: t.bone, fontSize: 13, height: 1.4)),
                    const SizedBox(height: 4),
                    Text(
                        '$placed of $total tracks placed'
                        '${placed < total && album != null ? ' — unplaced tracks are set aside for another pass' : ''}',
                        style: TextStyle(color: t.boneDim, fontSize: 12)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < confirm.tracks.length; i++)
            _albumTrackRow(t, confirm, i),
          if (confirm.mbHits != null) _albumMbHitList(t, confirm),
          const SizedBox(height: 12),
          if (confirm.busy)
            const LinearProgressIndicator()
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (album != null)
                  FilledButton(
                    onPressed: _session.albumAccept,
                    child: Text('Use for all '
                        '$placed track${placed == 1 ? '' : 's'}'),
                  ),
                OutlinedButton(
                  onPressed: () => _albumSearchDialog(confirm),
                  child: const Text('Search…'),
                ),
                OutlinedButton(
                  onPressed: () => _albumPasteIdDialog(confirm),
                  child: const Text('Paste ID…'),
                ),
                OutlinedButton(
                  onPressed: () => _albumManualDialog(confirm),
                  child: const Text('Enter details…'),
                ),
                TextButton(
                  onPressed: _session.albumReject,
                  child:
                      Text('No match', style: TextStyle(color: t.rust)),
                ),
                TextButton(
                  onPressed: _session.albumSkip,
                  child:
                      Text('Skip album', style: TextStyle(color: t.ash)),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _albumTrackRow(WiTokens t, AlbumConfirm confirm, int i) {
    final out = confirm.outcomes[i];
    final ok = out?.matched ?? false;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(ok ? Icons.check : Icons.help_outline,
              size: 14, color: ok ? t.signalOk : t.rust),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              ok
                  ? out!.name!
                  : '${p.basename(confirm.tracks[i])} — not placed',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: ok ? t.boneDim : t.rust,
                  fontSize: 12,
                  fontFamily: ok ? wiMonoFamily : null,
                  fontFamilyFallback: ok ? wiMonoFallback : null),
            ),
          ),
        ],
      ),
    );
  }

  Widget _albumMbHitList(WiTokens t, AlbumConfirm confirm) {
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
            onTap: () => _session.albumPickMb(hit.mbid),
          ),
      ],
    );
  }

  Future<void> _albumSearchDialog(AlbumConfirm confirm) async {
    final t = WiTokens.of(context);
    final artist = TextEditingController(
        text: '${confirm.defaults['artist'] ?? ''}');
    final album =
        TextEditingController(text: '${confirm.defaults['album'] ?? ''}');
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
      await _session.albumSearch(artist.text.trim(), album.text.trim());
    }
  }

  Future<void> _albumPasteIdDialog(AlbumConfirm confirm) async {
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
            helperText: 'MusicBrainz release ID or URL — applied to '
                'every track of the album',
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
      final recognized = await _session.albumPasteId(raw.text.trim());
      if (!recognized) _snack('Not a MusicBrainz release ID');
    }
  }

  /// Case B for a whole album: artist/album/year/artwork entered once,
  /// track titles and numbers from each file's tags or name.
  Future<void> _albumManualDialog(AlbumConfirm confirm) async {
    final t = WiTokens.of(context);
    final artist = TextEditingController(
        text: '${confirm.defaults['artist'] ?? ''}');
    final album =
        TextEditingController(text: '${confirm.defaults['album'] ?? ''}');
    final year =
        TextEditingController(text: '${confirm.defaults['year'] ?? ''}');
    final description = TextEditingController();
    String? artPath;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: t.ink2,
          title: Text('Enter album details',
              style: TextStyle(color: t.bone, fontSize: 16)),
          content: SizedBox(
            width: 380,
            child: ListView(
              shrinkWrap: true,
              children: [
                Text(
                  'For an album not in any database — one entry covers '
                  'all ${confirm.tracks.length} tracks; each track keeps '
                  'its own title and number from its tags or file name.',
                  style: TextStyle(color: t.ash, fontSize: 12, height: 1.4),
                ),
                const SizedBox(height: 10),
                TextField(
                    controller: artist,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: 'Artist')),
                TextField(
                    controller: album,
                    decoration: const InputDecoration(labelText: 'Album')),
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
    if (artist.text.trim().isEmpty || album.text.trim().isEmpty) {
      _snack('Artist and album are needed');
      return;
    }
    await _session.albumManual(
      artist: artist.text.trim(),
      album: album.text.trim(),
      year: int.tryParse(year.text.trim()),
      description:
          description.text.trim().isEmpty ? null : description.text.trim(),
      artPath: artPath,
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
    final planned = _session.plannedUploadCount;
    final total = _session.estimatedTotalAtto;
    final wallet = _wallet;
    return [
      Text('Ready to upload',
          style: TextStyle(
              color: t.bone, fontSize: 16, fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      _countsLine(t),
      if (_session.confirmables.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(
          'Every match has a card — automatically accepted ones too. '
          'Tap a file below to see what it matched (title, artwork) '
          'and change the answer if it\'s wrong.',
          style: TextStyle(color: t.ash, fontSize: 12, height: 1.4),
        ),
      ],
      if (_session.prepareError != null) ...[
        const SizedBox(height: 8),
        Text('Prepare stopped early: ${_session.prepareError}',
            style: TextStyle(color: t.rust, fontSize: 12)),
      ],
      if (_session.attentionCount > 0) ...[
        const SizedBox(height: 8),
        Text(
          'Files needing attention are left out of this upload — they '
          'stay in its manifest and can be fixed in another pass.',
          style: TextStyle(color: t.ash, fontSize: 12, height: 1.4),
        ),
      ],
      const SizedBox(height: 12),
      ..._entryTiles(t),
      ..._qualitySection(t),
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
                '$planned ${planned == 1 ? 'upload' : 'uploads'} · '
                'estimated cost ≈${formatUnits(total)} ANT (+ gas)',
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
      if (ready > 0)
        CheckboxListTile(
          value: _rights,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(
            'I have the right to upload '
            '${ready == 1 ? 'this file' : 'these files'} — '
            '${ready == 1 ? 'it is' : 'they are'} my own work, '
            'verifiably public domain, or a personal copy for private '
            'use.',
            style: TextStyle(color: t.bone, fontSize: 13),
          ),
          onChanged: (v) => setState(() => _rights = v ?? false),
        ),
      // A batch where every file deduped against the ledger has nothing
      // to pay for, but finishing it still adds the files back to the
      // chosen list (and rebuilds the bundle) — the free way to restore
      // something deleted from the library by mistake.
      if (ready == 0 && _session.dedupCount > 0) ...[
        Text(
          'Everything here is already on the network — finishing is '
          'free and adds ${_session.dedupCount == 1 ? 'it' : 'them'} '
          'to "${_session.manifest?.listName ?? 'the list'}".',
          style: TextStyle(color: t.ash, fontSize: 12, height: 1.4),
        ),
        const SizedBox(height: 8),
      ],
      const SizedBox(height: 8),
      FilledButton.icon(
        onPressed: ready > 0
            ? (_rights && (wallet?.configured ?? false)
                ? _session.startUpload
                : null)
            : _session.dedupCount > 0
                ? _session.startUpload
                : null,
        icon: Icon(ready == 0 && _session.dedupCount > 0
            ? Icons.library_add_outlined
            : Icons.cloud_upload_outlined),
        label: Text(ready == 0 && _session.dedupCount > 0
            ? 'Add to library'
            : planned <= 1
                ? 'Upload'
                : 'Upload $planned files'),
      ),
      const SizedBox(height: 8),
      TextButton(
        onPressed: _session.clear,
        child: Text('Discard upload', style: TextStyle(color: t.ash)),
      ),
    ];
  }

  /// QUALITY tiers for the batch's video entries (the old Upload tier
  /// flow relocated to where the batch is reviewed): each ticked tier
  /// is encoded with the bundled ffmpeg and uploaded for every video it
  /// applies to; same-title versions fold into one library card with a
  /// version picker. Hidden when the batch has no (probeable) videos.
  List<Widget> _qualitySection(WiTokens t) {
    final videos = _session.readyVideoEntries;
    final ordered = _session.offeredTiers;
    if (videos.isEmpty ||
        (ordered.length == 1 &&
            ordered.single == plan.PublishTier.original)) {
      return const [];
    }
    final uncovered = _session.uncoveredVideoEntries;
    return [
      const SizedBox(height: 16),
      Row(
        children: [
          Text(
            'QUALITY',
            style: TextStyle(
                fontSize: 11,
                letterSpacing: 1.5,
                fontWeight: FontWeight.w700,
                color: t.ash),
          ),
          const SizedBox(width: 2),
          IconButton(
            tooltip: 'Why multiple versions?',
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.info_outline, color: t.ash, size: 16),
            onPressed: () => _showWhyVersionsDialog(t),
          ),
        ],
      ),
      Text(
        'Devices and connections vary — smaller versions play smoothly '
        'where the full-quality file can\'t. Each ticked quality is '
        'encoded and uploaded for every video it applies to; your '
        'library shows one card with a version picker.',
        style: TextStyle(color: t.ash, fontSize: 12, height: 1.4),
      ),
      for (final tier in ordered) _tierTile(t, tier, videos),
      if (uncovered.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '${uncovered.length} '
            '${uncovered.length == 1 ? 'video matches' : 'videos match'} '
            'none of the ticked qualities and will upload as-is.',
            style: TextStyle(color: t.rust, fontSize: 12, height: 1.4),
          ),
        ),
    ];
  }

  Widget _tierTile(
      WiTokens t, plan.PublishTier tier, List<ManifestEntry> videos) {
    final applicable = [
      for (final e in videos)
        if (plan
            .offeredTiers(_session.videoProbes[e.source])
            .contains(tier))
          e,
    ];
    var knownBytes = 0;
    var anyUnknown = false;
    for (final e in applicable) {
      final bytes = plan.predictedSizeBytes(
          _session.videoProbes[e.source], tier, e.sizeBytes ?? 0);
      if (bytes == null) {
        anyUnknown = true;
      } else {
        knownBytes += bytes;
      }
    }
    final spec = plan.kTierSpecs[tier];
    final title = tier == plan.PublishTier.original
        ? 'Original files (as-is)'
        : '${spec!.name} · ${spec.label} H.264';
    final details = [
      if (videos.length > 1)
        'applies to ${applicable.length} of ${videos.length} videos',
      if (knownBytes > 0)
        '≈${formatBytes(knownBytes)}${anyUnknown ? '+' : ''}',
    ].join(' · ');
    return CheckboxListTile(
      dense: true,
      value: _session.tiers.contains(tier),
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(title, style: TextStyle(color: t.bone, fontSize: 14)),
      subtitle: details.isEmpty
          ? null
          : Text(details, style: TextStyle(color: t.ash, fontSize: 12)),
      onChanged: (v) => _session.setTier(tier, v ?? false),
    );
  }

  /// The full "why" story behind the quality tiers, one tap away from
  /// where the choice is made (moved from the old Upload tier flow).
  void _showWhyVersionsDialog(WiTokens t) {
    final style = TextStyle(color: t.boneDim, fontSize: 13, height: 1.5);
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: t.ink2,
        title: Text('Why multiple versions?',
            style: TextStyle(color: t.bone, fontSize: 16)),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'One file rarely suits every viewer. A full-quality file '
                'can stutter or fail entirely on phones, TVs and older '
                'computers, and it needs a fast connection to stream '
                'without buffering. Smaller versions play everywhere and '
                'start quickly even on slow links.',
                style: style,
              ),
              const SizedBox(height: 12),
              Text(
                'Uploads to Autonomi are permanent — a file can\'t be '
                'replaced with a re-encoded copy later. Any quality you '
                'want your devices to have needs to be uploaded now.',
                style: style,
              ),
              const SizedBox(height: 12),
              Text(
                'The extra versions don\'t clutter anyone\'s library: '
                'uploads of the same title share a single card, and its '
                'page has a version picker where you choose what plays '
                'best on each device.',
                style: style,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Close', style: TextStyle(color: t.accent)),
          ),
        ],
      ),
    );
  }

  List<Widget> _entryTiles(WiTokens t) {
    final reopenable =
        _session.stage == BatchStage.review;
    return [
      for (final e in _session.entries)
        InkWell(
          onTap: reopenable && _session.canReopen(e.source)
              ? () => _session.reopenConfirmForSource(e.source)
              : null,
          child: Padding(
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
              // Matched artwork (poster / album cover) right on the
              // row — an auto-accepted match must be seen, not taken
              // on faith.
              if (e.art != null && File(e.art!).existsSync()) ...[
                const SizedBox(width: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: Image.file(File(e.art!),
                      height: 34, fit: BoxFit.contain),
                ),
              ],
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
        ),
    ];
  }

  // ── uploading ────────────────────────────────────────────────────────

  List<Widget> _uploadingChildren(WiTokens t) {
    final job = _session.currentJob;
    final encoding = _session.encodeFraction;
    final phase = job?.phase ?? 'starting';
    final total = job?.total ?? 0;
    final done = job?.done ?? 0;
    final label = encoding != null
        ? 'Encoding · ${(encoding * 100).round()}%'
        : switch (phase) {
            'starting' => 'Starting upload…',
            'encrypting' => 'Encrypting file…',
            'quoting' =>
              'Getting storage quotes${total > 0 ? ' ($done of $total)' : '…'}',
            'paying' => 'Paying for storage…',
            'storing' =>
              'Storing chunks${total > 0 ? ' ($done of $total)' : '…'}',
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
        value: encoding ??
            (phase == 'storing' && total > 0 ? done / total : null),
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
            child: Text('Upload finished',
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
          'hand everything you uploaded to another device or person.',
          style: TextStyle(color: t.ash, fontSize: 12, height: 1.4),
        ),
      const SizedBox(height: 16),
      if (uploaded.isNotEmpty) ...[
        // The list was chosen on the setup page, so the batch added
        // itself there — report the result instead of asking again.
        if (_session.autoAddedList != null)
          Row(
            children: [
              Icon(Icons.check_circle_outline,
                  color: t.signalOk, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Added ${_session.autoAddedCount} '
                  '${_session.autoAddedCount == 1 ? 'title' : 'titles'} '
                  'to "${_session.autoAddedList}".',
                  style: TextStyle(color: t.bone, fontSize: 13),
                ),
              ),
            ],
          )
        else
          FilledButton.icon(
            onPressed: () => _addAllToLibrary(),
            icon: const Icon(Icons.video_library_outlined),
            label:
                Text('Add to "${_session.manifest?.listName ?? 'library'}"'),
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
        onPressed: () {
          _session.clear();
          // Done means done — back to the home wall, not the upload
          // stack.
          Navigator.of(context).popUntil((route) => route.isFirst);
        },
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
          videoInfo: _session.videoInfoByName[e.name!],
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
