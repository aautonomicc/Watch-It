import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';

/// Error surfaces are tap-to-copy: a long core error (hardware wallet,
/// payment, backup) never has to be retyped from a screenshot — tapping
/// the text puts the whole message on the clipboard for a bug report.

/// An error snackbar whose text copies itself when tapped. Errors also
/// stay up longer than the 4s default so there is time to read and tap.
SnackBar copyableErrorSnackBar(String message) => SnackBar(
      duration: const Duration(seconds: 10),
      content: CopyableSnackText(message),
    );

/// The snackbar body: the message plus a "Tap to copy" line that flips
/// to "Copied to clipboard" once tapped.
class CopyableSnackText extends StatefulWidget {
  const CopyableSnackText(this.message, {super.key});

  final String message;

  @override
  State<CopyableSnackText> createState() => _CopyableSnackTextState();
}

class _CopyableSnackTextState extends State<CopyableSnackText> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.message));
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _copy,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.message,
              maxLines: 8,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Text(
              _copied ? 'Copied to clipboard' : 'Tap to copy',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context)
                    .snackBarTheme
                    .contentTextStyle
                    ?.color
                    ?.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// An inline error paragraph (dialog error lines, screen error states)
/// that copies its full text when tapped and confirms with a short
/// snackbar.
class CopyableErrorText extends StatelessWidget {
  const CopyableErrorText(this.message, {super.key, this.style});

  final String message;

  /// Defaults to the small rust-red error style used across the app.
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return Tooltip(
      message: 'Tap to copy the error',
      waitDuration: const Duration(milliseconds: 600),
      child: InkWell(
        onTap: () async {
          await Clipboard.setData(ClipboardData(text: message));
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Error message copied'),
            duration: Duration(seconds: 2),
          ));
        },
        child: Text(
          message,
          style: style ?? TextStyle(color: t.rust, fontSize: 12),
        ),
      ),
    );
  }
}
