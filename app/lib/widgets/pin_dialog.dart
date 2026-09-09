import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/profiles.dart';
import '../theme/tokens.dart';

/// Ask for [profile]'s PIN and verify it (rate-limited by the store).
/// Resolves true when verified — including via the admin recovery code
/// ("Forgot PIN?", admin profile only), which removes the PIN and lets
/// the user through to set a fresh one. False = cancelled.
Future<bool> verifyPinDialog(
  BuildContext context,
  Profile profile, {
  String? title,
}) async {
  if (!profile.hasPin) return true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => _PinPromptDialog(profile: profile, title: title),
  );
  return ok ?? false;
}

/// Convenience: verify the ADMIN profile's PIN (true immediately when
/// none is set) — the guard on switching away from a kid profile and on
/// admin-only doors.
Future<bool> verifyAdminPin(BuildContext context, {String? title}) async {
  final admin = ProfileStore.instance.adminProfile;
  if (admin == null || !admin.hasPin) return true;
  return verifyPinDialog(context, admin, title: title ?? 'Admin PIN');
}

class _PinPromptDialog extends StatefulWidget {
  const _PinPromptDialog({required this.profile, this.title});

  final Profile profile;
  final String? title;

  @override
  State<_PinPromptDialog> createState() => _PinPromptDialogState();
}

class _PinPromptDialogState extends State<_PinPromptDialog> {
  final _controller = TextEditingController();
  String? _error;
  bool _checking = false;

  Future<void> _submit() async {
    if (_checking) return;
    setState(() => _checking = true);
    final result = await ProfileStore.instance.verifyPin(
      widget.profile.id,
      _controller.text.trim(),
    );
    if (!mounted) return;
    switch (result) {
      case PinVerify.ok:
        Navigator.of(context).pop(true);
      case PinVerify.wrong:
        setState(() {
          _checking = false;
          _error = 'Wrong PIN — try again';
          _controller.clear();
        });
      case PinVerify.locked:
        setState(() {
          _checking = false;
          _error = 'Too many tries — locked for a minute';
          _controller.clear();
        });
    }
  }

  Future<void> _forgot() async {
    final recovered = await showDialog<bool>(
      context: context,
      builder: (context) => const _RecoveryCodeDialog(),
    );
    if (recovered == true && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final isAdmin = widget.profile.isAdmin;
    return AlertDialog(
      backgroundColor: t.ink2,
      title: Text(
        widget.title ?? 'PIN for ${widget.profile.name}',
        style: TextStyle(color: t.bone, fontSize: 16),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            maxLength: 6,
            style: TextStyle(color: t.bone, letterSpacing: 6),
            decoration: InputDecoration(
              hintText: 'PIN',
              counterText: '',
              hintStyle: TextStyle(color: t.ash),
            ),
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: t.rust, fontSize: 12.5)),
          ],
          if (isAdmin)
            TextButton(
              onPressed: _forgot,
              child: Text(
                'Forgot PIN?',
                style: TextStyle(color: t.accent, fontSize: 12.5),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text('Cancel', style: TextStyle(color: t.ash)),
        ),
        TextButton(
          onPressed: _checking ? null : _submit,
          child: Text('Unlock', style: TextStyle(color: t.accent)),
        ),
      ],
    );
  }
}

/// "Forgot PIN?": entering the one-time recovery code removes the admin
/// PIN so a fresh one can be set.
class _RecoveryCodeDialog extends StatefulWidget {
  const _RecoveryCodeDialog();

  @override
  State<_RecoveryCodeDialog> createState() => _RecoveryCodeDialogState();
}

class _RecoveryCodeDialogState extends State<_RecoveryCodeDialog> {
  final _controller = TextEditingController();
  String? _error;

  Future<void> _submit() async {
    final ok = await ProfileStore.instance.recoverAdminPin(_controller.text);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => _error = 'That code doesn\'t match');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return AlertDialog(
      backgroundColor: t.ink2,
      title: Text(
        'Recovery code',
        style: TextStyle(color: t.bone, fontSize: 16),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Enter the recovery code shown when the admin PIN was set. '
            'A match removes the PIN so you can set a new one.',
            style: TextStyle(color: t.boneDim, fontSize: 12.5),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            style: TextStyle(color: t.bone, fontFamily: 'monospace'),
            decoration: InputDecoration(
              hintText: 'XXXX-XXXX-XXXX',
              hintStyle: TextStyle(color: t.ash),
            ),
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: t.rust, fontSize: 12.5)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text('Cancel', style: TextStyle(color: t.ash)),
        ),
        TextButton(
          onPressed: _submit,
          child: Text('Recover', style: TextStyle(color: t.accent)),
        ),
      ],
    );
  }
}

/// Enter-and-confirm a new 4–6 digit PIN; resolves the PIN or null.
Future<String?> promptNewPin(BuildContext context, {String title = 'Set PIN'}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _NewPinDialog(title: title),
  );
}

class _NewPinDialog extends StatefulWidget {
  const _NewPinDialog({required this.title});

  final String title;

  @override
  State<_NewPinDialog> createState() => _NewPinDialogState();
}

class _NewPinDialogState extends State<_NewPinDialog> {
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;

  void _submit() {
    final pin = _pin.text.trim();
    if (pin.length < 4) {
      setState(() => _error = 'Use at least 4 digits');
      return;
    }
    if (pin != _confirm.text.trim()) {
      setState(() => _error = 'The PINs don\'t match');
      return;
    }
    Navigator.of(context).pop(pin);
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return AlertDialog(
      backgroundColor: t.ink2,
      title: Text(widget.title, style: TextStyle(color: t.bone, fontSize: 16)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (controller, hint) in [
            (_pin, '4–6 digit PIN'),
            (_confirm, 'Repeat PIN'),
          ])
            TextField(
              controller: controller,
              autofocus: controller == _pin,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              maxLength: 6,
              style: TextStyle(color: t.bone, letterSpacing: 6),
              decoration: InputDecoration(
                hintText: hint,
                counterText: '',
                hintStyle: TextStyle(color: t.ash),
              ),
              onSubmitted: controller == _confirm ? (_) => _submit() : null,
            ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: t.rust, fontSize: 12.5)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Cancel', style: TextStyle(color: t.ash)),
        ),
        TextButton(
          onPressed: _submit,
          child: Text('Save', style: TextStyle(color: t.accent)),
        ),
      ],
    );
  }
}

/// One-time display of a freshly minted admin recovery code — it is
/// never shown again (only its hash is kept).
Future<void> showRecoveryCode(BuildContext context, String code) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) {
      final t = WiTokens.of(context);
      return AlertDialog(
        backgroundColor: t.ink2,
        title: Text(
          'Your recovery code',
          style: TextStyle(color: t.bone, fontSize: 16),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Write this down somewhere safe. It is shown only ONCE and '
              'is the only way back in if the admin PIN is forgotten:',
              style: TextStyle(color: t.boneDim, fontSize: 12.5),
            ),
            const SizedBox(height: 14),
            Center(
              child: SelectableText(
                code,
                style: TextStyle(
                  color: t.accent,
                  fontSize: 20,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Setting or changing the PIN again mints a new code and '
              'invalidates this one.',
              style: TextStyle(color: t.ash, fontSize: 11.5),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('I wrote it down', style: TextStyle(color: t.accent)),
          ),
        ],
      );
    },
  );
}
