import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/publish_api.dart' show formatUnits;
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

/// A plain-words line for a failure caused by an underfunded wallet, or
/// null when [message] is some other error. The core reports the
/// shortfall in atto ("Have: 0 atto, need: 514836038085937500 atto");
/// this turns it into ANT, and names gas when that is what ran out.
String? fundsHintFor(String message) {
  final lower = message.toLowerCase();
  if (!lower.contains('insufficient')) return null;
  final m = RegExp(r'have:\s*(\d+)\s*atto,\s*need:\s*(\d+)\s*atto',
          caseSensitive: false)
      .firstMatch(message);
  if (m != null) {
    final have = BigInt.parse(m.group(1)!);
    final need = BigInt.parse(m.group(2)!);
    return 'The upload wallet does not hold enough ANT: this needs about '
        '${formatUnits(need)} ANT and the wallet has ${formatUnits(have)} '
        'ANT. Nothing was spent. Add ANT to the wallet (Settings → '
        'Wallet shows its address), then try again.';
  }
  if (lower.contains('gas')) {
    return 'The upload wallet does not hold enough ETH (on Arbitrum) to '
        'pay the network fee. Nothing was spent. Add a little ETH to the '
        'wallet (Settings → Wallet shows its address), then try again.';
  }
  return 'The upload wallet does not hold enough funds for this. Add '
      'funds to the wallet (Settings → Wallet shows its address), then '
      'try again.';
}

/// A failure that must be acknowledged: unlike a snackbar it stays up
/// until dismissed, so someone who walked away from a long job comes
/// back to the reason it stopped. Takes the [NavigatorState] (grab the
/// root one before the job starts) so the dialog still appears when the
/// screen that started the job has been left meanwhile.
Future<void> showErrorDialog(
  NavigatorState navigator, {
  required String title,
  required String message,
}) async {
  if (!navigator.mounted) return;
  final hint = fundsHintFor(message);
  await showDialog<void>(
    context: navigator.context,
    barrierDismissible: false,
    builder: (context) {
      final t = WiTokens.of(context);
      return AlertDialog(
        icon: Icon(Icons.error_outline, color: t.rust),
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (hint != null) ...[
                Text(hint, style: TextStyle(color: t.bone, fontSize: 14)),
                const SizedBox(height: 12),
              ],
              SelectableText(
                message,
                style: TextStyle(
                  color: hint == null ? t.bone : t.rust,
                  fontSize: hint == null ? 14 : 12,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: message));
              if (!context.mounted) return;
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
                content: Text('Error message copied'),
                duration: Duration(seconds: 2),
              ));
            },
            child: const Text('Copy'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      );
    },
  );
}
