import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/screens/detail_screen.dart';
import 'package:watchit/screens/season_screen.dart';
import 'package:watchit/screens/show_screen.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata_service.dart';
import 'package:watchit/services/season_grouping.dart';
import 'package:watchit/theme/tokens.dart';

const _addr =
    'a3f1c9e07b6d5a4f2e8c1b0d9f7a6e5c4b3a2d1e0f9c8b7a6d5e4f3c2b1a0d9e';

MediaEntry _e(String name) => MediaEntry(name: name, address: _addr);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    // Offline: no API key, so screens render from parsed file names.
    MetadataService.instance = MetadataService(apiKeyProvider: () async => '');
  });

  Widget app(Widget home) => MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: home,
      );

  testWidgets('show page lists seasons; tapping opens season then episode',
      (tester) async {
    final entries = [
      _e('Show.S01E01.mkv'),
      _e('Show.S01E02.mkv'),
      _e('Show.S02E01.mkv'),
    ];
    await tester
        .pumpWidget(app(ShowScreen(seasons: showSeasons(entries, 'Show'))));
    await tester.pumpAndSettle();

    // Show page: one tile per season in the library.
    expect(find.text('SEASONS'), findsOneWidget);
    expect(find.text('Season 1'), findsOneWidget);
    expect(find.text('Season 2'), findsOneWidget);
    expect(find.text('2 episodes'), findsOneWidget);
    expect(find.text('1 episode'), findsOneWidget);

    // Season page: header + one episode tile per file.
    await tester.ensureVisible(find.text('Season 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Season 1'));
    await tester.pumpAndSettle();
    expect(find.byType(SeasonScreen), findsOneWidget);
    expect(find.text('EPISODES'), findsOneWidget);
    expect(find.textContaining('Episode 1'), findsOneWidget);
    expect(find.textContaining('Episode 2'), findsOneWidget);

    // Episode tile opens the detail screen for playback.
    await tester.ensureVisible(find.textContaining('Episode 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Episode 1'));
    await tester.pumpAndSettle();
    expect(find.byType(DetailScreen), findsOneWidget);
    expect(find.text('Play'), findsOneWidget);
  });
}
