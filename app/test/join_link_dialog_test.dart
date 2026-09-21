import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    expect(find.text('Enter an invite code'), findsOneWidget);
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

  testWidgets('on TV: a vertical arrow LEAVES a field — the D-pad is '
      'never trapped below the Join button (tester report)', (tester) async {
    TvSettings.instance = TvSettings(enabled: true);
    await show(tester);

    // The trap state: focus wandered down into the invite field. A plain
    // TextField consumes all four arrows as caret movement, so no arrow
    // ever escaped and Join was unreachable until the app was killed.
    await tester.tap(find.widgetWithText(TextField, 'Invite code'));
    await tester.pump();
    final invite = inviteField(tester);
    expect(invite.focusNode!.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(invite.focusNode!.hasFocus, isFalse,
        reason: 'arrow-down must escape the invite field on TV');

    // Same for the topmost field, where the IME-dismiss asymmetry
    // stranded the focus (down from the scope lands on it).
    await tester.tap(find.widgetWithText(TextField, 'Device name'));
    await tester.pump();
    final name = tester
        .widget<TextField>(find.widgetWithText(TextField, 'Device name'));
    expect(name.focusNode!.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(name.focusNode!.hasFocus, isFalse,
        reason: 'arrow-down must escape the name field on TV');
    // Nothing typed/popped by the traversal keys.
    expect(popped, isEmpty);
  });

  testWidgets('off TV: arrows stay caret movement inside a field',
      (tester) async {
    await show(tester);
    await tester.enterText(
        find.widgetWithText(TextField, 'Invite code'), 'wtch1-abc');
    final invite = inviteField(tester);
    expect(invite.focusNode!.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    // Desktop keyboards edit with arrows — the escape is TV-only.
    expect(invite.focusNode!.hasFocus, isTrue);
  });
}
