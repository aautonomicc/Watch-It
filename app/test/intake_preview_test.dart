import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/intake_draft.dart';
import 'package:watchit/screens/intake_screen.dart';
import 'package:watchit/services/intake_store.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/theme/tokens.dart' show WiTokens, wiTheme;

/// Manual-intake preview with the REAL Latvian festival register
/// (Downloads/Watch-Media-Intake/Latvian-festival/source-register.json):
/// drives the whole intake flow against those files' names, sizes and
/// source URLs at laptop and phone sizes. No file bytes are read, nothing
/// uploads, no network is available to the flow — saving drafts is
/// device-local by construction.
const _festival = [
  (
    name: 'G94Q8TbFnIA.mp4',
    title: 'MĒS UZKĀPĀM KALNIŅĀ | Deju lieluzvedums "Mūžīgais dzinējs"',
    bytes: 145274057,
    source: 'https://www.youtube.com/watch?v=G94Q8TbFnIA',
    creator: 'LSM info',
  ),
  (
    name: 'WeovGfNEEsk.mp4',
    title:
        'Saule, Pērkons, Daugava - XXV Dziesmu svētku un XV Deju svētku '
        'noslēguma koncerts. 07.07.13',
    bytes: 32374904,
    source: 'https://www.youtube.com/watch?v=WeovGfNEEsk',
    creator: 'Agita Baranova (AgitaBaranova)',
  ),
];

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  for (final (w, h, label) in [
    (1280.0, 800.0, 'laptop'),
    (390.0, 844.0, 'phone'),
  ]) {
    testWidgets('festival intake preview renders and saves at $label size',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()),
      );
      tester.view.physicalSize = Size(w, h);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: IntakeScreen(
          filesPicker: () async => [
            for (final f in _festival)
              (name: f.name, path: '/preview/${f.name}', size: f.bytes),
          ],
        ),
      ));
      await tester.pumpAndSettle();

      // Both festival files come in as review cards with their names.
      await tester.tap(find.text('Choose media files'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('intake-title')), findsAtLeastNWidgets(1));
      expect(tester.takeException(), isNull);

      // Review card one: type the real title, creator and source URL.
      await tester.enterText(
        find.byKey(const ValueKey('intake-title')).first,
        _festival[0].title,
      );
      await tester.enterText(
        find.byKey(const ValueKey('intake-creator')).first,
        _festival[0].creator,
      );
      await tester.enterText(
        find.byKey(const ValueKey('intake-url')).first,
        _festival[0].source,
      );
      await tester.enterText(
        find.byKey(const ValueKey('intake-language')).first,
        'Latvian',
      );
      await tester.ensureVisible(find.text('Save draft').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save draft').first);
      await tester.pumpAndSettle();

      // Review card two keeps its file name as the title; blank fields
      // stay blank (unknown details, not invented). Scroll it into view
      // first — ListView children build lazily.
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('intake-url')), 200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(
        find.byKey(const ValueKey('intake-title')).first,
        _festival[1].title,
      );
      await tester.enterText(
        find.byKey(const ValueKey('intake-url')).first,
        _festival[1].source,
      );
      await tester.ensureVisible(find.text('Save draft').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save draft').first);
      await tester.pumpAndSettle();

      expect(find.text('REVIEW'), findsNothing);
      final saved = await IntakeStore.loadAll();
      expect(saved, hasLength(2));
      final byLabel = {for (final d in saved) d.label: d};
      expect(byLabel[_festival[0].title]!.credits.creator,
          _festival[0].creator);
      expect(byLabel[_festival[0].title]!.credits.sourceUrl,
          _festival[0].source);
      expect(byLabel[_festival[0].title]!.language, 'Latvian');
      expect(byLabel[_festival[0].title]!.sizeBytes, 145274057);
      expect(byLabel[_festival[1].title]!.credits.creator, '');
      expect(byLabel[_festival[1].title]!.credits.sourceUrl,
          _festival[1].source);

      // The saved rows render at this size with no layout errors.
      expect(find.text(_festival[0].title), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a pasted festival link stays a reference record', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await LibraryStore.useForTesting(
      AppDatabase.forTesting(NativeDatabase.memory()),
    );
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: const IntakeScreen(),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('intake-link-field')),
      _festival[1].source,
    );
    await tester.tap(find.byIcon(Icons.add_link));
    await tester.pumpAndSettle();
    expect(find.text('REVIEW'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('intake-title')),
      _festival[1].title,
    );
    await tester.ensureVisible(find.text('Save draft'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save draft'));
    await tester.pumpAndSettle();

    final saved = await IntakeStore.loadAll();
    expect(saved.single.kind, IntakeDraft.kindLink);
    expect(saved.single.sourceUrl, _festival[1].source);
    expect(saved.single.localPath, isNull);
    expect(find.text('Reference link'), findsOneWidget);
  });
}
