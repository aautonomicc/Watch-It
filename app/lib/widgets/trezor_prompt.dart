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
    case 'unlock-wallet':
      return 'W@tch is opening a wallet session on your Trezor for this '
          'job. If the device asks for its PIN or passphrase, enter it on '
          'the device — one entry covers every signature in this run.';
    default:
      return 'The Trezor needs a confirmation on its own screen — pick it '
          'up and follow what the device shows.';
  }
}

/// Short title per action, used as the card headline.
String trezorPromptTitle(String? action) {
  switch (action) {
    case 'confirm-address':
      return 'Check the address on your Trezor';
    case 'sign-payment':
      return 'Confirm the payment on your Trezor';
    case 'unlock-wallet':
      return 'Unlock the wallet on your Trezor';
    default:
      return 'Check your Trezor';
  }
}

/// Mounts once above the app's first route and watches
/// [TrezorAttentionService]: the moment the core reports the Trezor is
/// waiting for a human, it plays the chime and shows an explanation
/// card; the card follows the action live and removes itself when the
/// device stops waiting. Manually hiding it only silences THAT tap —
/// the next one announces again.
///
/// The card is an [OverlayEntry], deliberately NOT a dialog route: a
/// navigator route here once absorbed another dialog's `Navigator.pop`
/// (the Trezor setup dialog's success-pop landed on the still-open
/// prompt, stranding the setup dialog forever), because `pop` always
/// removes the TOP-MOST route. An overlay entry sits outside the route
/// stack, so other dialogs open and close as if it weren't there.
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
  OverlayEntry? _entry;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onChange);
  }

  @override
  void dispose() {
    _service.removeListener(_onChange);
    _removeCard();
    super.dispose();
  }

  void _onChange() {
    final activity = _service.current;
    if (activity == null) {
      // The device stopped waiting — the card goes with it.
      _removeCard();
      return;
    }
    // Same tap as before: an open card already follows it live (the card
    // listens too), and a hidden one stays hidden.
    if (activity.seq == _announcedSeq) return;
    _announcedSeq = activity.seq;
    unawaited(TrezorChime.play());
    _showCard();
  }

  void _showCard() {
    if (!mounted || _entry != null) return;
    final entry = OverlayEntry(
      builder: (_) => TrezorPromptCard(service: _service, onHide: _removeCard),
    );
    _entry = entry;
    Overlay.of(context, rootOverlay: true).insert(entry);
  }

  void _removeCard() {
    _entry?.remove();
    _entry = null;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The floating card itself: explains the current device action in plain
/// words and follows it live. Non-modal — the app behind it stays
/// usable, and only the card itself absorbs taps.
class TrezorPromptCard extends StatelessWidget {
  const TrezorPromptCard({
    super.key,
    required this.service,
    required this.onHide,
  });

  final TrezorAttentionService service;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final activity = service.current;
        // The host removes the entry when the beacon clears; render
        // nothing for the frame in between.
        if (activity == null) return const SizedBox.shrink();
        return SafeArea(
          // Bottom-centered like a rich toast: the card never covers a
          // centered dialog's buttons, and the app stays usable behind it.
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 20, left: 16, right: 16),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Material(
                  color: t.ink2,
                  elevation: 12,
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 20, 24, 10),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.vibration, color: t.accent, size: 32),
                        const SizedBox(height: 10),
                        Text(
                          trezorPromptTitle(activity.action),
                          style: TextStyle(color: t.bone, fontSize: 16),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          trezorPromptBody(activity.action),
                          style: TextStyle(
                            color: t.boneDim,
                            fontSize: 13,
                            height: 1.45,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: onHide,
                            child: const Text('Hide'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
