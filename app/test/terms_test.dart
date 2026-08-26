import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/main.dart';
import 'package:watchit/screens/terms_screen.dart';
import 'package:watchit/services/app_settings.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/terms.dart';
import 'package:watchit/theme/tokens.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() async {
    // Skip default seeding so home shows the deterministic empty state.
    SharedPreferences.setMockInitialValues({'defaults_seeded_v4': true});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(const WatchItApp());
    // TermsGate reads the accepted version async; flush it in.
    await tester.pump();
    await tester.pump();
  }

  testWidgets('fresh install gates on the terms until accepted',
      (tester) async {
    await pumpApp(tester);

    // Gate is up: terms visible, home is not.
    expect(find.text('Terms of Use & Disclaimer'), findsOneWidget);
    expect(find.text('I agree'), findsOneWidget);
    expect(find.text('Exit'), findsOneWidget);
    expect(find.text('Your library is empty'), findsNothing);
    // No back button — the gate is not escapable.
    expect(find.byType(BackButton), findsNothing);

    await tester.tap(find.text('I agree'));
    await tester.pump();
    await tester.pump();

    // Home is through and the acceptance persisted.
    expect(find.text('Your library is empty'), findsOneWidget);
    expect(find.text('Terms of Use & Disclaimer'), findsNothing);
    expect(await AppSettings.termsAcceptedVersion(), kTermsVersion);
  });

  testWidgets('accepted install goes straight to home', (tester) async {
    SharedPreferences.setMockInitialValues({
      'defaults_seeded_v4': true,
      'terms_accepted_version_v1': kTermsVersion,
    });
    await pumpApp(tester);

    expect(find.text('Your library is empty'), findsOneWidget);
    expect(find.text('Terms of Use & Disclaimer'), findsNothing);
  });

  testWidgets('an older accepted version re-gates after a terms bump',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'defaults_seeded_v4': true,
      'terms_accepted_version_v1': kTermsVersion - 1,
    });
    await pumpApp(tester);

    expect(find.text('Terms of Use & Disclaimer'), findsOneWidget);
    expect(find.text('Your library is empty'), findsNothing);
  });

  testWidgets('read-only screen has back navigation and no accept bar',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const TermsScreen()),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Terms of Use & Disclaimer'), findsOneWidget);
    expect(find.text('I agree'), findsNothing);
    expect(find.text('Exit'), findsNothing);
    expect(find.byType(BackButton), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Terms of Use & Disclaimer'), findsNothing);
  });

  test('terms text covers the load-bearing clauses', () {
    final all = [
      kTermsIntro,
      for (final s in kTermsSections) '${s.title} ${s.body}',
    ].join(' ');
    // Anchor phrases the disclaimer must keep: no hosting/control,
    // user responsibility, permanence, wallet risk, no warranty,
    // liability cap.
    for (final phrase in [
      'do not host',
      'solely responsible',
      'permanent',
      '"hot" wallet',
      '"as is"',
      'not liable',
      'indemnify',
    ]) {
      expect(all.contains(phrase), isTrue,
          reason: 'terms must mention "$phrase"');
    }
  });
}
