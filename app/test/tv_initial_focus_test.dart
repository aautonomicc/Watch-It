import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:watchit/services/tv_settings.dart';
import 'package:watchit/widgets/tv_dpad_focus.dart';

/// TvInitialFocus: on TV a pushed screen must open with a visible focus
/// (TvFocusFrame paints nothing while only the route's scope is focused,
/// so screens opened "dark" and the first D-pad press hunted in from a
/// screen edge — tester report).
void main() {
  tearDown(() => TvSettings.instance = TvSettings());

  Future<void> push(WidgetTester tester, Widget screen) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => screen)),
            child: const Text('go'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
  }

  Widget screen({bool autofocusSecond = false}) => TvInitialFocus(
        child: Scaffold(
          body: Column(children: [
            ElevatedButton(onPressed: () {}, child: const Text('first')),
            ElevatedButton(
              autofocus: autofocusSecond,
              onPressed: () {},
              child: const Text('second'),
            ),
          ]),
        ),
      );

  FocusNode nodeOf(WidgetTester tester, String label) =>
      Focus.of(tester.element(find.text(label)));

  testWidgets('TV: a pushed screen starts with its first control focused',
      (tester) async {
    TvSettings.instance = TvSettings(enabled: true);
    await push(tester, screen());
    expect(nodeOf(tester, 'first').hasPrimaryFocus, isTrue);
  });

  testWidgets('an explicit autofocus on the screen wins over the wrapper',
      (tester) async {
    TvSettings.instance = TvSettings(enabled: true);
    await push(tester, screen(autofocusSecond: true));
    expect(nodeOf(tester, 'second').hasPrimaryFocus, isTrue);
    expect(nodeOf(tester, 'first').hasPrimaryFocus, isFalse);
  });

  testWidgets('off TV the wrapper does nothing — no stray focus ring',
      (tester) async {
    await push(tester, screen());
    expect(nodeOf(tester, 'first').hasPrimaryFocus, isFalse);
    expect(nodeOf(tester, 'second').hasPrimaryFocus, isFalse);
  });
}
