import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter/foundation.dart' show LicenseRegistry;

import 'package:watchit/db/app_database.dart';
import 'package:watchit/screens/settings_screen.dart';
import 'package:watchit/services/bundle.dart' show kTmdbAttributionNotice;
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/licenses.dart';
import 'package:watchit/services/storage_usage.dart';
import 'package:watchit/theme/tokens.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
  });

  tearDown(() => debugAppDataDirOverride = null);

  Future<void> pumpSettings(WidgetTester tester) async {
    // Tall surface so the About section is on screen without scrolling
    // (a lazily built ListView never creates off-screen tiles).
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: const SettingsScreen(),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('About shows the size-on-disk tile', (tester) async {
    // Sync I/O only — async dart:io never completes in the fake-async
    // test zone.
    final tmp = Directory.systemTemp.createTempSync('wi-size-test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    File('${tmp.path}/blob.bin').writeAsBytesSync(List.filled(2048, 7));
    debugAppDataDirOverride = tmp;
    await pumpSettings(tester);
    expect(find.text('Size on disk'), findsOneWidget);
    // The size comes from a real directory walk; runAsync lets that I/O
    // complete, then a pump renders the result.
    var found = false;
    for (var i = 0; i < 50 && !found; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      found = find.textContaining('2 KB').evaluate().isNotEmpty;
    }
    expect(find.textContaining('2 KB'), findsOneWidget);
  });

  testWidgets('About shows the TMDB attribution notice and logo',
      (tester) async {
    await pumpSettings(tester);
    expect(find.text(kTmdbAttributionNotice), findsOneWidget);
    expect(
      find.byWidgetPredicate((w) =>
          w is Image &&
          w.image is AssetImage &&
          (w.image as AssetImage).assetName == 'assets/tmdb_logo.png'),
      findsOneWidget,
    );
  });

  testWidgets('About shows the open-source licenses tile and opens the '
      'license page', (tester) async {
    await pumpSettings(tester);
    expect(find.text('Open-source licenses'), findsOneWidget);
    expect(find.textContaining('distributed under GPLv3'), findsOneWidget);
    await tester.tap(find.text('Open-source licenses'));
    // No pumpAndSettle: the page's loading spinner animates forever until
    // the license collectors finish, which they never do in fake-async.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(LicensePage), findsOneWidget);
  });

  testWidgets('registered native licenses carry the GPL text for '
      'self_encryption plus the media and font notices', (tester) async {
    registerNativeLicenses();
    // runAsync: the collector loads the GPL/OFL texts from the asset
    // bundle, which is real async I/O the fake-async zone would deadlock.
    final entries = await tester.runAsync(
        () => LicenseRegistry.licenses.toList());
    final byPackage = {
      for (final e in entries!)
        for (final p in e.packages) p: e.paragraphs.toList(),
    };
    expect(byPackage, contains('self_encryption'));
    expect(
      byPackage['self_encryption']!
          .any((p) => p.text.contains('GNU GENERAL PUBLIC LICENSE')),
      isTrue,
    );
    expect(byPackage, contains('W@tch'));
    expect(byPackage, contains('libmpv'));
    expect(byPackage, contains('FFmpeg'));
    expect(byPackage, contains('watchit_core Rust crates'));
    expect(byPackage, contains('Anton font'));
    expect(
      byPackage['Anton font']!
          .any((p) => p.text.contains('SIL OPEN FONT LICENSE')),
      isTrue,
    );
  });

  testWidgets('Clear all data needs two confirmations and can be backed '
      'out of both', (tester) async {
    await pumpSettings(tester);
    await tester.tap(find.text('Clear all data'));
    await tester.pumpAndSettle();
    // First warning: what gets deleted.
    expect(find.text('Clear all data?'), findsOneWidget);
    expect(find.textContaining('all media lists'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Clear all data?'), findsNothing);
    // Through the first warning into the second, then back out.
    await tester.tap(find.text('Clear all data'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Are you sure?'), findsOneWidget);
    expect(find.textContaining('no way to get them back'), findsOneWidget);
    await tester.tap(find.text('Keep my data'));
    await tester.pumpAndSettle();
    expect(find.text('Are you sure?'), findsNothing);
    // Nothing was deleted: the store still answers.
    expect(await LibraryStore.load(), isEmpty);
  });
}
