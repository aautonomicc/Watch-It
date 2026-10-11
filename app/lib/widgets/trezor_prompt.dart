import 'dart:async';

import 'package:flutter/material.dart';

import '../services/trezor_attention.dart';
import '../theme/tokens.dart';

/// Plain-language copy for each Trezor attention action — what the
/// device is asking, why it is safe (or what to check), and what happens
/// next. Top-level so tests can pin the wording.
String trezorPromptBody(String? action) {
  switch (action) {
    case 'sign-identity':
      return 'W@tch is asking the Trezor to sign its backup-identity '
          'message. The signature only unlocks your backup keys — it costs '
          'nothing and authorizes no payment. Confirm it on the device. '
          'During setup the device asks twice: the second signature is a '
          'safety check that the device repeats itself exactly.';
    case 'confirm-address':
      return 'The Trezor is showing a wallet address on its own screen. '
          'Check that it matches the address W@tch shows, then confirm on '
          'the device — the device\'s screen is the one display no '
          'software on this computer can fake.';
    case 'sign-payment':
      return 'The Trezor is asking you to confirm a payment for network '
          'storage. Check the amount on the device screen and confirm — '
          'the upload carries on by itself afterwards. The first payment '
          'after setup may ask twice: the extra confirmation is a one-time '
          'spending allowance for the payment contract.';
    default:
      return 'The Trezor needs a confirmation on its own screen — pick it '
          'up and follow what the device shows.';
  }
}

/// Short title per action, used as the dialog headline.
String trezorPromptTitle(String? action) {
  switch (action) {
    case 'confirm-address':
      return 'Check the address on your Trezor';
    case 'sign-payment':
      return 'Confirm the payment on your Trezor';
    default:
      return 'Check your Trezor';
  }
}

/// Mounts once above the app's first route and watches
/// [TrezorAttentionService]: the moment the core reports the Trezor is
/// waiting for a human, it plays the chime and pops an explanation
/// dialog; the dialog follows the action live and dismisses itself when
/// the device stops waiting. Manually closing it only silences THAT tap
/// — the next one announces again.
class TrezorPromptHost extends StatefulWidget {
  const TrezorPromptHost({super.key, required this.child, this.service});

  final Widget child;

  /// Test seam; defaults to [TrezorAttentionService.instance].
  final TrezorAttentionService? service;

  @override
  State<TrezorPromptHost> createState() => _TrezorPromptHostState();
}

class _TrezorPromptHostState extends State<TrezorPromptHost> {
  TrezorAttentionService get _service =>
      widget.service ?? TrezorAttentionService.instance;

  int _announcedSeq = 0;
  bool _dialogOpen = false;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onChange);
  }

  @override
  void dispose() {
    _service.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    final activity = _service.current;
    // The dialog pops itself when the activity clears (it listens too);
    // the host only ANNOUNCES new taps.
    if (activity == null || activity.seq == _announcedSeq) return;
    _announcedSeq = activity.seq;
    unawaited(TrezorChime.play());
    if (_dialogOpen || !mounted) return;
    _dialogOpen = true;
    unawaited(showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (_) => TrezorPromptDialog(service: _service),
    ).whenComplete(() => _dialogOpen = false));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The popup itself: explains the current device action in plain words
/// and dismisses itself the moment the device stops waiting.
class TrezorPromptDialog extends StatefulWidget {
  const TrezorPromptDialog({super.key, required this.service});

  final TrezorAttentionService service;

  @override
  State<TrezorPromptDialog> createState() => _TrezorPromptDialogState();
}

class _TrezorPromptDialogState extends State<TrezorPromptDialog> {
  bool _popped = false;

  void _popSelf(BuildContext context) {
    if (_popped) return;
    _popped = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return ListenableBuilder(
      listenable: widget.service,
      builder: (context, _) {
        final activity = widget.service.current;
        if (activity == null) {
          _popSelf(context);
          return const SizedBox.shrink();
        }
        return AlertDialog(
          backgroundColor: t.ink2,
          icon: Icon(Icons.vibration, color: t.accent, size: 32),
          title: Text(
            trezorPromptTitle(activity.action),
            style: TextStyle(color: t.bone, fontSize: 16),
            textAlign: TextAlign.center,
          ),
          content: SizedBox(
            width: 380,
            child: Text(
              trezorPromptBody(activity.action),
              style: TextStyle(color: t.boneDim, fontSize: 13, height: 1.45),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Hide'),
            ),
          ],
        );
      },
    );
  }
}
