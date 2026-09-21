import 'dart:async';

import 'package:flutter/material.dart';

import '../services/my_watch_api.dart';
import '../services/tv_settings.dart';
import '../theme/tokens.dart';
import 'wi_qr.dart';

/// Reverse-QR pairing, unlinked side: shows the `wtchp1-` pairing code
/// as a QR for a linked device (with a camera) to scan, and polls until
/// this device has joined the link. Pops `true` once linked, `false`
/// when cancelled or dismissed after a failure.
///
/// The forward invite QR needs a camera on the joining device — this is
/// the path for TVs and desktops, which only have a screen.
class PairCodeDialog extends StatefulWidget {
  const PairCodeDialog({
    super.key,
    required this.api,
    required this.code,
    this.pollInterval = const Duration(seconds: 3),
  });

  final MyWatchApi api;

  /// The `wtchp1-…` code from `pairStart`.
  final String code;

  final Duration pollInterval;

  @override
  State<PairCodeDialog> createState() => _PairCodeDialogState();
}

class _PairCodeDialogState extends State<PairCodeDialog> {
  Timer? _timer;
  bool _polling = false;
  String? _failure;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(widget.pollInterval, (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    if (_polling || _failure != null) return;
    _polling = true;
    try {
      final status = await widget.api.status();
      if (status.linked) {
        if (mounted) Navigator.of(context).pop(true);
        return;
      }
      final pair = await widget.api.pairStatus();
      if (pair.active && pair.state == 'failed' && mounted) {
        setState(() => _failure = pair.message ?? 'Pairing failed');
      }
    } catch (_) {
      // Transient — the next poll retries.
    } finally {
      _polling = false;
    }
  }

  Future<void> _cancel() async {
    try {
      await widget.api.pairCancel();
    } catch (_) {}
    if (mounted) Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return AlertDialog(
      title: const Text('Pair this device'),
      content: SizedBox(
        width: wiQrDialogWidth(context),
        // No scroll view: a D-pad can't scroll one (no focusable child),
        // so on a small TV viewport the QR bottom simply cropped away.
        // The QR itself shrinks to the height the dialog really has.
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'On a phone that is already linked, open My W@tch, '
              'choose "Link a new device", and scan this code. This '
              'device then joins the same My W@tch — nothing to type.',
              style: TextStyle(fontSize: 13, color: t.boneDim),
            ),
            const SizedBox(height: 16),
            Flexible(child: WiQrCard(data: widget.code, size: 220)),
            const SizedBox(height: 12),
            if (_failure != null)
              Text(
                _failure!,
                style: TextStyle(fontSize: 13, color: t.rust),
              )
            else
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      'Waiting for a linked device… linking can take '
                      'a minute or two after the scan.',
                      style: TextStyle(fontSize: 12.5, color: t.ash),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          // The dialog's only control takes the TV's initial D-pad focus
          // — without it the dialog opened with no visible focus at all.
          autofocus: TvSettings.instance.enabled,
          onPressed: _cancel,
          child: Text(_failure == null ? 'Cancel' : 'Close'),
        ),
      ],
    );
  }
}

/// Reverse-QR pairing, linked side: after scanning a new device's code
/// and starting the send, polls until the new device confirms receipt
/// (or the attempt fails). Pops `true` on delivery, `false` otherwise.
class PairSendDialog extends StatefulWidget {
  const PairSendDialog({
    super.key,
    required this.api,
    this.pollInterval = const Duration(seconds: 2),
  });

  final MyWatchApi api;
  final Duration pollInterval;

  @override
  State<PairSendDialog> createState() => _PairSendDialogState();
}

class _PairSendDialogState extends State<PairSendDialog> {
  Timer? _timer;
  bool _polling = false;
  String? _failure;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(widget.pollInterval, (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    if (_polling || _failure != null) return;
    _polling = true;
    try {
      final pair = await widget.api.pairStatus();
      if (pair.state == 'delivered') {
        // Sweep the finished session so the next attempt starts clean.
        try {
          await widget.api.pairCancel();
        } catch (_) {}
        if (mounted) Navigator.of(context).pop(true);
        return;
      }
      if (pair.active && pair.state == 'failed' && mounted) {
        setState(() => _failure = pair.message ?? 'Pairing failed');
      }
    } catch (_) {
      // Transient — the next poll retries.
    } finally {
      _polling = false;
    }
  }

  Future<void> _cancel() async {
    try {
      await widget.api.pairCancel();
    } catch (_) {}
    if (mounted) Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return AlertDialog(
      title: const Text('Linking the new device'),
      content: SizedBox(
        width: 300,
        child: _failure != null
            ? Text(_failure!, style: TextStyle(fontSize: 13, color: t.rust))
            : Row(
                children: [
                  const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Sending the link to the new device — keep its '
                      'pairing code on screen. This can take a minute '
                      'or two.',
                      style: TextStyle(fontSize: 13, color: t.boneDim),
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          autofocus: TvSettings.instance.enabled,
          onPressed: _cancel,
          child: Text(_failure == null ? 'Cancel' : 'Close'),
        ),
      ],
    );
  }
}
