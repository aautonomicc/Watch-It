import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../models/media_list.dart';
import '../services/embedded_client.dart';
import '../services/ffmpeg.dart';
import '../services/library_store.dart';
import '../services/publish_api.dart';
import '../services/publish_plan.dart';
import '../services/publish_session.dart';
import '../theme/tokens.dart';
import 'settings_screen.dart' show promptForText;
import 'wallet_screen.dart';

/// Upload: put media files on the Autonomi network from the app.
///
/// User-facing name is "Upload" (formerly "Publish" — renamed so the
/// word "publish" stays reserved for the genuinely-public Channels
/// feature; docs/PLAN-personal-vs-channels.md). Uploads are PRIVATE:
/// Visibility::Private keeps the datamap off the network. Internal
/// identifiers keep the Publish* names.
///
/// Multi-file edition — pick one file or a whole series, see per-file
/// probe verdicts, choose quality tiers (encoded with bundled ffmpeg;
/// H.264/AAC faststart MP4 that plays everywhere), confirm rights +
/// permanence, then the batch runs: each file × tier encodes and uploads
/// in turn, paid from the internal wallet. Results land in the library
/// like any import; same-title tiers fold into the version picker.
class PublishScreen extends StatefulWidget {
  const PublishScreen({super.key, this.apiBase, this.apiToken, this.ffmpeg});

  /// Test overrides for the embedded server base URL / auth token.
  final String? apiBase;
  final String? apiToken;

  /// Test override for the ffmpeg integration.
  final FfmpegService? ffmpeg;

  @override
  State<PublishScreen> createState() => _PublishScreenState();
}

class _PickedFile {
  _PickedFile(this.file, this.size, this.probe);
  final XFile file;
  final int size;
  final MediaProbe? probe;

  PublishSource get source => PublishSource(
      path: file.path, name: file.name, size: size, probe: probe);
}

class _PublishScreenState extends State<PublishScreen> {
  late final PublishApi _api =
      PublishApi(base: widget.apiBase, token: widget.apiToken);
  late final FfmpegService _ffmpeg = widget.ffmpeg ?? FfmpegService();

  /// The batch itself lives in this app-wide session, not the widget —
  /// leaving the page mid-upload loses nothing, and reopening it shows
  /// the batch where it stands.
  final PublishSession _session = PublishSession.instance;

  WalletStatus? _wallet;
  bool? _ffmpegAvailable;

  final List<_PickedFile> _files = [];
  bool _picking = false;
  Set<PublishTier> _selection = {};
  UploadEstimate? _refEstimate;
  bool _estimating = false;
  String? _estimateError;
  bool _rights = false;

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSession);
    _loadWallet();
    _ffmpeg.available.then((ok) {
      if (mounted) setState(() => _ffmpegAvailable = ok);
    });
  }

  @override
  void dispose() {
    _session.removeListener(_onSession);
    // A running batch encodes with this ffmpeg instance — leave it be;
    // only kill setup-stage probes.
    if (!identical(_session.ffmpegInUse, _ffmpeg)) _ffmpeg.cancel();
    super.dispose();
  }

  void _onSession() {
    if (mounted) setState(() {});
  }

  Future<void> _loadWallet() async {
    try {
      final status = await _api.walletStatus();
      if (mounted) setState(() => _wallet = status);
    } catch (_) {
      // Leave null — the wallet row shows setup guidance either way.
      if (mounted) {
        setState(() => _wallet = const WalletStatus(configured: false));
      }
    }
  }

  Future<void> _pickFiles() async {
    final files = await openFiles(acceptedTypeGroups: [
      const XTypeGroup(label: 'Media files', extensions: [
        'mp4', 'mkv', 'webm', 'avi', 'mov', 'm4v',
        'mp3', 'flac', 'm4a', 'ogg', 'opus', 'wav',
      ]),
      const XTypeGroup(label: 'All files'),
    ]);
    if (files.isEmpty || !mounted) return;
    setState(() => _picking = true);
    final hadFirst = _files.isNotEmpty;
    for (final file in files) {
      if (_files.any((f) => f.file.path == file.path)) continue;
      final size = await file.length();
      final probe = await _ffmpeg.probe(file.path);
      if (!mounted) return;
      _files.add(_PickedFile(file, size, probe));
    }
    setState(() {
      _picking = false;
      _selection = _defaultSelection();
      _rights = false;
    });
    if (!hadFirst || _refEstimate == null) await _estimateCost();
  }

  void _removeFile(_PickedFile file) {
    final wasFirst = _files.isNotEmpty && identical(_files.first, file);
    setState(() {
      _files.remove(file);
      _selection = _defaultSelection();
      _rights = false;
      if (_files.isEmpty) {
        _refEstimate = null;
        _estimateError = null;
      }
    });
    // The reference quote came from the removed file — refresh it.
    if (wasFirst && _files.isNotEmpty) unawaited(_estimateCost());
  }

  /// Default tier ticks: the union of every file's defaults, so a series
  /// mixing sources starts with each file's recommended tiers covered.
  Set<PublishTier> _defaultSelection() =>
      {for (final f in _files) ...defaultTiers(f.probe)};

  Future<void> _estimateCost() async {
    if (_files.isEmpty) return;
    setState(() {
      _estimating = true;
      _estimateError = null;
    });
    try {
      final estimate = await _api.estimate(_files.first.file.path);
      if (mounted) setState(() => _refEstimate = estimate);
    } catch (e) {
      if (mounted) setState(() => _estimateError = '$e');
    } finally {
      if (mounted) setState(() => _estimating = false);
    }
  }

  List<PublishItem> _plannedQueue() =>
      buildQueue([for (final f in _files) f.source], _selection);

  /// Files none of the selected qualities apply to — they would be
  /// skipped, so the setup stage calls them out.
  List<_PickedFile> _uncoveredFiles() => [
        for (final f in _files)
          if (!f.source.offered.any(_selection.contains)) f,
      ];

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
      _session.idle &&
      !_picking &&
      (_wallet?.configured ?? false) &&
      _refEstimate != null &&
      _rights &&
      _plannedQueue().isNotEmpty;

  void _publish() {
    final queue = _plannedQueue();
    if (queue.isEmpty || !_session.idle) return;
    _session.start(api: _api, ffmpeg: _ffmpeg, items: queue);
  }

  void _reset() {
    _session.clear();
    setState(() {
      _files.clear();
      _selection = {};
      _refEstimate = null;
      _estimateError = null;
      _rights = false;
    });
  }

  List<PublishQueueEntry> get _published => _session.published;

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
        '${entries.length == 1 ? 'title' : 'titles'} to '
        '${chosen.length == 1 ? chosen.first : '${chosen.length} lists'}');
  }

  Future<void> _saveAllDatamaps() async {
    final published = _published;
    if (published.isEmpty) return;
    final base = widget.apiBase ?? EmbeddedClient.baseUrl();
    if (base == null) return;
    final dirPath = await getDirectoryPath();
    if (dirPath == null) return;
    var saved = 0;
    for (final entry in published) {
      try {
        final res = await http
            .get(Uri.parse('$base/datamap/${entry.result!.address}'));
        if (res.statusCode != 200) continue;
        File('$dirPath${Platform.pathSeparator}'
                '${entry.item.outputName}.datamap')
            .writeAsBytesSync(res.bodyBytes);
        saved++;
      } catch (_) {}
    }
    _snack(saved == published.length
        ? 'Saved $saved .datamap ${saved == 1 ? 'file' : 'files'}'
        : 'Saved $saved of ${published.length} .datamap files');
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
        title: Text('Upload', style: TextStyle(color: t.bone, fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: switch (_session.stage) {
          PublishStage.idle => _setupChildren(t),
          PublishStage.running => _runningChildren(t),
          PublishStage.done => _doneChildren(t),
        },
      ),
    );
  }

  // ── setup ────────────────────────────────────────────────────────────

  List<Widget> _setupChildren(WiTokens t) {
    final queue = _plannedQueue();
    return [
      Text(
        'Upload media files to the Autonomi network — one file or a '
        'whole series at once. Uploads are private: only you and your '
        'linked devices can watch. Nothing is published.',
        style: TextStyle(color: t.boneDim, fontSize: 13, height: 1.4),
      ),
      const SizedBox(height: 8),
      Text(
        'Uploaded files are permanent — they cannot be edited or '
        'deleted — and storage is paid once, in ANT, from your wallet.',
        style: TextStyle(color: t.ash, fontSize: 12, height: 1.4),
      ),
      const SizedBox(height: 16),
      _walletRow(t),
      if (_ffmpegAvailable == false) ...[
        const SizedBox(height: 12),
        Text(
          'ffmpeg was not found beside the app, so quality tiers are '
          'unavailable — files can only be uploaded as-is.',
          style: TextStyle(color: t.rust, fontSize: 12, height: 1.4),
        ),
      ],
      const SizedBox(height: 16),
      ..._filesSection(t),
      if (_files.isNotEmpty && !_picking) ...[
        const SizedBox(height: 16),
        ..._tierSection(t),
        const SizedBox(height: 16),
        _estimateSection(t, queue),
        const SizedBox(height: 8),
        ..._uncoveredWarning(t),
        CheckboxListTile(
          value: _rights,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(
            'I have the right to upload '
            '${_files.length == 1 ? 'this file' : 'these files'} — '
            '${_files.length == 1 ? 'it is' : 'they are'} my own work, '
            'verifiably public domain, or a personal copy for private use.',
            style: TextStyle(color: t.bone, fontSize: 13),
          ),
          onChanged: (v) => setState(() => _rights = v ?? false),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _canPublish ? _publish : null,
          icon: const Icon(Icons.cloud_upload_outlined),
          label: Text(queue.length <= 1
              ? 'Upload'
              : 'Upload ${queue.length} files'),
        ),
      ],
    ];
  }

  List<Widget> _filesSection(WiTokens t) {
    if (_files.isEmpty && !_picking) {
      return [
        OutlinedButton.icon(
          onPressed: _pickFiles,
          icon: const Icon(Icons.insert_drive_file_outlined),
          label: const Text('Choose files to upload'),
        ),
        const SizedBox(height: 6),
        Text(
          'Select several files at once to upload a whole series — '
          'episodes named like "Show S01E02.mkv" group under one card '
          'in the library.',
          style: TextStyle(color: t.ash, fontSize: 12, height: 1.4),
        ),
      ];
    }
    return [
      Row(
        children: [
          Text(
            'FILES (${_files.length})',
            style: TextStyle(
                fontSize: 11,
                letterSpacing: 1.5,
                fontWeight: FontWeight.w700,
                color: t.ash),
          ),
          const Spacer(),
          if (!_picking)
            TextButton.icon(
              onPressed: _pickFiles,
              icon: const Icon(Icons.add, size: 16),
              label: Text('Add more', style: TextStyle(color: t.accent)),
            ),
        ],
      ),
      for (final file in _files)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.insert_drive_file_outlined,
              color: t.accent, size: 20),
          title: Text(
            '${file.file.name} · ${formatBytes(file.size)}',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: t.bone, fontSize: 14),
          ),
          subtitle: Text(
            probeVerdict(file.probe),
            style: TextStyle(color: t.ash, fontSize: 12),
          ),
          trailing: IconButton(
            tooltip: 'Remove',
            icon: Icon(Icons.close, color: t.ash, size: 18),
            onPressed: () => _removeFile(file),
          ),
        ),
      if (_picking)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 10),
              Text('Reading files…',
                  style: TextStyle(color: t.ash, fontSize: 13)),
            ],
          ),
        ),
    ];
  }

  List<Widget> _tierSection(WiTokens t) {
    final offered = <PublishTier>{
      for (final f in _files) ...f.source.offered,
    };
    // Best encode tiers first, Original last — matches the queue order.
    final ordered = [
      ...kEncodeTierOrder.where(offered.contains),
      if (offered.contains(PublishTier.original)) PublishTier.original,
    ];
    if (ordered.length == 1 && ordered.single == PublishTier.original) {
      // Nothing to choose — every file goes up as-is.
      return const [];
    }
    return [
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
        'encoded and uploaded for every file it applies to; your library '
        'shows one card with a version picker.',
        style: TextStyle(color: t.ash, fontSize: 12, height: 1.4),
      ),
      for (final tier in ordered) _tierTile(t, tier),
    ];
  }

  /// The full "why" story behind the quality tiers, one tap away from
  /// where the choice is made. The inline helper carries the one-line
  /// version; this covers the permanence angle that makes the choice
  /// matter (uploads can't be swapped for a better-encoded copy later).
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

  Widget _tierTile(WiTokens t, PublishTier tier) {
    final applicable = [
      for (final f in _files)
        if (f.source.offered.contains(tier)) f,
    ];
    var knownBytes = 0;
    var anyUnknown = false;
    for (final f in applicable) {
      final bytes = predictedSizeBytes(f.probe, tier, f.size);
      if (bytes == null) {
        anyUnknown = true;
      } else {
        knownBytes += bytes;
      }
    }
    final ref = _refEstimate;
    final cost = ref == null || knownBytes == 0
        ? null
        : approxCostAtto(knownBytes, ref.costAtto, ref.chunkCount);
    final spec = kTierSpecs[tier];
    final title = tier == PublishTier.original
        ? 'Original files (as-is)'
        : '${spec!.name} · ${spec.label} H.264';
    final details = [
      if (_files.length > 1)
        'applies to ${applicable.length} of ${_files.length} files',
      if (knownBytes > 0)
        '≈${formatBytes(knownBytes)}${anyUnknown ? '+' : ''}',
      if (cost != null) '≈${formatUnits(cost)} ANT',
    ].join(' · ');
    return CheckboxListTile(
      dense: true,
      value: _selection.contains(tier),
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(title, style: TextStyle(color: t.bone, fontSize: 14)),
      subtitle: details.isEmpty
          ? null
          : Text(details, style: TextStyle(color: t.ash, fontSize: 12)),
      onChanged: (v) => setState(() {
        v == true ? _selection.add(tier) : _selection.remove(tier);
      }),
    );
  }

  List<Widget> _uncoveredWarning(WiTokens t) {
    final uncovered = _uncoveredFiles();
    if (uncovered.isEmpty) return const [];
    return [
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          '${uncovered.length} '
          '${uncovered.length == 1 ? 'file matches' : 'files match'} none '
          'of the ticked qualities and will be skipped: '
          '${uncovered.map((f) => f.file.name).join(', ')}',
          style: TextStyle(color: t.rust, fontSize: 12, height: 1.4),
        ),
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
            child: Text('Retry', style: TextStyle(color: t.accent)),
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
            'Estimated from live network quotes on the first file; encoded '
            'sizes are predictions. Each upload is quoted and paid at live '
            'prices, so the final total can differ.',
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
            color: t.accent,
          ),
        ),
      ],
    );
  }

  // ── running ──────────────────────────────────────────────────────────

  List<Widget> _runningChildren(WiTokens t) {
    final queue = _session.queue;
    final finished = queue
        .where((e) =>
            e.status == PublishEntryStatus.done ||
            e.status == PublishEntryStatus.skipped)
        .length;
    final entry = _session.currentEntry;
    return [
      Text(
        'Uploading · task ${(_session.current + 1).clamp(1, queue.length)} '
        'of ${queue.length}',
        style: TextStyle(
            color: t.bone, fontSize: 16, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      LinearProgressIndicator(
        value: queue.isEmpty ? null : finished / queue.length,
        backgroundColor: t.ink2,
      ),
      const SizedBox(height: 16),
      if (entry.status == PublishEntryStatus.error)
        ..._entryErrorSection(t, entry)
      else
        ..._entryProgressSection(t, entry),
      const SizedBox(height: 4),
      Text(
        'You can leave this page — uploading continues and picks up here '
        'when you come back. Just keep W@tch itself open until it '
        'finishes.',
        style: TextStyle(color: t.ash, fontSize: 12),
      ),
      const SizedBox(height: 16),
      ..._queueList(t),
    ];
  }

  List<Widget> _entryProgressSection(WiTokens t, PublishQueueEntry entry) {
    final String label;
    double? fraction;
    if (entry.status == PublishEntryStatus.encoding) {
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

  List<Widget> _entryErrorSection(WiTokens t, PublishQueueEntry entry) {
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
            onPressed: () => _session.resolveError(PublishErrorAction.retry),
            child: const Text('Try again'),
          ),
          OutlinedButton(
            onPressed: () => _session.resolveError(PublishErrorAction.skip),
            child: const Text('Skip this file'),
          ),
          TextButton(
            onPressed: () => _session.resolveError(PublishErrorAction.stop),
            child: Text('Stop', style: TextStyle(color: t.ash)),
          ),
        ],
      ),
    ];
  }

  List<Widget> _queueList(WiTokens t) {
    return [
      for (final entry in _session.queue)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Icon(
                switch (entry.status) {
                  PublishEntryStatus.pending => Icons.schedule,
                  PublishEntryStatus.encoding => Icons.movie_filter_outlined,
                  PublishEntryStatus.uploading =>
                    Icons.cloud_upload_outlined,
                  PublishEntryStatus.done => Icons.check_circle_outline,
                  PublishEntryStatus.error => Icons.error_outline,
                  PublishEntryStatus.skipped => Icons.remove_circle_outline,
                },
                size: 16,
                color: switch (entry.status) {
                  PublishEntryStatus.done => t.signalOk,
                  PublishEntryStatus.error => t.rust,
                  PublishEntryStatus.pending ||
                  PublishEntryStatus.skipped =>
                    t.ash,
                  _ => t.accent,
                },
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  entry.item.outputName,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: entry.status == PublishEntryStatus.skipped
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

  // ── done ─────────────────────────────────────────────────────────────

  List<Widget> _doneChildren(WiTokens t) {
    final queue = _session.queue;
    final published = _published;
    final failed =
        queue.where((e) => e.status == PublishEntryStatus.error).length;
    final skipped =
        queue.where((e) => e.status == PublishEntryStatus.skipped).length;
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
              'Uploaded',
              style: TextStyle(
                  color: t.bone, fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Text(
        '${published.length} of ${queue.length} uploads finished · '
        'paid ${formatUnits(paid)} ANT'
        '${skipped > 0 ? ' · $skipped skipped' : ''}'
        '${failed > 0 ? ' · $failed failed' : ''}',
        style: TextStyle(color: t.boneDim, fontSize: 13),
      ),
      const SizedBox(height: 16),
      for (final entry in published) _publishedTile(t, entry),
      const SizedBox(height: 8),
      Text(
        'The titles are ready to play from your library once added, and '
        'My W@tch sync carries them to your linked devices. They stay '
        'private unless you share the .datamap files (or a list bundle '
        'from the Media page) yourself.',
        style: TextStyle(color: t.ash, fontSize: 12, height: 1.4),
      ),
      const SizedBox(height: 20),
      if (published.isNotEmpty) ...[
        FilledButton.icon(
          onPressed: _addAllToLibrary,
          icon: const Icon(Icons.video_library_outlined),
          label: const Text('Add to library'),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _saveAllDatamaps,
          icon: const Icon(Icons.save_alt),
          label: Text(published.length == 1
              ? 'Save .datamap file'
              : 'Save ${published.length} .datamap files'),
        ),
        const SizedBox(height: 10),
      ],
      TextButton(
        onPressed: _reset,
        child: Text('Upload more', style: TextStyle(color: t.ash)),
      ),
    ];
  }

  Widget _publishedTile(WiTokens t, PublishQueueEntry entry) {
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

/// Desktop platforms are the only place Upload exists this edition
/// (uploads need local files, ffmpeg, and a wallet on disk).
bool get isDesktopPlatform =>
    Platform.isLinux || Platform.isMacOS || Platform.isWindows;

/// Checkbox picker over the existing lists plus a create-new option —
/// the import flow's picker pattern (its original is private to the
/// Media page). Shared by the Upload and channel-publish done pages.
Future<List<String>?> pickTargetLists(
    BuildContext context, List<MediaList> allLists) async {
  final t = WiTokens.of(context);
  // Channel lists mirror someone's manifest and are read-only — never
  // add targets.
  final lists = [for (final l in allLists) if (!l.isChannel) l];
  if (lists.isEmpty) {
    final title = await promptForText(
      context,
      title: 'New list',
      hint: 'e.g. My uploads',
      note: 'The library has no lists yet — name one for these titles.',
    );
    final trimmed = title?.trim() ?? '';
    return trimmed.isEmpty ? null : [trimmed];
  }
  final selected = <String>{};
  return showDialog<List<String>>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        backgroundColor: t.ink2,
        title: Text('Add to library',
            style: TextStyle(color: t.bone, fontSize: 16)),
        content: SizedBox(
          width: 360,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final list in lists)
                CheckboxListTile(
                  dense: true,
                  value: selected.contains(list.title),
                  title: Text(list.title,
                      style: TextStyle(color: t.bone, fontSize: 14)),
                  onChanged: (v) => setDialogState(() => v == true
                      ? selected.add(list.title)
                      : selected.remove(list.title)),
                ),
              OutlinedButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Create new list'),
                onPressed: () async {
                  final title = await promptForText(
                    context,
                    title: 'New list',
                    hint: 'e.g. My uploads',
                  );
                  final trimmed = title?.trim() ?? '';
                  if (trimmed.isNotEmpty) {
                    setDialogState(() => selected.add(trimmed));
                    if (context.mounted) {
                      Navigator.of(context).pop(selected.toList());
                    }
                  }
                },
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
            onPressed: selected.isEmpty
                ? null
                : () => Navigator.of(context).pop(selected.toList()),
            child: Text('Add', style: TextStyle(color: t.accent)),
          ),
        ],
      ),
    ),
  );
}

/// Merge [entries] into every list named in [chosen] (created when
/// missing), deduplicating by address — the Upload done page's
/// add-to-library semantics, shared with the channel-publish flow.
Future<void> addEntriesToLists(
    List<MediaEntry> entries, List<String> chosen) async {
  final lists = await LibraryStore.load();
  final updated = List<MediaList>.of(lists);
  var idBase = DateTime.now().microsecondsSinceEpoch;
  for (final title in chosen) {
    final i = updated.indexWhere((l) =>
        !l.isChannel && l.title.toLowerCase() == title.toLowerCase());
    if (i < 0) {
      updated
          .add(MediaList(id: '${idBase++}', title: title, entries: entries));
    } else {
      final existing = updated[i].entries.map((e) => e.address).toSet();
      final fresh = [
        for (final entry in entries)
          if (!existing.contains(entry.address)) entry,
      ];
      if (fresh.isNotEmpty) {
        updated[i] = updated[i]
            .copyWith(entries: [...updated[i].entries, ...fresh]);
      }
    }
  }
  await LibraryStore.save(updated);
}
