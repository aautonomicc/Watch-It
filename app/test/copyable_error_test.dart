import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchit/theme/tokens.dart';
import 'package:watchit/widgets/copyable_error.dart';

void main() {
  final copied = <String>[];

  setUp(() {
    copied.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('tapping an error snackbar copies the full message and '
      'confirms in place', (tester) async {
    const message = 'Backup failed: the Trezor\'s payment signature did '
        'not verify: a long error worth copying whole';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => ScaffoldMessenger.of(context)
                .showSnackBar(copyableErrorSnackBar(message)),
            child: const Text('boom'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('boom'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Tap to copy'), findsOneWidget);

    await tester.tap(find.text(message));
    await tester.pump();
    expect(copied, [message], reason: 'the whole error lands on the clipboard');
    expect(find.text('Copied to clipboard'), findsOneWidget);
    expect(find.text('Tap to copy'), findsNothing);

    // Let the (10s) error snackbar time out so no timers leak.
    await tester.pumpAndSettle(const Duration(seconds: 11));
  });

  testWidgets('tapping an inline error line copies it and confirms with '
      'a snackbar', (tester) async {
    const message = 'Could not read the backup state: boom';
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: const Scaffold(body: CopyableErrorText(message)),
    ));
    expect(find.text(message), findsOneWidget);

    await tester.tap(find.text(message));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(copied, [message]);
    expect(find.text('Error message copied'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });

  test('an underfunded wallet gets a plain-words line in ANT', () {
    final hint = fundsHintFor('paying for the backup failed: Insufficient '
        'tokens to pay for quotes. Have: 0 atto, need: 514836038085937500 '
        'atto');
    expect(hint, contains('0.514836 ANT'));
    expect(hint, contains('has 0 ANT'));
    expect(fundsHintFor('insufficient funds for gas * price + value'),
        contains('ETH'));
    expect(fundsHintFor('cancelled on the Trezor'), isNull);
  });

  testWidgets('an error dialog stays until acknowledged, explains a '
      'funds shortfall and copies the raw error', (tester) async {
    const message = 'Insufficient tokens to pay for quotes. Have: 0 atto, '
        'need: 514836038085937500 atto';
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showErrorDialog(Navigator.of(context),
                title: 'Backup failed', message: message),
            child: const Text('go'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('Backup failed'), findsOneWidget);
    expect(find.textContaining('0.514836 ANT'), findsOneWidget);
    expect(find.text(message), findsOneWidget);
    // Unlike the old snackbar it does not time out or close on a tap
    // outside.
    await tester.pump(const Duration(minutes: 5));
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('Backup failed'), findsOneWidget);
    await tester.tap(find.text('Copy'));
    await tester.pump();
    expect(copied, [message]);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Backup failed'), findsNothing);
  });
}
