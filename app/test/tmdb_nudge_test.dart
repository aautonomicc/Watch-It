import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/services/app_settings.dart';
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
}
