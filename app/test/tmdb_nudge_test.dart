import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/main.dart';
import 'package:watchit/screens/settings_screen.dart';
import 'package:watchit/services/app_settings.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata_service.dart';
import 'package:watchit/services/terms.dart';
import 'package:watchit/services/watch_state.dart';
import 'package:watchit/theme/tokens.dart';
import 'package:watchit/widgets/tmdb_nudge.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('shouldShowTmdbNudge', () {
    test('shown when keyless and not dismissed', () async {
      expect(await shouldShowTmdbNudge(), isTrue);
    });

    test('hidden once a user key is set', () async {
      await AppSettings.setTmdbApiKey('my-key');
      expect(await shouldShowTmdbNudge(), isFalse);
    });

    test('hidden after dismissal, even keyless', () async {
      await AppSettings.setTmdbNudgeDismissed();
      expect(await shouldShowTmdbNudge(), isFalse);
    });
  });

  testWidgets('banner renders and routes both taps', (tester) async {
    var settingsOpened = false;
    var dismissed = false;
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: Scaffold(
        body: TmdbNudgeBanner(
          onOpenSettings: () => settingsOpened = true,
          onDismiss: () => dismissed = true,
        ),
      ),
    ));
    expect(find.textContaining('TMDB API key'), findsOneWidget);

    await tester.tap(find.textContaining('TMDB API key'));
    expect(settingsOpened, isTrue);
    expect(dismissed, isFalse);

    await tester.tap(find.byIcon(Icons.close));
    expect(dismissed, isTrue);
  });

  // The TV-remote regression: the whole bar is the natural Select
  // target, so tapping it must count as acknowledged — before this,
  // only the small close button dismissed and the banner came back on
  // every return to the home screen.
  testWidgets('tapping the banner opens Settings and dismisses for good',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'defaults_seeded_v4': true,
      'terms_accepted_version_v1': kTermsVersion,
    });
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    MetadataService.instance = MetadataService(apiKeyProvider: () async => '');
    WatchStateStore.instance = WatchStateStore();

    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();
    expect(find.textContaining('TMDB API key'), findsOneWidget);

    await tester.tap(find.textContaining('TMDB API key'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('tmdb_nudge_dismissed_v1'), isTrue);

    // Back on the home screen the banner stays gone.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.textContaining('TMDB API key'), findsNothing);
  });
}
