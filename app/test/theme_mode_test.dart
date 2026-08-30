import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/main.dart';
import 'package:watchit/services/app_settings.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata_service.dart';
import 'package:watchit/services/terms.dart';
import 'package:watchit/services/watch_state.dart';
import 'package:watchit/theme/tokens.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'defaults_seeded_v4': true,
      'terms_accepted_version_v1': kTermsVersion,
      'tmdb_nudge_dismissed_v1': true,
    });
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    MetadataService.instance = MetadataService(apiKeyProvider: () async => '');
    WatchStateStore.instance = WatchStateStore();
    // The notifier is app-global — reset the previous test's choice.
    wiThemeMode.value = ThemeMode.dark;
  });

  group('AppSettings.themeMode', () {
    test('defaults to dark (the original look)', () async {
      expect(await AppSettings.themeMode(), ThemeMode.dark);
    });

    test('round-trips every choice', () async {
      for (final mode in ThemeMode.values) {
        await AppSettings.setThemeMode(mode);
        expect(await AppSettings.themeMode(), mode);
      }
    });

    test('garbage stored value falls back to dark', () async {
      SharedPreferences.setMockInitialValues({'theme_mode_v1': 'sepia'});
      expect(await AppSettings.themeMode(), ThemeMode.dark);
    });
  });

  testWidgets('app ships dark by default with a light theme on standby',
      (tester) async {
    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);
    expect(app.darkTheme!.brightness, Brightness.dark);
    expect(app.theme!.brightness, Brightness.light);
  });

  testWidgets('Settings → Colour scheme switches to light and persists',
      (tester) async {
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Browse lists'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    // Appearance sits below Metadata (2026-08-30) — bring it in.
    await tester.scrollUntilVisible(find.text('Colour scheme'), 100);
    await tester.ensureVisible(find.text('Colour scheme'));
    await tester.pumpAndSettle();
    expect(find.text('Colour scheme'), findsOneWidget);
    await tester.tap(find.text('Colour scheme'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();

    expect(wiThemeMode.value, ThemeMode.light);
    expect(await AppSettings.themeMode(), ThemeMode.light);
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.light);
    // The live theme actually flipped: light tokens now resolve.
    final context = tester.element(find.text('Colour scheme'));
    expect(WiTokens.of(context).ink, WiTokens.light.ink);
  });

  testWidgets('System default option is offered and persists',
      (tester) async {
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Browse lists'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Colour scheme'), 100);
    await tester.ensureVisible(find.text('Colour scheme'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Colour scheme'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('System default'));
    await tester.pumpAndSettle();

    expect(wiThemeMode.value, ThemeMode.system);
    expect(await AppSettings.themeMode(), ThemeMode.system);
  });
}
