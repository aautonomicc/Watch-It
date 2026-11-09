import 'dart:async';

import 'package:flutter/material.dart';

import '../services/publish_api.dart';
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
          'job. If the device asks for its PIN or passphrase, or shows a '
          'passphrase to confirm, do it on the device — one entry covers '
          'every signature in this run.';
    case 'unlock-device':
      return 'Your Trezor is locked and is showing its PIN pad. Enter the '
          'PIN on the device — W@tch carries on by itself the moment it is '
          'unlocked, and nothing has failed. If a confirmation was on the '
          'screen when the device locked, it comes back for you to '
          'confirm.';
    case 'connect-device':
      return 'W@tch cannot reach your Trezor. Plug it in — or, if it is '
          'plugged in, unplug it and plug it back in — and enter its PIN: '
          'a Trezor only shows up on this computer once it is unlocked. '
          'W@tch carries on by itself as soon as the device answers; '
          'nothing has failed and nothing was spent.';
    case 'enter-passphrase':
      return 'Your Trezor is asking for its passphrase (the hidden-wallet '
          'secret). Type it below to open that wallet for this run, or '
          'choose to enter it on the device instead. It is never saved.';
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
    case 'unlock-device':
      return 'Unlock your Trezor';
    case 'connect-device':
      return 'Reconnect your Trezor';
    case 'enter-passphrase':
      return 'Enter your Trezor passphrase';
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
  const TrezorPromptHost(
      {super.key, required this.child, this.service, this.api});

  final Widget child;

  /// Test seam for the passphrase-entry card; defaults to [PublishApi].
  final PublishApi? api;

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
      builder: (_) => TrezorPromptCard(
          service: _service, onHide: _removeCard, api: widget.api),
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
    this.api,
  });

  final TrezorAttentionService service;
  final VoidCallback onHide;

  /// Test seam for the passphrase-entry POST; defaults to [PublishApi].
  final PublishApi? api;

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
                        if (activity.action == 'enter-passphrase')
                          _PassphraseField(api: api ?? PublishApi())
                        else if (activity.action == 'connect-device')
                          // The one wait the device itself cannot end
                          // (it is not there) — so the app can.
                          _StopWaiting(
                            api: api ?? PublishApi(),
                            onHide: onHide,
                          )
                        else ...[
                          const SizedBox(height: 4),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: onHide,
                              child: const Text('Hide'),
                            ),
                          ),
                        ],
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

/// The buttons of the `connect-device` card: Hide (keep waiting, just
/// without the card) and Stop waiting (give up — the job fails cleanly
/// and can be retried later).
class _StopWaiting extends StatefulWidget {
  const _StopWaiting({required this.api, required this.onHide});
  final PublishApi api;
  final VoidCallback onHide;

  @override
  State<_StopWaiting> createState() => _StopWaitingState();
}

class _StopWaitingState extends State<_StopWaiting> {
  bool _busy = false;

  Future<void> _stop() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.api.stopTrezorWaiting();
    } catch (_) {
      // The wait ends by itself after ten minutes if this never lands.
    }
    // The card goes when the beacon clears.
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        alignment: WrapAlignment.end,
        spacing: 8,
        children: [
          TextButton(
            onPressed: _busy ? null : _stop,
            child: Text(_busy ? 'Stopping…' : 'Stop waiting'),
          ),
          TextButton(onPressed: widget.onHide, child: const Text('Hide')),
        ],
      ),
    );
  }
}

/// The passphrase-entry variant of the prompt: an obscured field that
/// POSTs the typed passphrase to the waiting device conversation, plus
/// an "Enter on device instead" escape. Shown only for the
/// `enter-passphrase` action; the device caches the passphrase for the
/// session, so this appears at most once per job.
class _PassphraseField extends StatefulWidget {
  const _PassphraseField({required this.api});
  final PublishApi api;

  @override
  State<_PassphraseField> createState() => _PassphraseFieldState();
}

class _PassphraseFieldState extends State<_PassphraseField> {
  final _controller = TextEditingController();
  bool _busy = false;
  bool _obscure = true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.api.sendTrezorPassphrase(passphrase: _controller.text);
    } catch (_) {
      // The conversation times out on its own if delivery fails.
    }
    // The device takes over from here; the host removes the card when the
    // beacon clears. Leave _busy true so a second tap can't double-send.
  }

  Future<void> _onDevice() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.api.sendTrezorPassphrase(onDevice: true);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 12),
        TextField(
          controller: _controller,
          autofocus: true,
          obscureText: _obscure,
          enabled: !_busy,
          onSubmitted: (_) => _submit(),
          style: TextStyle(color: t.bone, fontSize: 14),
          decoration: InputDecoration(
            labelText: 'Passphrase',
            labelStyle: TextStyle(color: t.ash),
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off,
                  color: t.ash, size: 20),
              onPressed: _busy ? null : () => setState(() => _obscure = !_obscure),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton(
              onPressed: _busy ? null : _onDevice,
              child: const Text('Enter on device instead'),
            ),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: Text(_busy ? 'Sending…' : 'Unlock'),
            ),
          ],
        ),
      ],
    );
  }
}
