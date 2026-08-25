import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../models/media_list.dart';
import '../services/embedded_client.dart';
import '../services/library_store.dart';
import '../services/publish_api.dart';
import '../theme/tokens.dart';
import 'settings_screen.dart' show promptForText;
import 'wallet_screen.dart';

/// Publish: upload a media file to the Autonomi network from the app.
///
/// Plain upload edition — pick a file, see the live network cost
/// estimate, confirm rights + permanence, pay from the internal wallet
/// and watch progress; the result lands in the library like any import.
/// (Quality tiers / re-encoding arrive in the next edition.)
class PublishScreen extends StatefulWidget {
  const PublishScreen({super.key, this.apiBase, this.apiToken});

  /// Test overrides for the embedded server base URL / auth token.
  final String? apiBase;
  final String? apiToken;

  @override
  State<PublishScreen> createState() => _PublishScreenState();
}

class _PublishScreenState extends State<PublishScreen> {
  late final PublishApi _api =
      PublishApi(base: widget.apiBase, token: widget.apiToken);

  WalletStatus? _wallet;
  XFile? _file;
  int? _fileSize;
  UploadEstimate? _estimate;
  bool _estimating = false;
  String? _estimateError;
  bool _rights = false;
  int? _jobId;
  UploadJob? _job;
  Timer? _poll;
  String? _startError;

  @override
  void initState() {
    super.initState();
    _loadWallet();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _loadWallet() async {
    try {
      final status = await _api.walletStatus();
      if (mounted) setState(() => _wallet = status);
    } catch (_) {
      // Leave null — the wallet row shows setup guidance either way.
      if (mounted) {
        setState(() => _wallet =
            const WalletStatus(configured: false));
      }
    }
  }

  Future<void> _pickFile() async {
    final file = await openFile(acceptedTypeGroups: [
      const XTypeGroup(label: 'Media files', extensions: [
        'mp4', 'mkv', 'webm', 'avi', 'mov', 'm4v',
        'mp3', 'flac', 'm4a', 'ogg', 'opus', 'wav',
      ]),
      const XTypeGroup(label: 'All files'),
    ]);
    if (file == null) return;
    final size = await file.length();
    if (!mounted) return;
    setState(() {
      _file = file;
      _fileSize = size;
      _estimate = null;
      _estimateError = null;
      _rights = false;
      _jobId = null;
      _job = null;
      _startError = null;
    });
    await _estimateCost();
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
      if (mounted) setState(() => _estimate = estimate);
    } catch (e) {
      if (mounted) setState(() => _estimateError = '$e');
    } finally {
      if (mounted) setState(() => _estimating = false);
    }
  }

  Future<void> _publish() async {
    final file = _file;
    if (file == null) return;
    setState(() => _startError = null);
    try {
      final id = await _api.startUpload(file.path, name: file.name);
      setState(() {
        _jobId = id;
        _job = UploadJob(id: id, phase: 'starting', done: 0, total: 0);
      });
      _poll = Timer.periodic(const Duration(seconds: 1), (_) => _pollJob());
    } catch (e) {
      setState(() => _startError = '$e');
    }
  }

  Future<void> _pollJob() async {
    final id = _jobId;
    if (id == null) return;
    try {
      final job = await _api.jobStatus(id);
      if (!mounted) return;
      setState(() => _job = job);
      if (job.finished) {
        _poll?.cancel();
        _poll = null;
      }
    } catch (_) {
      // Transient poll failure: keep the timer, the next tick retries.
    }
  }

  void _reset() {
    _poll?.cancel();
    _poll = null;
    setState(() {
      _file = null;
      _fileSize = null;
      _estimate = null;
      _estimateError = null;
      _rights = false;
      _jobId = null;
      _job = null;
      _startError = null;
    });
  }

  Future<void> _addToLibrary(UploadResult result) async {
    final lists = await LibraryStore.load();
    if (!mounted) return;
    final chosen = await _pickTargetLists(lists);
    if (chosen == null || chosen.isEmpty) return;
    var updated = List<MediaList>.of(lists);
    var idBase = DateTime.now().microsecondsSinceEpoch;
    final entry = MediaEntry(
      name: _file?.name ?? result.address,
      address: result.address,
      sizeBytes: result.size,
    );
    for (final title in chosen) {
      final i = updated
          .indexWhere((l) => l.title.toLowerCase() == title.toLowerCase());
      if (i < 0) {
        updated.add(MediaList(
            id: '${idBase++}', title: title, entries: [entry]));
      } else if (!updated[i]
          .entries
          .any((e) => e.address == result.address)) {
        updated[i] = updated[i]
            .copyWith(entries: [...updated[i].entries, entry]);
      }
    }
    await LibraryStore.save(updated);
    _snack('Added to ${chosen.length == 1 ? chosen.first : '${chosen.length} lists'}');
  }

  /// Checkbox picker over the existing lists plus a create-new option —
  /// the import flow's picker pattern (its original is private to the
  /// Media page).
  Future<List<String>?> _pickTargetLists(List<MediaList> lists) async {
    final t = WiTokens.of(context);
    if (lists.isEmpty) {
      final title = await promptForText(
        context,
        title: 'New list',
        hint: 'e.g. My uploads',
        note: 'The library has no lists yet — name one for this title.',
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

  Future<void> _saveDatamap(UploadResult result) async {
    final base = widget.apiBase ?? EmbeddedClient.baseUrl();
    if (base == null) return;
    final fileName = '${_file?.name ?? result.address}.datamap';
    try {
      final res = await http
          .get(Uri.parse('$base/datamap/${result.address}'));
      if (res.statusCode != 200) {
        _snack('Could not fetch the data map (${res.statusCode})');
        return;
      }
      final location = await getSaveLocation(
        suggestedName: fileName,
        acceptedTypeGroups: const [
          XTypeGroup(label: 'Data map', extensions: ['datamap']),
        ],
      );
      if (location == null) return;
      await XFile.fromData(res.bodyBytes,
              mimeType: 'application/octet-stream', name: fileName)
          .saveTo(location.path);
      _snack('Saved $fileName');
    } catch (e) {
      _snack('Save failed: $e');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  bool get _uploading =>
      _job != null && !_job!.finished || _jobId != null && _job == null;

  bool get _canPublish =>
      _file != null &&
      (_wallet?.configured ?? false) &&
      _estimate != null &&
      _rights &&
      !_uploading &&
      (_job == null || _job!.phase == 'error');

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final job = _job;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Text('Publish', style: TextStyle(color: t.bone, fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (job?.phase == 'done' && job?.result != null)
            ..._doneSection(t, job!.result!)
          else ...[
            Text(
              'Publish a media file to the Autonomi network. Published '
              'files are permanent — they cannot be edited or deleted — '
              'and storage is paid once, in ANT, from your wallet.',
              style: TextStyle(color: t.boneDim, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 16),
            _walletRow(t),
            const SizedBox(height: 16),
            _fileRow(t),
            if (_file != null) ...[
              const SizedBox(height: 16),
              _estimateSection(t),
            ],
            if (_file != null && _estimate != null && !_uploading) ...[
              const SizedBox(height: 8),
              CheckboxListTile(
                value: _rights,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(
                  'I have the right to publish this file — it is my own '
                  'work or verifiably public domain.',
                  style: TextStyle(color: t.bone, fontSize: 13),
                ),
                onChanged: (v) => setState(() => _rights = v ?? false),
              ),
            ],
            const SizedBox(height: 8),
            if (_startError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(_startError!,
                    style: TextStyle(color: t.rust, fontSize: 13)),
              ),
            if (_uploading || job?.phase == 'error')
              _progressSection(t, job)
            else
              FilledButton.icon(
                onPressed: _canPublish ? _publish : null,
                icon: const Icon(Icons.cloud_upload_outlined),
                label: const Text('Publish'),
              ),
          ],
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

  Widget _fileRow(WiTokens t) {
    final file = _file;
    if (file == null) {
      return OutlinedButton.icon(
        onPressed: _pickFile,
        icon: const Icon(Icons.insert_drive_file_outlined),
        label: const Text('Choose a file to publish'),
      );
    }
    return Row(
      children: [
        Icon(Icons.insert_drive_file_outlined, color: t.accent, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '${file.name}${_fileSize != null ? ' · ${formatBytes(_fileSize!)}' : ''}',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: t.bone, fontSize: 14),
          ),
        ),
        if (!_uploading)
          TextButton(
            onPressed: _pickFile,
            child: Text('Change', style: TextStyle(color: t.ash)),
          ),
      ],
    );
  }

  Widget _estimateSection(WiTokens t) {
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
    final estimate = _estimate;
    if (estimate == null) return const SizedBox.shrink();
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
            estimate.alreadyStored
                ? 'Already on the network — publishing again is free'
                : 'Estimated cost: ${formatUnits(estimate.costAtto)} ANT',
            style: TextStyle(
                color: t.bone, fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            '${estimate.chunkCount} chunks · plus ~'
            '${formatUnits(estimate.gasWei)} ETH gas · the network quotes '
            'live prices, so the final cost can differ slightly',
            style: TextStyle(color: t.ash, fontSize: 12, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _progressSection(WiTokens t, UploadJob? job) {
    final phase = job?.phase ?? 'starting';
    final total = job?.total ?? 0;
    final done = job?.done ?? 0;
    final label = switch (phase) {
      'starting' => 'Starting…',
      'encrypting' => 'Encrypting file…',
      'quoting' =>
        'Getting storage quotes${total > 0 ? ' ($done of $total)' : '…'}',
      'paying' => 'Paying for storage…',
      'storing' =>
        'Storing chunks${total > 0 ? ' ($done of $total)' : '…'}',
      'error' => 'Upload failed',
      _ => phase,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (phase != 'error') ...[
          LinearProgressIndicator(
            value: phase == 'storing' && total > 0 ? done / total : null,
            backgroundColor: t.ink2,
          ),
          const SizedBox(height: 8),
          Text(label, style: TextStyle(color: t.boneDim, fontSize: 13)),
          const SizedBox(height: 4),
          Text(
            'Keep W@tch open until the upload finishes.',
            style: TextStyle(color: t.ash, fontSize: 12),
          ),
        ] else ...[
          Text(label,
              style: TextStyle(
                  color: t.rust,
                  fontSize: 14,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(job?.error ?? 'unknown error',
              style: TextStyle(color: t.boneDim, fontSize: 13)),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton(
                onPressed: _canPublish ? _publish : null,
                child: const Text('Try again'),
              ),
              const SizedBox(width: 12),
              TextButton(
                onPressed: _reset,
                child:
                    Text('Start over', style: TextStyle(color: t.ash)),
              ),
            ],
          ),
        ],
      ],
    );
  }

  List<Widget> _doneSection(WiTokens t, UploadResult result) {
    return [
      Row(
        children: [
          Icon(Icons.check_circle_outline, color: t.signalOk, size: 28),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Published',
              style: TextStyle(
                  color: t.bone, fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Text(
        '${_file?.name ?? ''} · ${formatBytes(result.size)} · '
        '${result.chunks} chunks · paid ${formatUnits(result.costAtto)} ANT',
        style: TextStyle(color: t.boneDim, fontSize: 13),
      ),
      const SizedBox(height: 16),
      Text('ADDRESS',
          style: TextStyle(
              fontSize: 11,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w700,
              color: t.ash)),
      const SizedBox(height: 6),
      Row(
        children: [
          Expanded(
            child: SelectableText(
              result.address,
              style: TextStyle(
                fontFamily: wiMonoFamily,
                fontFamilyFallback: wiMonoFallback,
                fontSize: 12,
                color: t.accent,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Copy address',
            icon: Icon(Icons.copy, color: t.ash, size: 18),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: result.address));
              _snack('Address copied');
            },
          ),
        ],
      ),
      const SizedBox(height: 8),
      Text(
        'The title is ready to play from your library once added. To '
        'share it, save the .datamap file and send that (or export a '
        'list bundle from the Media page).',
        style: TextStyle(color: t.ash, fontSize: 12, height: 1.4),
      ),
      const SizedBox(height: 20),
      FilledButton.icon(
        onPressed: () => _addToLibrary(result),
        icon: const Icon(Icons.video_library_outlined),
        label: const Text('Add to library'),
      ),
      const SizedBox(height: 10),
      OutlinedButton.icon(
        onPressed: () => _saveDatamap(result),
        icon: const Icon(Icons.save_alt),
        label: const Text('Save .datamap file'),
      ),
      const SizedBox(height: 10),
      TextButton(
        onPressed: _reset,
        child:
            Text('Publish another file', style: TextStyle(color: t.ash)),
      ),
    ];
  }
}

/// Desktop platforms are the only place Publish exists this edition
/// (uploads need local files, ffmpeg later, and a wallet on disk).
bool get isDesktopPlatform =>
    Platform.isLinux || Platform.isMacOS || Platform.isWindows;
