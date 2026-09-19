import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:watchit/services/tv_settings.dart';
import 'package:watchit/theme/tokens.dart';
import 'package:watchit/widgets/join_link_dialog.dart';

void main() {
  tearDown(() {
    TvSettings.instance = TvSettings();
  });

  // Opens the dialog and exposes what it eventually pops with.
  final popped = <(String, String)?>[];

  Future<void> show(WidgetTester tester,
      {Future<String?> Function()? onScanQr}) async {
    popped.clear();
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: Builder(
        builder: (context) => Center(
          child: FilledButton(
            onPressed: () async {
              popped.add(await showDialog<(String, String)>(
                context: context,
                builder: (_) => JoinLinkDialog(
                  initialName: 'Living room',
                  onScanQr: onScanQr,
                ),
              ));
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  TextField inviteField(WidgetTester tester) => tester
      .widget<TextField>(find.widgetWithText(TextField, 'Invite code'));

  testWidgets('invite field is code-shaped: monospace, no autocorrect, '
      'Enter submits normalized lowercase', (tester) async {
    await show(tester);

    final field = inviteField(tester);
    expect(field.autocorrect, isFalse);
    expect(field.enableSuggestions, isFalse);
    expect(field.style?.fontFamily, 'monospace');

    // TV remotes and shouty paste sources capitalize freely — the code
    // pops trimmed and lowercased, and Enter submits without hunting
    // for the Join button.
    await tester.enterText(
        find.widgetWithText(TextField, 'Invite code'), ' WTCH1-ABCDEF ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(popped, [('Living room', 'wtch1-abcdef')]);
  });

  testWidgets('Join without a code keeps the dialog open and moves focus '
      'into the invite field', (tester) async {
    await show(tester);
    await tester.tap(find.text('Join'));
    await tester.pumpAndSettle();
    expect(popped, isEmpty);
    expect(find.text('Join with invite code'), findsOneWidget);
    final focused = FocusManager.instance.primaryFocus;
    final field = find.widgetWithText(TextField, 'Invite code');
    expect(tester.widget<TextField>(field).focusNode, focused);
  });

  testWidgets('on TV: no field autofocus (no surprise IME), Join takes '
      'initial focus, scan button absent even if a scanner exists',
      (tester) async {
    TvSettings.instance = TvSettings(enabled: true);
    // The screen passes onScanQr: null on TV; belt-and-braces, the
    // dialog is exercised without one here.
    await show(tester);
    expect(inviteField(tester).autofocus, isFalse);
    final join = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Join'));
    expect(join.autofocus, isTrue);
    expect(find.text('Scan QR code'), findsNothing);
  });

  testWidgets('off TV: invite field autofocuses and a provided scanner '
      'shows and fills the field', (tester) async {
    await show(tester, onScanQr: () async => 'wtch1-feedbeef');
    expect(inviteField(tester).autofocus, isTrue);
    await tester.tap(find.text('Scan QR code'));
    await tester.pumpAndSettle();
    expect(find.text('wtch1-feedbeef'), findsOneWidget);
  });
}
