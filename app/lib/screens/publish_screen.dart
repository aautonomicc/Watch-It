import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/media_list.dart';
import '../services/batch_upload.dart'
    show AttentionBatch, scanAttentionBatches;
import '../services/ffmpeg.dart';
import '../services/publish_api.dart';
import '../theme/tokens.dart';
import 'batch_upload_screen.dart';
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
/// One way in since the tier-flow merge: the batch uploader handles a
/// single file and a whole folder alike (auto naming/metadata, ledger
/// dedup, unattended paid batch), and quality-tier encoding for videos
/// lives on its review page. This screen is the doorway: wallet state,
/// the way in, and a pointer at files from earlier batches that still
/// need attention.
class PublishScreen extends StatefulWidget {
  const PublishScreen({
    super.key,
    this.apiBase,
    this.apiToken,
    this.ffmpeg,
    this.batchRootProvider,
  });

  /// Test overrides for the embedded server base URL / auth token.
  final String? apiBase;
  final String? apiToken;

  /// Kept for call-site compatibility (the tier flow that used it
  /// moved into the batch uploader's review page).
  final FfmpegService? ffmpeg;

  /// Test override for the earlier-batches root the needs-attention
  /// scan reads (`<support>/batch_uploads` normally).
  final Future<Directory> Function()? batchRootProvider;

  @override
  State<PublishScreen> createState() => _PublishScreenState();
}

class _PublishScreenState extends State<PublishScreen> {
  late final PublishApi _api =
      PublishApi(base: widget.apiBase, token: widget.apiToken);

  WalletStatus? _wallet;
  List<AttentionBatch> _attention = [];

  @override
  void initState() {
    super.initState();
    _loadWallet();
    _loadAttention();
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

  Future<void> _loadAttention() async {
    try {
      final root = widget.batchRootProvider != null
          ? await widget.batchRootProvider!()
          : Directory(p.join(
              (await getApplicationSupportDirectory()).path,
              'batch_uploads'));
      final batches = await scanAttentionBatches(root);
      if (mounted) setState(() => _attention = batches);
    } catch (_) {
      // No support dir (tests) — nothing to surface.
    }
  }

  Future<void> _openBatchUploader() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => BatchUploadScreen(
          apiBase: widget.apiBase, apiToken: widget.apiToken),
    ));
    // Coming back: refresh the pointers (a batch may have resolved or
    // produced needs-attention files).
    await _loadWallet();
    await _loadAttention();
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final attentionTotal =
        _attention.fold(0, (n, b) => n + b.sources.length);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Text('Upload', style: TextStyle(color: t.bone, fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Upload media files to the Autonomi network — one file or a '
            'whole folder at once. Uploads are private: only you and '
            'your linked devices can watch. Nothing is published.',
            style: TextStyle(color: t.boneDim, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 8),
          Text(
            'Uploaded files are permanent — they cannot be edited or '
            'deleted — and storage is paid once, in ANT, from your '
            'wallet.',
            style: TextStyle(color: t.ash, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 16),
          _walletRow(t),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _openBatchUploader,
            icon: const Icon(Icons.cloud_upload_outlined),
            label: const Text('Upload files or folders'),
          ),
          const SizedBox(height: 6),
          Text(
            'One file or a whole folder: music and video are matched '
            'against MusicBrainz/TMDB, renamed to canonical W@tch '
            'names, and uploaded in one unattended batch — files you '
            'already uploaded are recognized and never paid for twice. '
            'Videos can be encoded into several quality versions on the '
            'review page.',
            style: TextStyle(color: t.ash, fontSize: 12, height: 1.4),
          ),
          if (attentionTotal > 0) ...[
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.help_outline, color: t.rust, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '$attentionTotal '
                    '${attentionTotal == 1 ? 'file' : 'files'} from '
                    'earlier batches still '
                    '${attentionTotal == 1 ? 'needs' : 'need'} '
                    'attention — open the uploader to fix '
                    '${attentionTotal == 1 ? 'it' : 'them'}.',
                    style: TextStyle(
                        color: t.boneDim, fontSize: 12.5, height: 1.4),
                  ),
                ),
              ],
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
}

/// Desktop platforms are the only place Upload exists this edition
/// (uploads need local files, ffmpeg, and a wallet on disk).
bool get isDesktopPlatform =>
    Platform.isLinux || Platform.isMacOS || Platform.isWindows;

/// Checkbox picker over the existing lists plus a create-new option —
/// the import flow's picker pattern (its original is private to the
/// Media page). Shared by the batch-upload and channel-publish done
/// pages.
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
