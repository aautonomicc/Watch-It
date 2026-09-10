import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/models/media_list.dart';
import 'package:watchit/services/metadata_service.dart';
import 'package:watchit/theme/tokens.dart';
import 'package:watchit/widgets/poster_cards.dart';

// Android TV / keyboard navigation: wall cards draw their own focus
// ring (WiCardInk) because InkWell's ink highlights paint behind the
// opaque poster image, and D-pad select must activate the focused card.

String _addr(int i) => i.toRadixString(16).padLeft(64, '0');

MediaEntry _entry(int i, String name) =>
    MediaEntry(name: name, address: _addr(i));

Finder _ring() => find.byWidgetPredicate((w) {
      if (w is! Container) return false;
      final deco = w.foregroundDecoration;
      if (deco is! BoxDecoration) return false;
      final border = deco.border;
      return border is Border && border.top.color == WiTokens.dark.accent;
    });

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'defaults_seeded_v4': true});
    MetadataService.instance = MetadataService(apiKeyProvider: () async => '');
  });

  Widget page(Widget body) => MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: Scaffold(body: body),
      );

  Widget twoCards({VoidCallback? onFirst, VoidCallback? onSecond}) => Row(
        children: [
          PosterCard(
            entry: _entry(1, 'First Film (2001).mp4'),
            tokens: WiTokens.dark,
            onTap: onFirst ?? () {},
          ),
          PosterCard(
            entry: _entry(2, 'Second Film (2002).mp4'),
            tokens: WiTokens.dark,
            onTap: onSecond ?? () {},
          ),
        ],
      );

  testWidgets('focused card shows the accent ring, unfocused shows none',
      (tester) async {
    await tester.pumpWidget(page(twoCards()));
    await tester.pump();
    expect(_ring(), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(_ring(), findsOneWidget);

    // Focus moving on never leaves a stale ring behind.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(_ring(), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('D-pad select activates the focused card', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(page(twoCards(onFirst: () => tapped++)));
    await tester.pump();

    // Select with nothing focused does nothing.
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(tapped, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(tapped, 1);
    await tester.pumpAndSettle();
  });

  testWidgets('arrow keys move focus between cards (D-pad traversal)',
      (tester) async {
    var first = 0;
    var second = 0;
    await tester.pumpWidget(page(
        twoCards(onFirst: () => first++, onSecond: () => second++)));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(first, 0);
    expect(second, 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(first, 1);
    expect(second, 1);
    await tester.pumpAndSettle();
  });
}
