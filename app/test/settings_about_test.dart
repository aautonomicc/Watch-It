import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter/foundation.dart' show LicenseRegistry;

import 'package:watchit/db/app_database.dart';
import 'package:watchit/screens/settings_screen.dart';
import 'package:watchit/screens/terms_screen.dart';
import 'package:watchit/services/app_settings.dart';
import 'package:watchit/services/bundle.dart' show kTmdbAttributionNotice;
import 'package:watchit/services/impeller.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/licenses.dart';
import 'package:watchit/services/storage_usage.dart';
import 'package:watchit/services/update_check.dart';
import 'package:watchit/theme/tokens.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LibraryStore.useForTesting(
      AppDatabase.forTesting(NativeDatabase.memory()),
    );
  });

  tearDown(() => debugAppDataDirOverride = null);

  Future<void> pumpSettings(WidgetTester tester) async {
    // Tall surface so the About section is on screen without scrolling
    // (a lazily built ListView never creates off-screen tiles).
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: const SettingsScreen(),
      ),
    );
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
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      found = find.textContaining('2 KB').evaluate().isNotEmpty;
    }
    expect(find.textContaining('2 KB'), findsOneWidget);
  });

  testWidgets('About shows the TMDB attribution notice and logo', (
    tester,
  ) async {
    await pumpSettings(tester);
    expect(find.text(kTmdbAttributionNotice), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is Image &&
            w.image is AssetImage &&
            (w.image as AssetImage).assetName == 'assets/tmdb_logo.png',
      ),
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

  testWidgets('About shows the terms tile and opens the read-only terms '
      'page', (tester) async {
    await pumpSettings(tester);
    expect(find.text('Terms of Use & Disclaimer'), findsOneWidget);
    await tester.tap(find.text('Terms of Use & Disclaimer'));
    await tester.pumpAndSettle();
    expect(find.byType(TermsScreen), findsOneWidget);
    // Read-only: no accept bar, back navigation present.
    expect(find.text('I agree'), findsNothing);
    expect(find.byType(BackButton), findsOneWidget);
  });

  testWidgets('registered native licenses carry the GPL text for '
      'self_encryption plus the media and font notices', (tester) async {
    registerNativeLicenses();
    // runAsync: the collector loads the GPL/OFL texts from the asset
    // bundle, which is real async I/O the fake-async zone would deadlock.
    final entries = await tester.runAsync(
      () => LicenseRegistry.licenses.toList(),
    );
    final byPackage = {
      for (final e in entries!)
        for (final p in e.packages) p: e.paragraphs.toList(),
    };
    expect(byPackage, contains('self_encryption'));
    expect(
      byPackage['self_encryption']!.any(
        (p) => p.text.contains('GNU GENERAL PUBLIC LICENSE'),
      ),
      isTrue,
    );
    expect(byPackage, contains('W@tch'));
    expect(byPackage, contains('libmpv'));
    expect(byPackage, contains('FFmpeg'));
    expect(byPackage, contains('watchit_core Rust crates'));
    expect(byPackage, contains('Anton font'));
    expect(
      byPackage['Anton font']!.any(
        (p) => p.text.contains('SIL OPEN FONT LICENSE'),
      ),
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

  testWidgets('About: update toggle persists; available update shows a row', (
    tester,
  ) async {
    UpdateCheck.resetForTesting();
    addTearDown(UpdateCheck.resetForTesting);
    await pumpSettings(tester);
    expect(find.text('Check for updates on startup'), findsOneWidget);
    expect(find.text('Update available'), findsNothing);

    await tester.tap(find.text('Check for updates on startup'));
    await tester.pumpAndSettle();
    expect(await UpdateCheck.enabled(), false);

    UpdateCheck.instance.availableTag = 'v0.1.0-alpha.99';
    UpdateCheck.instance.releaseUrl = UpdateCheck.releasePage;
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    UpdateCheck.instance.notifyListeners();
    await tester.pump();
    expect(find.text('Update available'), findsOneWidget);
    expect(find.textContaining('v0.1.0-alpha.99'), findsOneWidget);
  });

  testWidgets('Software video decoding toggle persists and defaults off', (
    tester,
  ) async {
    expect(await AppSettings.softwareVideoDecode(), false);
    await pumpSettings(tester);
    final tile = find.text('Software video decoding');
    await tester.ensureVisible(tile);
    await tester.pump();
    expect(tile, findsOneWidget);
    // Below Buffer size — the playback pair stays together.
    expect(
      tester.getTopLeft(tile).dy,
      greaterThan(tester.getTopLeft(find.text('Buffer size')).dy),
    );

    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(await AppSettings.softwareVideoDecode(), true);

    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(await AppSettings.softwareVideoDecode(), false);
  });

  testWidgets('Graphics compatibility toggle stores an explicit choice', (
    tester,
  ) async {
    addTearDown(() => ImpellerSettings.deviceDefaultOff = false);
    ImpellerSettings.deviceDefaultOff = false;
    await pumpSettings(tester);
    final tile = find.text('Graphics compatibility mode');
    await tester.ensureVisible(tile);
    await tester.pump();
    // Directly below its sibling escape hatch.
    expect(
      tester.getTopLeft(tile).dy,
      greaterThan(tester.getTopLeft(find.text('Software video decoding')).dy),
    );
    expect(
      tester
          .widget<SwitchListTile>(
            find.ancestor(of: tile, matching: find.byType(SwitchListTile)),
          )
          .value,
      false,
    );

    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(await ImpellerSettings.explicit(), true);
    expect(await ImpellerSettings.effectiveDisabled(), true);

    await tester.tap(tile);
    await tester.pumpAndSettle();
    // An explicit false is stored, not removed — it must keep beating a
    // Tegra device default.
    expect(await ImpellerSettings.explicit(), false);
  });

  testWidgets('Graphics compatibility defaults on for Tegra devices', (
    tester,
  ) async {
    addTearDown(() => ImpellerSettings.deviceDefaultOff = false);
    ImpellerSettings.deviceDefaultOff = true;
    await pumpSettings(tester);
    final tile = find.text('Graphics compatibility mode');
    await tester.ensureVisible(tile);
    await tester.pump();
    expect(
      tester
          .widget<SwitchListTile>(
            find.ancestor(of: tile, matching: find.byType(SwitchListTile)),
          )
          .value,
      true,
    );
    expect(
      find.textContaining('turned on automatically for this device'),
      findsOneWidget,
    );
    // No explicit pref yet — the ON state is the device default.
    expect(await ImpellerSettings.explicit(), null);
    expect(await ImpellerSettings.effectiveDisabled(), true);

    // Switching it off writes an explicit false that overrides Tegra.
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(await ImpellerSettings.explicit(), false);
    expect(await ImpellerSettings.effectiveDisabled(), false);
  });

  test('effectiveDisabled: explicit choice beats the device default', () async {
    addTearDown(() => ImpellerSettings.deviceDefaultOff = false);
    ImpellerSettings.deviceDefaultOff = true;
    expect(await ImpellerSettings.effectiveDisabled(), true);
    await ImpellerSettings.setDisabled(false);
    expect(await ImpellerSettings.effectiveDisabled(), false);
    ImpellerSettings.deviceDefaultOff = false;
    await ImpellerSettings.setDisabled(true);
    expect(await ImpellerSettings.effectiveDisabled(), true);
  });
}
