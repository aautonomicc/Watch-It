import 'package:flutter/material.dart';

import '../services/backup.dart';
import '../theme/tokens.dart';
import 'wallet_screen.dart';

/// Settings → Backup: the seed-phrase backup. Everything W@tch knows —
/// lists, watch points, profiles, edits, artwork, the data maps that
/// make entries playable — backed up to Autonomi under keys derived
/// from the upload wallet, restorable anywhere from its 12 words.
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key, this.service});

  /// Test override.
  final BackupService? service;

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  BackupService get _service => widget.service ?? BackupService.instance;

  BackupStatus? _status;
  String? _error;

  /// The running job's latest polled state, while one runs from here.
  BackupJob? _progress;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _status = null;
      _error = null;
    });
    try {
      final status = await _service.status();
      if (mounted) setState(() => _status = status);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _backUpNow() async {
    final t = WiTokens.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Back up now?'),
        content: Text(
          'Your library, watch points, profiles, edits and artwork are '
          'encrypted and stored on Autonomi, paid from the upload '
          'wallet. The first backup uploads everything; later backups '
          'only pay for what changed.\n\n'
          'Anyone with this wallet\'s 12 words can read the backup — '
          'they are the key.',
          style: TextStyle(color: t.bone, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Back up'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _progress = null;
    });
    try {
      final summary = await _service.runBackup(
        onProgress: (job) {
          if (mounted) setState(() => _progress = job);
        },
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(summary.uploaded == 0
            ? 'Backup up to date — nothing had changed.'
            : 'Backed up — ${summary.uploaded} of ${summary.objects} '
                'object(s) uploaded.'),
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Backup failed: $e')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
        await _reload();
      }
    }
  }

  Future<void> _restore() async {
    final t = WiTokens.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore from backup?'),
        content: Text(
          'The backup made with this wallet is fetched from Autonomi '
          'and merged into this device — nothing here is deleted, and '
          'anything newer on this device wins.',
          style: TextStyle(color: t.bone, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _progress = null;
    });
    try {
      final summary = await _service.restore(
        onProgress: (job) {
          if (mounted) setState(() => _progress = job);
        },
      );
      if (!mounted) return;
      final parts = <String>[
        if (summary.entriesAdded > 0) '${summary.entriesAdded} entries',
        if (summary.watchApplied > 0)
          '${summary.watchApplied} watch point(s)',
        if (summary.profilesChanged > 0)
          '${summary.profilesChanged} profile(s)',
        if (summary.detailsApplied + summary.tmdbApplied > 0)
          '${summary.detailsApplied + summary.tmdbApplied} detail(s)',
        if (summary.artInstalled > 0) '${summary.artInstalled} artwork file(s)',
      ];
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Restore finished'),
          content: Text(
            [
              parts.isEmpty
                  ? 'Everything in the backup was already on this device.'
                  : 'Restored ${parts.join(', ')}.',
              for (final p in summary.problems) p,
            ].join('\n\n'),
            style: TextStyle(color: t.bone, fontSize: 14),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Restore failed: $e')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
        await _reload();
      }
    }
  }

  String _lastLine(BackupLast last) {
    final when = DateTime.fromMillisecondsSinceEpoch(last.ms);
    final date = '${when.year}-${when.month.toString().padLeft(2, '0')}-'
        '${when.day.toString().padLeft(2, '0')} '
        '${when.hour.toString().padLeft(2, '0')}:'
        '${when.minute.toString().padLeft(2, '0')}';
    return 'Backup #${last.backups} · $date · ${last.objects} object(s)';
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final status = _status;
    return Scaffold(
      appBar: AppBar(title: const Text('Backup')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Backs up everything W@tch knows — your lists, watch '
            'points, profiles, edits and artwork — to the Autonomi '
            'network, encrypted so only this wallet\'s 12 words can '
            'read it. A fresh install restores the lot from the words '
            'alone: no other device needed.',
            style: TextStyle(color: t.ash, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 20),
          if (_error != null) ...[
            Text('Could not read the backup state: $_error',
                style: TextStyle(color: t.rust, fontSize: 13)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _reload, child: const Text('Retry')),
          ] else if (status == null) ...[
            const Center(child: CircularProgressIndicator()),
          ] else if (!status.configured) ...[
            Text(
              'No upload wallet is set up on this device yet. The '
              'backup lives under keys derived from the wallet, so set '
              'one up first — to restore an existing backup, import '
              'the same 12 words.',
              style: TextStyle(color: t.bone, fontSize: 14, height: 1.4),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.account_balance_wallet_outlined),
              label: const Text('Set up the wallet'),
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const WalletScreen()),
                );
                await _reload();
              },
            ),
          ] else ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.history, color: t.accent),
              title: Text('Last backup from this device',
                  style: TextStyle(color: t.bone, fontSize: 15)),
              subtitle: Text(
                status.last == null
                    ? 'Never backed up from this device'
                    : _lastLine(status.last!),
                style: TextStyle(color: t.ash, fontSize: 12),
              ),
            ),
            const SizedBox(height: 8),
            if (_busy) ...[
              LinearProgressIndicator(
                value: (_progress?.total ?? 0) > 0
                    ? _progress!.done / _progress!.total
                    : null,
              ),
              const SizedBox(height: 8),
              Text(
                _progress?.label ?? 'Starting…',
                style: TextStyle(color: t.ash, fontSize: 13),
              ),
              const SizedBox(height: 16),
            ] else ...[
              FilledButton.icon(
                icon: const Icon(Icons.cloud_upload_outlined),
                label: const Text('Back up now'),
                onPressed: _backUpNow,
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.cloud_download_outlined),
                label: const Text('Restore from backup'),
                onPressed: _restore,
              ),
              const SizedBox(height: 16),
              Text(
                'Backing up costs a little ANT from the upload wallet '
                '(only what changed since last time). Restoring is '
                'free. Replacing the wallet starts a new backup line — '
                'the old one stays readable with the old words.',
                style: TextStyle(color: t.ash, fontSize: 12, height: 1.4),
              ),
            ],
          ],
        ],
      ),
    );
  }
}
