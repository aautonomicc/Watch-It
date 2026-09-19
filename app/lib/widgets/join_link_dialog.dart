import 'package:flutter/material.dart';
import '../services/tv_settings.dart';

/// "Enter an invite code" dialog. Owns its controllers until the dialog
/// route is actually disposed (same pattern as [DeviceNameDialog]).
///
/// On TV nothing autofocuses a text field (that would pop the IME over
/// the dialog before the user can read it); the Join button takes the
/// initial D-pad focus instead. The invite field is monospace with
/// autocorrect/suggestions off — the code is 70 opaque characters, not
/// prose — and Enter submits.
class JoinLinkDialog extends StatefulWidget {
  const JoinLinkDialog({
    super.key,
    required this.initialName,
    this.onScanQr,
  });

  final String initialName;

  /// Opens the camera QR scanner and resolves to the scanned invite (or
  /// null when cancelled). Omitted on platforms without a camera path —
  /// desktops, and TVs where a scan button is dead weight.
  final Future<String?> Function()? onScanQr;

  @override
  State<JoinLinkDialog> createState() => _JoinLinkDialogState();
}

class _JoinLinkDialogState extends State<JoinLinkDialog> {
  late final _nameController = TextEditingController(text: widget.initialName);
  final _inviteController = TextEditingController();
  final _inviteFocus = FocusNode();

  /// Join stays pressable even while empty — a disabled button cannot
  /// hold the TV's initial D-pad focus. Pressing it without a code
  /// jumps into the invite field (deliberately raising the IME: the
  /// user just asked to join, input is exactly what is needed next).
  void _submit() {
    final name = _nameController.text.trim();
    final invite = _inviteController.text.trim();
    if (name.isEmpty || invite.isEmpty) {
      _inviteFocus.requestFocus();
      return;
    }
    // Case never carries meaning in an invite (prefix + hex); TV remote
    // keyboards and shouty paste sources both happen.
    Navigator.of(context).pop((name, invite.toLowerCase()));
  }

  @override
  void dispose() {
    _nameController.dispose();
    _inviteController.dispose();
    _inviteFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Enter an invite code'),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              maxLength: 48,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Device name'),
            ),
            TextField(
              controller: _inviteController,
              focusNode: _inviteFocus,
              autofocus: !TvSettings.instance.enabled,
              autocorrect: false,
              enableSuggestions: false,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: 'Invite code',
                helperText: 'Shown under the QR code on the linked device '
                    '(starts with wtch1-)',
                helperMaxLines: 3,
              ),
            ),
            if (widget.onScanQr != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.qr_code_scanner, size: 18),
                  label: const Text('Scan QR code'),
                  onPressed: () async {
                    final code = await widget.onScanQr!();
                    if (code != null) _inviteController.text = code;
                  },
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            autofocus: TvSettings.instance.enabled,
            onPressed: _submit,
            child: const Text('Join'),
          ),
        ],
      );
}
