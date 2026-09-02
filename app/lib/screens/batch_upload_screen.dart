import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:watchit_upload/watchit_upload.dart' hide MediaProbe;

import '../models/media_list.dart';
import '../services/app_settings.dart';
import '../services/batch_upload.dart';
import '../services/default_list.dart';
import '../services/ffmpeg.dart' show FfmpegService;
import '../services/library_store.dart';
import '../services/publish_plan.dart' as plan;
import '../services/publish_api.dart';
import '../theme/tokens.dart';
import '../widgets/match_review_cards.dart';
import 'publish_screen.dart' show isDesktopPlatform, pickTargetLists;
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
    this.resumeDir,
    this.ffmpegOverride,
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

  /// When set, the screen immediately continues this interrupted batch
  /// (the startup resume prompt's "Continue upload"): it reopens at its
  /// review page with already-uploaded files kept.
  final Directory? resumeDir;

  /// Test override for the ffmpeg wrapper (a real one spawns processes
  /// that hang the fake-async zone).
  final FfmpegService? ffmpegOverride;

  @override
  State<BatchUploadScreen> createState() => _BatchUploadScreenState();
}

class _BatchUploadScreenState extends State<BatchUploadScreen> {
  late final PublishApi _api =
      PublishApi(base: widget.apiBase, token: widget.apiToken);
  final BatchUploadSession _session = BatchUploadSession.instance;

  final List<String> _paths = [];

  /// The batch's target list — names the .watch-list bundle and is the
  /// done page's add-to-library default. Defaults by media type:
  /// "Music" / "TV Shows" / "Movies" ([defaultBatchList]); a manual
  /// pick from the dropdown sticks.
  String _list = 'My uploads';
  bool _listChosen = false;
  List<String> _libraryLists = [];
  WalletStatus? _wallet;
  List<PreviousBatch> _previous = [];
  bool _rights = false;
  late BatchStage _lastStage = _session.stage;

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSession);
    _loadWallet();
    _loadLists();
    _loadAttention();
    final resume = widget.resumeDir;
    if (resume != null) {
      scheduleMicrotask(() => _resumeFromDir(resume));
    }
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

  /// Re-derive the default list from what's picked so far: mostly
  /// audio lands in "Music", mostly episodes in "TV Shows", other
  /// video in "Movies".
  void _updateDefaultList() {
    if (_listChosen) return;
    _list = defaultBatchList(_paths, fallback: _list);
  }

  Future<Directory> _batchRoot() async => widget.batchRootProvider != null
      ? widget.batchRootProvider!()
      : Directory(p.join(
          (await getApplicationSupportDirectory()).path, 'batch_uploads'));

  /// Earlier batches still needing work. Fully finished batches are
  /// swept away first (their work dirs hold nothing load-bearing), so
  /// only unfinished ones surface.
  Future<void> _loadAttention() async {
    try {
      final root = await _batchRoot();
      // The live session's dir must survive: at the done stage it looks
      // finished while the done page still serves its bundle.
      await deleteFinishedBatches(root,
          keepPath: _session.workDir?.path);
      final batches = await scanPreviousBatches(root);
      if (mounted) {
        setState(() =>
            _previous = [for (final b in batches) if (!b.finished) b]);
      }
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
      ffmpeg: widget.ffmpegOverride ?? FfmpegService(),
    );
  }

  /// Continue an interrupted batch: reopen it at its review page —
  /// already-uploaded files are skipped, the rest upload from there.
  Future<void> _continueBatch(PreviousBatch batch) =>
      _resumeFromDir(batch.workDir);

  Future<void> _resumeFromDir(Directory dir) async {
    if (!_session.idle) return;
    await _session.resumeBatch(
      api: _api,
      workDir: dir,
      ffprobeBin: locateFfprobeBin(),
      configDir: widget.configDir,
      ffmpeg: widget.ffmpegOverride ?? FfmpegService(),
    );
  }

  /// Dismiss: give up on the batch's needs-attention files (they flip
  /// to skipped, so with nothing left to do the batch counts as
  /// finished and the reload sweeps its records; the ledger keeps its
  /// uploads either way).
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
      ffmpeg: widget.ffmpegOverride ?? FfmpegService(),
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

  /// Earlier batches as a management list: files needing attention or
  /// an upload that was cut short, with Continue / Review / Dismiss /
  /// Delete. Fully finished batches never appear — they are swept
  /// automatically (library entries and network uploads untouched).
  Widget _previousUploadsCard(WiTokens t) {
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
          for (final batch in _previous) _previousBatchRow(t, batch),
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
            _session.currentFile != null) ...[
          Text(_session.currentFile!,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: t.boneDim, fontSize: 13)),
          // Per-file step: the fingerprint read of a big movie takes
          // tens of seconds — without its own moving bar + explanation
          // the screen looks hung on "1 of 1".
          if (_session.prepareStep == PrepareStep.fingerprint &&
              _session.hashFraction != null) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: _session.hashFraction,
              backgroundColor: t.ink2,
              minHeight: 2,
            ),
          ],
          if (_session.prepareStep != null) ...[
            const SizedBox(height: 6),
            Text(_prepareStepLine(),
                style: TextStyle(color: t.ash, fontSize: 12)),
          ],
        ],
      ],
      if (confirm != null) ...[
        const SizedBox(height: 12),
        MatchConfirmCard(session: _session, confirm: confirm),
      ],
      if (albumConfirm != null) ...[
        const SizedBox(height: 12),
        AlbumMatchConfirmCard(session: _session, confirm: albumConfirm),
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

  /// What the scan is doing to the current file, with the why for the
  /// slow leg — reading a whole movie for the fingerprint is what makes
  /// "movie data take ~20s to come through".
  String _prepareStepLine() {
    switch (_session.prepareStep!) {
      case PrepareStep.fingerprint:
        final f = _session.hashFraction;
        final pct = f == null ? '' : ' · ${(f * 100).round()}%';
        return 'Fingerprinting$pct — reading the whole file once so '
            'anything you already uploaded is recognised and never paid '
            'for twice. Large files take a while.';
      case PrepareStep.mediaInfo:
        return 'Reading media info (format, resolution, tags)…';
      case PrepareStep.match:
        final file = _session.currentFile;
        final audio = file != null &&
            kAudioExtensions.contains(p.extension(file).toLowerCase());
        return audio
            ? 'Looking it up on MusicBrainz…'
            : 'Looking it up on the movie database (TMDB)…';
    }
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
          'hand everything you uploaded to another device or person.'
          '${allGood ? ' Use "Save bundle to…" to keep a copy — a fully '
              'successful batch\'s working files are tidied away when '
              'you press Done.' : ''}',
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

/// The default target list for a batch of [paths] (files or folders),
/// by media type: "Music" when the files are mostly audio, "TV Shows"
/// when mostly episodes, else "Movies" ([defaultListForNames]).
/// [fallback] survives empty or unreadable picks.
String defaultBatchList(List<String> paths,
    {String fallback = 'My uploads'}) {
  try {
    final files = collectMediaFiles(paths);
    if (files.isEmpty) return fallback;
    return defaultListForNames([for (final f in files) p.basename(f)],
        fallback: fallback);
  } catch (_) {
    return fallback;
  }
}

bool _batchResumeOffered = false;

/// Test hook: re-arm the once-per-launch resume offer.
@visibleForTesting
void resetBatchResumeOffer() => _batchResumeOffered = false;

/// Test hook: where [offerBatchResume] scans for batch work dirs
/// (`<support>/batch_uploads` normally).
Future<Directory> Function()? batchResumeRootOverride;

/// Once per launch (from the home screen's first build): if a crash or
/// shutdown left a batch upload cut short, offer to continue it —
/// "Continue upload" opens the batch screen resuming the newest one
/// (or, with several waiting, at their management list). The same pass
/// sweeps fully finished batch records left behind by a crash on the
/// done page or by older versions. Desktop-only, like the batch
/// uploader itself; a silent no-op when nothing is interrupted.
Future<void> offerBatchResume(
  BuildContext context, {
  String? apiBase,
  String? apiToken,
  Directory? configDir,
  FfmpegService? ffmpegOverride,
}) async {
  if (_batchResumeOffered || !isDesktopPlatform) return;
  _batchResumeOffered = true;
  if (!BatchUploadSession.instance.idle) return;
  final List<PreviousBatch> interrupted;
  try {
    final root = batchResumeRootOverride != null
        ? await batchResumeRootOverride!()
        : Directory(p.join((await getApplicationSupportDirectory()).path,
            'batch_uploads'));
    await deleteFinishedBatches(root);
    interrupted = await scanInterruptedBatches(root);
  } catch (_) {
    return; // No support dir (tests) — nothing to offer.
  }
  if (interrupted.isEmpty || !context.mounted) return;
  final newest = interrupted.first;
  final waiting = newest.resumableSources.length;
  final t = WiTokens.of(context);
  final resume = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: t.ink2,
      title: Text('Finish an interrupted upload?',
          style: TextStyle(color: t.bone, fontSize: 16)),
      content: Text(
        interrupted.length == 1
            ? 'The upload batch "${newest.listName}" was cut short — '
                '$waiting ${waiting == 1 ? 'file' : 'files'} never made '
                'it up (W@tch closed or the computer shut down '
                'mid-upload). Continuing is safe: anything already '
                'uploaded is recognised and never paid for twice. You '
                'can also continue later from the Upload page.'
            : '${interrupted.length} upload batches were cut short '
                'before they finished. Continuing is safe: anything '
                'already uploaded is recognised and never paid for '
                'twice. You can also continue later from the Upload '
                'page.',
        style: TextStyle(color: t.boneDim, fontSize: 13, height: 1.4),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text('Not now', style: TextStyle(color: t.ash)),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Continue upload'),
        ),
      ],
    ),
  );
  if (resume != true || !context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => BatchUploadScreen(
      apiBase: apiBase,
      apiToken: apiToken,
      configDir: configDir,
      batchRootProvider: batchResumeRootOverride,
      resumeDir: interrupted.length == 1 ? newest.workDir : null,
      ffmpegOverride: ffmpegOverride,
    ),
  ));
}

/// The bundled ffprobe beside the executable (AppImage / Windows zip
/// ship one), falling back to PATH — FfmpegService's location rule.
String locateFfprobeBin() {
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final ext = Platform.isWindows ? '.exe' : '';
  final bundled = '$exeDir${Platform.pathSeparator}ffprobe$ext';
  return File(bundled).existsSync() ? bundled : 'ffprobe';
}
