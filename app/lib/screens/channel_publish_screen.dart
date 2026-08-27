import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/media_list.dart';
import '../services/channel_service.dart';
import '../services/ffmpeg.dart';
import '../services/library_store.dart';
import '../services/publish_api.dart';
import '../services/publish_plan.dart';
import '../theme/tokens.dart';
import '../widgets/channel_badge.dart';
import 'channels_screen.dart' show ChannelAttestationDialog;
import 'describe_item_screen.dart';
import 'publish_screen.dart'
    show addEntriesToLists, pickTargetLists;
import 'wallet_screen.dart';

/// Publish an item to the channel, starting from a FILE — the Upload
/// flow's shape applied to the public space: pick one local file, choose
/// the qualities to encode (bundled ffmpeg, same tiers as Upload),
/// describe it for subscribers (required — with the Check TMDB helper
/// for known films), attest the rights, then encode + upload.
///
/// Finished uploads are STAGED on the channel's item list; nothing is
/// public until "Publish update" ships the signed manifest (the uploads
/// themselves are private-visibility — their data maps only leave this
/// computer inside the manifest). One file per pass on purpose: channel
/// items enter one explicit pick at a time, there is no bulk publish.
class ChannelPublishScreen extends StatefulWidget {
  const ChannelPublishScreen({
    super.key,
    this.apiBase,
    this.apiToken,
    this.ffmpeg,
    this.postersDirProvider,
  });

  /// Test overrides for the embedded server base URL / auth token.
  final String? apiBase;
  final String? apiToken;

  /// Test override for the ffmpeg integration.
  final FfmpegService? ffmpeg;

  /// Posters directory override, forwarded to the describe page (tests).
  final Future<Directory> Function()? postersDirProvider;

  @override
  State<ChannelPublishScreen> createState() => _ChannelPublishScreenState();
}

enum _Stage { setup, running, done }

enum _EntryStatus { pending, encoding, uploading, done, error, skipped }

enum _ErrorAction { retry, skip, stop }

class _QueueEntry {
  _QueueEntry(this.item);
  final PublishItem item;
  _EntryStatus status = _EntryStatus.pending;
  double? encodeFraction;
  UploadJob? job;
  UploadResult? result;
  String? error;
  String? tempPath;
}

class _ChannelPublishScreenState extends State<ChannelPublishScreen> {
  late final PublishApi _api =
      PublishApi(base: widget.apiBase, token: widget.apiToken);
  late final FfmpegService _ffmpeg = widget.ffmpeg ?? FfmpegService();

  WalletStatus? _wallet;
  bool? _ffmpegAvailable;

  _Stage _stage = _Stage.setup;
  XFile? _file;
  int _fileSize = 0;
  MediaProbe? _probe;
  bool _picking = false;
  Set<PublishTier> _selection = {};
  UploadEstimate? _refEstimate;
  bool _estimating = false;
  String? _estimateError;
  bool _described = false;

  List<_QueueEntry> _queue = [];
  int _current = 0;
  Completer<_ErrorAction>? _errorAction;
  Directory? _tempDir;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _loadWallet();
    _ffmpeg.available.then((ok) {
      if (mounted) setState(() => _ffmpegAvailable = ok);
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _ffmpeg.cancel();
    if (!(_errorAction?.isCompleted ?? true)) {
      _errorAction!.complete(_ErrorAction.stop);
    }
    _cleanupTempDir();
    super.dispose();
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

  PublishSource? get _source {
    final file = _file;
    if (file == null) return null;
    return PublishSource(
        path: file.path, name: file.name, size: _fileSize, probe: _probe);
  }

  Future<void> _pickFile() async {
    final file = await openFile(acceptedTypeGroups: [
      const XTypeGroup(label: 'Media files', extensions: [
        'mp4', 'mkv', 'webm', 'avi', 'mov', 'm4v',
        'mp3', 'flac', 'm4a', 'ogg', 'opus', 'wav',
      ]),
      const XTypeGroup(label: 'All files'),
    ]);
    if (file == null || !mounted) return;
    setState(() => _picking = true);
    final size = await file.length();
    final probe = await _ffmpeg.probe(file.path);
    if (!mounted) return;
    setState(() {
      _picking = false;
      _file = file;
      _fileSize = size;
      _probe = probe;
      _selection = defaultTiers(probe).toSet();
      // A new file needs its own description.
      _described = false;
    });
    await _estimateCost();
  }

  void _removeFile() {
    setState(() {
      _file = null;
      _fileSize = 0;
      _probe = null;
      _selection = {};
      _described = false;
      _refEstimate = null;
      _estimateError = null;
    });
  }

  Future<void> _estimateCost() async {
    final file = _file;
    if (file == null) return;
    setState(() {
      _estimating = true;
      _estimateError = null;
    });
    try {
      final estimate = await _api.estimate(file.path);
      if (mounted) setState(() => _refEstimate = estimate);
    } catch (e) {
      if (mounted) setState(() => _estimateError = '$e');
    } finally {
      if (mounted) setState(() => _estimating = false);
    }
  }

  Future<void> _describe() async {
    final file = _file;
    if (file == null) return;
    final done = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => DescribeItemScreen(
        fileName: file.name,
        localPath: file.path,
        ffmpeg: widget.ffmpeg,
        postersDirProvider: widget.postersDirProvider,
      ),
    ));
    if (done == true && mounted) setState(() => _described = true);
  }

  List<PublishItem> _plannedQueue() {
    final source = _source;
    if (source == null) return const [];
    return buildQueue([source], _selection);
  }

  BigInt? _approxTotalCost(List<PublishItem> queue) {
    final ref = _refEstimate;
    if (ref == null) return null;
    var total = BigInt.zero;
    for (final item in queue) {
      final bytes = item.predictedBytes ?? item.source.size;
      total += approxCostAtto(bytes, ref.costAtto, ref.chunkCount);
    }
    return total;
  }

  bool get _canPublish =>
      _stage == _Stage.setup &&
      !_picking &&
      (_wallet?.configured ?? false) &&
      _refEstimate != null &&
      _described &&
      _plannedQueue().isNotEmpty;

  Future<void> _publish() async {
    final file = _file;
    final queue = _plannedQueue();
    if (file == null || queue.isEmpty) return;
    // The per-item rights attestation — the channel wall, stronger than
    // Upload's checkbox, because this content is headed for the public.
    final attested = await showDialog<bool>(
      context: context,
      builder: (_) => ChannelAttestationDialog(entryName: file.name),
    );
    if (attested != true || !mounted) return;
    if (queue.any((i) => i.needsEncode)) {
      // Sync on purpose: async file IO never completes in the widget
      // tests' fake-async zone, and this is a one-off cheap call.
      _tempDir = Directory.systemTemp.createTempSync('watchit-channel');
    }
    setState(() {
      _queue = [for (final item in queue) _QueueEntry(item)];
      _current = 0;
      _stage = _Stage.running;
    });
    unawaited(_run());
  }

  Future<void> _run() async {
    for (var i = 0; i < _queue.length; i++) {
      if (_disposed) return;
      final entry = _queue[i];
      if (mounted) setState(() => _current = i);
      var done = false;
      while (!done) {
        try {
          await _runEntry(entry);
          done = true;
        } catch (e) {
          if (_disposed || !mounted) return;
          setState(() {
            entry.status = _EntryStatus.error;
            entry.error = '$e';
          });
          _errorAction = Completer<_ErrorAction>();
          final action = await _errorAction!.future;
          _errorAction = null;
          if (_disposed || !mounted) return;
          switch (action) {
            case _ErrorAction.retry:
              setState(() => entry.error = null);
            case _ErrorAction.skip:
              setState(() => entry.status = _EntryStatus.skipped);
              done = true;
            case _ErrorAction.stop:
              _finishRun(markRemainingSkipped: true);
              return;
          }
        }
      }
    }
    _finishRun();
  }

  Future<void> _runEntry(_QueueEntry entry) async {
    final item = entry.item;
    var uploadPath = item.source.path;
    if (item.needsEncode) {
      // A retry after an upload failure reuses the finished encode.
      final existing = entry.tempPath;
      if (existing != null && File(existing).existsSync()) {
        uploadPath = existing;
      } else {
        if (mounted) {
          setState(() {
            entry.status = _EntryStatus.encoding;
            entry.encodeFraction = null;
          });
        }
        final output =
            '${_tempDir!.path}${Platform.pathSeparator}${item.outputName}';
        await _ffmpeg.encode(
          input: item.source.path,
          output: output,
          tier: item.tier,
          probe: item.source.probe,
          onProgress: (fraction) {
            if (mounted) setState(() => entry.encodeFraction = fraction);
          },
        );
        if (_disposed) throw FfmpegException('cancelled');
        entry.tempPath = output;
        uploadPath = output;
      }
    }
    if (mounted) {
      setState(() {
        entry.status = _EntryStatus.uploading;
        entry.job = null;
      });
    }
    final id = await _api.startUpload(uploadPath, name: item.outputName);
    while (true) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (_disposed) return;
      UploadJob job;
      try {
        job = await _api.jobStatus(id);
      } catch (_) {
        continue; // Transient poll failure — next tick retries.
      }
      if (mounted) setState(() => entry.job = job);
      final result = job.result;
      if (job.phase == 'done' && result != null) {
        // Straight onto the channel's staged item list — that is what
        // this whole flow is for (dedup by address inside).
        await ChannelService.instance.addMyItem(MediaEntry(
          name: item.outputName,
          address: result.address,
          sizeBytes: result.size,
          videoInfo: tierVideoInfo(item.source.probe, item.tier),
        ));
        if (mounted) {
          setState(() {
            entry.result = result;
            entry.status = _EntryStatus.done;
          });
        }
        _deleteTemp(entry);
        return;
      }
      if (job.phase == 'error') {
        throw PublishApiException(job.error ?? 'upload failed');
      }
    }
  }

  void _finishRun({bool markRemainingSkipped = false}) {
    if (!mounted) return;
    setState(() {
      if (markRemainingSkipped) {
        for (final entry in _queue) {
          if (entry.status == _EntryStatus.pending ||
              entry.status == _EntryStatus.error) {
            entry.status = _EntryStatus.skipped;
          }
        }
      }
      _stage = _Stage.done;
    });
    _cleanupTempDir();
  }

  void _deleteTemp(_QueueEntry entry) {
    final path = entry.tempPath;
    if (path == null) return;
    entry.tempPath = null;
    try {
      File(path).deleteSync();
    } catch (_) {}
  }

  void _cleanupTempDir() {
    final dir = _tempDir;
    _tempDir = null;
    if (dir == null) return;
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }

  void _reset() {
    setState(() {
      _stage = _Stage.setup;
      _file = null;
      _fileSize = 0;
      _probe = null;
      _selection = {};
      _refEstimate = null;
      _estimateError = null;
      _described = false;
      _queue = [];
      _current = 0;
    });
  }

  List<_QueueEntry> get _published =>
      [for (final e in _queue) if (e.result != null) e];

  /// The optional add-to-library leg the user asked for: the staged
  /// uploads can also join a normal (private, blue) library list of
  /// choice — same picker as the Upload done page.
  Future<void> _addAllToLibrary() async {
    final published = _published;
    if (published.isEmpty) return;
    final lists = await LibraryStore.load();
    if (!mounted) return;
    final chosen = await pickTargetLists(context, lists);
    if (chosen == null || chosen.isEmpty) return;
    final entries = [
      for (final e in published)
        MediaEntry(
          name: e.item.outputName,
          address: e.result!.address,
          sizeBytes: e.result!.size,
          videoInfo: tierVideoInfo(e.item.source.probe, e.item.tier),
        ),
    ];
    await addEntriesToLists(entries, chosen);
    _snack('Added ${entries.length} '
        '${entries.length == 1 ? 'version' : 'versions'} to '
        '${chosen.length == 1 ? chosen.first : '${chosen.length} lists'}');
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
        title: Row(
          children: [
            Text('Publish an item',
                style: TextStyle(color: t.bone, fontSize: 18)),
            const SizedBox(width: 10),
            const ChannelBadge(text: 'PUBLIC'),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: switch (_stage) {
          _Stage.setup => _setupChildren(t),
          _Stage.running => _runningChildren(t),
          _Stage.done => _doneChildren(t),
        },
      ),
    );
  }

  // ── setup ────────────────────────────────────────────────────────────

  Widget _header(WiTokens t, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 20, 0, 6),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11,
            letterSpacing: 1.5,
            fontWeight: FontWeight.w700,
            color: t.ash,
          ),
        ),
      );

  List<Widget> _setupChildren(WiTokens t) {
    final queue = _plannedQueue();
    return [
      Text(
        'Add an item to your channel straight from a file on this '
        'computer: it is encoded into the qualities you pick, described '
        'for subscribers, and uploaded. The uploads stay staged — '
        'nothing becomes public until you press "Publish update" on the '
        'channel page.',
        style: TextStyle(color: t.boneDim, fontSize: 13, height: 1.4),
      ),
      const SizedBox(height: 8),
      Text(
        'Once published, channel content is PUBLIC and PERMANENT — it '
        'can never be deleted from the network.',
        style: TextStyle(
            color: WiTokens.channelAmber, fontSize: 12.5, height: 1.4),
      ),
      const SizedBox(height: 16),
      _walletRow(t),
      if (_ffmpegAvailable == false) ...[
        const SizedBox(height: 12),
        Text(
          'ffmpeg was not found beside the app, so quality tiers are '
          'unavailable — the file can only be uploaded as-is.',
          style: TextStyle(color: t.rust, fontSize: 12, height: 1.4),
        ),
      ],
      const SizedBox(height: 16),
      ..._fileSection(t),
      if (_file != null && !_picking) ...[
        ..._tierSection(t),
        _header(t, 'DESCRIBE — WHAT SUBSCRIBERS SEE'),
        ..._describeSection(t),
        const SizedBox(height: 16),
        _estimateSection(t, queue),
        const SizedBox(height: 16),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: WiTokens.channelAmber,
            foregroundColor: Colors.black,
            disabledBackgroundColor: t.ink2,
          ),
          onPressed: _canPublish ? _publish : null,
          icon: const Icon(Icons.cloud_upload_outlined),
          label: Text(queue.length <= 1
              ? 'Encode & upload for the channel'
              : 'Encode & upload ${queue.length} versions'),
        ),
        if (!_canPublish && _file != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              [
                if (!(_wallet?.configured ?? false)) 'a wallet',
                if (!_described) 'the description',
                if (queue.isEmpty) 'at least one quality',
                if (_refEstimate == null && _estimateError == null)
                  'the cost estimate',
                if (_estimateError != null) 'a working cost estimate',
              ].isEmpty
                  ? ''
                  : 'Still needed: '
                      '${[
                      if (!(_wallet?.configured ?? false)) 'a wallet',
                      if (!_described) 'the description',
                      if (queue.isEmpty) 'at least one quality',
                      if (_refEstimate == null && _estimateError == null)
                        'the cost estimate',
                      if (_estimateError != null)
                        'a working cost estimate',
                    ].join(', ')}',
              style: TextStyle(color: t.ash, fontSize: 12),
            ),
          ),
      ],
    ];
  }

  List<Widget> _fileSection(WiTokens t) {
    final file = _file;
    if (file == null && !_picking) {
      return [
        OutlinedButton.icon(
          onPressed: _pickFile,
          icon: const Icon(Icons.insert_drive_file_outlined),
          label: const Text('Choose a file'),
        ),
        const SizedBox(height: 6),
        Text(
          'One item per pass — channel items are added one explicit '
          'pick at a time. Name the file like "Title (Year).mp4" so it '
          'displays well.',
          style: TextStyle(color: t.ash, fontSize: 12, height: 1.4),
        ),
      ];
    }
    if (_picking) {
      return [
        Row(
          children: [
            const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 10),
            Text('Reading file…',
                style: TextStyle(color: t.ash, fontSize: 13)),
          ],
        ),
      ];
    }
    return [
      ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.insert_drive_file_outlined,
            color: WiTokens.channelAmber, size: 20),
        title: Text(
          '${file!.name} · ${formatBytes(_fileSize)}',
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: t.bone, fontSize: 14),
        ),
        subtitle: Text(
          probeVerdict(_probe),
          style: TextStyle(color: t.ash, fontSize: 12),
        ),
        trailing: IconButton(
          tooltip: 'Remove',
          icon: Icon(Icons.close, color: t.ash, size: 18),
          onPressed: _removeFile,
        ),
      ),
    ];
  }

  List<Widget> _tierSection(WiTokens t) {
    final source = _source;
    if (source == null) return const [];
    final offered = source.offered;
    // Best encode tiers first, Original last — matches the queue order.
    final ordered = [
      ...kEncodeTierOrder.where(offered.contains),
      if (offered.contains(PublishTier.original)) PublishTier.original,
    ];
    if (ordered.length == 1 && ordered.single == PublishTier.original) {
      // Nothing to choose — the file goes up as-is.
      return const [];
    }
    return [
      _header(t, 'QUALITY'),
      Text(
        'Subscribers\' devices and connections vary — smaller versions '
        'play smoothly where the full-quality file can\'t. Each ticked '
        'quality is encoded and uploaded; they show as one channel item '
        'with a version picker.',
        style: TextStyle(color: t.ash, fontSize: 12, height: 1.4),
      ),
      for (final tier in ordered) _tierTile(t, tier),
    ];
  }

  Widget _tierTile(WiTokens t, PublishTier tier) {
    final bytes = predictedSizeBytes(_probe, tier, _fileSize);
    final ref = _refEstimate;
    final cost = ref == null || bytes == null
        ? null
        : approxCostAtto(bytes, ref.costAtto, ref.chunkCount);
    final spec = kTierSpecs[tier];
    final title = tier == PublishTier.original
        ? 'Original file (as-is)'
        : '${spec!.name} · ${spec.label} H.264';
    final details = [
      if (bytes != null) '≈${formatBytes(bytes)}',
      if (cost != null) '≈${formatUnits(cost)} ANT',
    ].join(' · ');
    return CheckboxListTile(
      dense: true,
      value: _selection.contains(tier),
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      activeColor: WiTokens.channelAmber,
      checkColor: Colors.black,
      title: Text(title, style: TextStyle(color: t.bone, fontSize: 14)),
      subtitle: details.isEmpty
          ? null
          : Text(details, style: TextStyle(color: t.ash, fontSize: 12)),
      onChanged: (v) => setState(() {
        v == true ? _selection.add(tier) : _selection.remove(tier);
      }),
    );
  }

  List<Widget> _describeSection(WiTokens t) {
    if (_described) {
      return [
        Row(
          children: [
            Icon(Icons.check_circle_outline, color: t.signalOk, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Described for subscribers ✓',
                  style: TextStyle(color: t.bone, fontSize: 13.5)),
            ),
            TextButton(
              onPressed: _describe,
              child: Text('Edit', style: TextStyle(color: t.ash)),
            ),
          ],
        ),
      ];
    }
    return [
      Text(
        'Title, description and artwork are required — subscribers only '
        'see what you write. Known films can be filled in from TMDB.',
        style: TextStyle(color: t.ash, fontSize: 12, height: 1.4),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: _describe,
        icon: const Icon(Icons.edit_note, color: WiTokens.channelAmber),
        label: const Text('Describe this item',
            style: TextStyle(color: WiTokens.channelAmber)),
      ),
    ];
  }

  Widget _estimateSection(WiTokens t, List<PublishItem> queue) {
    if (_estimating) {
      return Row(
        children: [
          const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 10),
          Text('Getting storage quotes from the network…',
              style: TextStyle(color: t.ash, fontSize: 13)),
        ],
      );
    }
    final error = _estimateError;
    if (error != null) {
      return Row(
        children: [
          Expanded(
            child: Text('Estimate failed: $error',
                style: TextStyle(color: t.rust, fontSize: 13)),
          ),
          TextButton(
            onPressed: _estimateCost,
            child: const Text('Retry',
                style: TextStyle(color: WiTokens.channelAmber)),
          ),
        ],
      );
    }
    final total = _approxTotalCost(queue);
    if (total == null) return const SizedBox.shrink();
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
          Text(
            '${queue.length} ${queue.length == 1 ? 'upload' : 'uploads'} · '
            'estimated cost ≈${formatUnits(total)} ANT',
            style: TextStyle(
                color: t.bone, fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            'Estimated from live network quotes; encoded sizes are '
            'predictions. Publishing the channel update afterwards is a '
            'separate, small manifest upload with its own cost preview.',
            style: TextStyle(color: t.ash, fontSize: 12, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _walletRow(WiTokens t) {
    final wallet = _wallet;
    if (wallet == null) {
      return Text('Checking wallet…',
          style: TextStyle(color: t.ash, fontSize: 13));
    }
    if (!wallet.configured) {
      return Row(
        children: [
          Icon(Icons.account_balance_wallet_outlined,
              color: t.rust, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text('No wallet set up yet',
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
      );
    }
    final address = wallet.address ?? '';
    final short = address.length > 12
        ? '${address.substring(0, 8)}…${address.substring(address.length - 4)}'
        : address;
    return Row(
      children: [
        Icon(Icons.account_balance_wallet_outlined,
            color: t.signalOk, size: 20),
        const SizedBox(width: 8),
        Text('Wallet ready · ',
            style: TextStyle(color: t.boneDim, fontSize: 13)),
        Text(
          short,
          style: TextStyle(
            fontFamily: wiMonoFamily,
            fontFamilyFallback: wiMonoFallback,
            fontSize: 12,
            color: WiTokens.channelAmber,
          ),
        ),
      ],
    );
  }

  // ── running ──────────────────────────────────────────────────────────

  List<Widget> _runningChildren(WiTokens t) {
    final finished = _queue
        .where((e) =>
            e.status == _EntryStatus.done || e.status == _EntryStatus.skipped)
        .length;
    final entry =
        _current < _queue.length ? _queue[_current] : _queue.last;
    return [
      Text(
        'Uploading for the channel · task '
        '${(_current + 1).clamp(1, _queue.length)} of ${_queue.length}',
        style: TextStyle(
            color: t.bone, fontSize: 16, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      LinearProgressIndicator(
        value: _queue.isEmpty ? null : finished / _queue.length,
        backgroundColor: t.ink2,
      ),
      const SizedBox(height: 16),
      if (entry.status == _EntryStatus.error)
        ..._entryErrorSection(t, entry)
      else
        ..._entryProgressSection(t, entry),
      const SizedBox(height: 4),
      Text(
        'Keep W@tch open until uploading finishes. Nothing is public '
        'yet — that happens at "Publish update".',
        style: TextStyle(color: t.ash, fontSize: 12),
      ),
      const SizedBox(height: 16),
      for (final e in _queue)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Icon(
                switch (e.status) {
                  _EntryStatus.pending => Icons.schedule,
                  _EntryStatus.encoding => Icons.movie_filter_outlined,
                  _EntryStatus.uploading => Icons.cloud_upload_outlined,
                  _EntryStatus.done => Icons.check_circle_outline,
                  _EntryStatus.error => Icons.error_outline,
                  _EntryStatus.skipped => Icons.remove_circle_outline,
                },
                size: 16,
                color: switch (e.status) {
                  _EntryStatus.done => t.signalOk,
                  _EntryStatus.error => t.rust,
                  _EntryStatus.pending || _EntryStatus.skipped => t.ash,
                  _ => WiTokens.channelAmber,
                },
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  e.item.outputName,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: e.status == _EntryStatus.skipped
                          ? t.ash
                          : t.boneDim,
                      fontSize: 13),
                ),
              ),
            ],
          ),
        ),
    ];
  }

  List<Widget> _entryProgressSection(WiTokens t, _QueueEntry entry) {
    final String label;
    double? fraction;
    if (entry.status == _EntryStatus.encoding) {
      fraction = entry.encodeFraction;
      label = 'Encoding ${tierLabel(entry.item.source.probe, entry.item.tier)}'
          '${fraction == null ? '…' : ' · ${(fraction * 100).round()}%'}';
    } else {
      final job = entry.job;
      final phase = job?.phase ?? 'starting';
      final total = job?.total ?? 0;
      final done = job?.done ?? 0;
      label = switch (phase) {
        'starting' => 'Starting upload…',
        'encrypting' => 'Encrypting file…',
        'quoting' =>
          'Getting storage quotes${total > 0 ? ' ($done of $total)' : '…'}',
        'paying' => 'Paying for storage…',
        'storing' =>
          'Storing chunks${total > 0 ? ' ($done of $total)' : '…'}',
        _ => phase,
      };
      fraction =
          phase == 'storing' && total > 0 ? done / total : null;
    }
    return [
      Text(
        entry.item.outputName,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: t.bone, fontSize: 14),
      ),
      const SizedBox(height: 8),
      LinearProgressIndicator(value: fraction, backgroundColor: t.ink2),
      const SizedBox(height: 8),
      Text(label, style: TextStyle(color: t.boneDim, fontSize: 13)),
    ];
  }

  List<Widget> _entryErrorSection(WiTokens t, _QueueEntry entry) {
    return [
      Text(
        '${entry.item.outputName} failed',
        style: TextStyle(
            color: t.rust, fontSize: 14, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 4),
      Text(entry.error ?? 'unknown error',
          style: TextStyle(color: t.boneDim, fontSize: 13)),
      const SizedBox(height: 12),
      Wrap(
        spacing: 12,
        children: [
          FilledButton(
            onPressed: () => _errorAction?.complete(_ErrorAction.retry),
            child: const Text('Try again'),
          ),
          OutlinedButton(
            onPressed: () => _errorAction?.complete(_ErrorAction.skip),
            child: const Text('Skip this version'),
          ),
          TextButton(
            onPressed: () => _errorAction?.complete(_ErrorAction.stop),
            child: Text('Stop', style: TextStyle(color: t.ash)),
          ),
        ],
      ),
    ];
  }

  // ── done ─────────────────────────────────────────────────────────────

  List<Widget> _doneChildren(WiTokens t) {
    final published = _published;
    final failed =
        _queue.where((e) => e.status == _EntryStatus.error).length;
    final skipped =
        _queue.where((e) => e.status == _EntryStatus.skipped).length;
    var paid = BigInt.zero;
    for (final e in published) {
      paid += e.result!.costAtto;
    }
    final allGood = failed == 0 && skipped == 0;
    return [
      Row(
        children: [
          Icon(
            allGood && published.isNotEmpty
                ? Icons.check_circle_outline
                : Icons.info_outline,
            color: allGood && published.isNotEmpty ? t.signalOk : t.rust,
            size: 28,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Staged for the channel',
              style: TextStyle(
                  color: t.bone, fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Text(
        '${published.length} of ${_queue.length} uploads finished · '
        'paid ${formatUnits(paid)} ANT'
        '${skipped > 0 ? ' · $skipped skipped' : ''}'
        '${failed > 0 ? ' · $failed failed' : ''}',
        style: TextStyle(color: t.boneDim, fontSize: 13),
      ),
      const SizedBox(height: 16),
      for (final entry in published) _publishedTile(t, entry),
      const SizedBox(height: 8),
      Text(
        'The ${published.length == 1 ? 'upload is' : 'uploads are'} on '
        'the channel\'s item list now, but still private. Press '
        '"Publish update" on the channel page to make the new version '
        'public — permanently.',
        style: const TextStyle(
            color: WiTokens.channelAmber, fontSize: 12.5, height: 1.4),
      ),
      const SizedBox(height: 20),
      if (published.isNotEmpty) ...[
        OutlinedButton.icon(
          onPressed: _addAllToLibrary,
          icon: const Icon(Icons.video_library_outlined),
          label: const Text('Also add to my library'),
        ),
        const SizedBox(height: 10),
      ],
      FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: WiTokens.channelAmber,
          foregroundColor: Colors.black,
        ),
        onPressed: () => Navigator.of(context).pop(true),
        icon: const Icon(Icons.check),
        label: const Text('Back to the channel'),
      ),
      const SizedBox(height: 8),
      TextButton(
        onPressed: _reset,
        child:
            Text('Publish another item', style: TextStyle(color: t.ash)),
      ),
    ];
  }

  Widget _publishedTile(WiTokens t, _QueueEntry entry) {
    final result = entry.result!;
    final address = result.address;
    final short = address.length > 16
        ? '${address.substring(0, 10)}…${address.substring(address.length - 6)}'
        : address;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(Icons.check_circle_outline, color: t.signalOk, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.item.outputName,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.bone, fontSize: 13),
                ),
                Text(
                  '${formatBytes(result.size)} · ${result.chunks} chunks · '
                  '${formatUnits(result.costAtto)} ANT · $short',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: t.ash,
                    fontSize: 11,
                    fontFamily: wiMonoFamily,
                    fontFamilyFallback: wiMonoFallback,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Copy address',
            icon: Icon(Icons.copy, color: t.ash, size: 16),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: address));
              _snack('Address copied');
            },
          ),
        ],
      ),
    );
  }
}
