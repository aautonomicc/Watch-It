import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/main.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/services/app_settings.dart';
import 'package:watchit/services/home_sections.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata_service.dart';
import 'package:watchit/services/watch_state.dart';
import 'package:watchit/services/terms.dart';
import 'package:watchit/theme/tokens.dart';

String _addr(int i) => i.toRadixString(16).padLeft(64, '0');

/// Base prefs: skip seeding and the TMDB nudge banner so the wall holds
/// exactly what each test stores.
const _basePrefs = {
  'defaults_seeded_v4': true,
      'terms_accepted_version_v1': kTermsVersion,
  'tmdb_nudge_dismissed_v1': true,
};

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() async {
    SharedPreferences.setMockInitialValues(_basePrefs);
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    MetadataService.instance = MetadataService(apiKeyProvider: () async => '');
    WatchStateStore.instance = WatchStateStore();
  });

  // Seeded inside the test body — see home_rows_flow_test.dart for why
  // warming drift in setUp deadlocks the fake-async zone.
  Future<void> seedLibrary() => LibraryStore.save([
        MediaList(id: 'a', title: 'Alpha', entries: [
          MediaEntry(name: 'Alpha.Movie.2020.mkv', address: _addr(1)),
        ]),
        MediaList(id: 'b', title: 'Beta', entries: [
          MediaEntry(name: 'Beta.Movie.2021.mkv', address: _addr(2)),
        ]),
      ]);

  double dy(WidgetTester tester, String text) =>
      tester.getTopLeft(find.text(text)).dy;

  testWidgets('stored section order reorders the wall', (tester) async {
    SharedPreferences.setMockInitialValues({
      ..._basePrefs,
      'home_sections_v1': encodeHomeSections(const [
        HomeSection(id: 'list:b'),
        HomeSection(id: 'list:a'),
        HomeSection(id: 'recent'),
        HomeSection(id: 'continue'),
        HomeSection(id: 'downloads'),
      ]),
    });
    await seedLibrary();
    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();

    expect(dy(tester, 'Beta'), lessThan(dy(tester, 'Alpha')));
  });

  testWidgets('hidden special row stays off the wall', (tester) async {
    SharedPreferences.setMockInitialValues({
      ..._basePrefs,
      'home_sections_v1': encodeHomeSections(const [
        HomeSection(id: 'continue'),
        HomeSection(id: 'downloads'),
        HomeSection(id: 'recent', visible: false),
      ]),
    });
    await seedLibrary();
    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();

    // Entries were just saved, so Recently Added would show by default.
    expect(find.text('Recently Added'), findsNothing);
    expect(find.text('Alpha'), findsOneWidget);
  });

  testWidgets('Media screen toggles and reorders home rows', (tester) async {
    // Tall surface: the Media page's header paragraphs push the rows
    // down, and off-screen ListView children are never built.
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await seedLibrary();
    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();

    // Default order: Recently Added tops the wall.
    expect(dy(tester, 'Recently Added'), lessThan(dy(tester, 'Alpha')));

    await tester.tap(find.byTooltip('Browse lists'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Media'));
    await tester.pumpAndSettle();

    // All six home rows are listed, even the currently-empty built-in
    // ones — the Media page now owns order and visibility.
    for (final title in [
      'Continue Watching',
      'Favourites',
      'Downloads',
      'Recently Added',
      'Alpha',
      'Beta',
    ]) {
      expect(find.widgetWithText(ListTile, title), findsOneWidget);
    }

    // Built-in rows are shaded lighter than list rows to mark that they
    // are not actual lists.
    final specialTile = tester.widget<ListTile>(
        find.widgetWithText(ListTile, 'Recently Added'));
    expect(specialTile.tileColor, WiTokens.dark.ink2);
    final listTile =
        tester.widget<ListTile>(find.widgetWithText(ListTile, 'Alpha'));
    expect(listTile.tileColor, isNull);

    // Hide Recently Added.
    await tester.tap(find.descendant(
      of: find.widgetWithText(ListTile, 'Recently Added'),
      matching: find.byType(Checkbox),
    ));
    await tester.pumpAndSettle();

    // Drag Beta above Alpha by its handle.
    final handle = find.descendant(
      of: find.widgetWithText(ListTile, 'Beta'),
      matching: find.byIcon(Icons.drag_handle),
    );
    final delta = tester.getCenter(find.widgetWithText(ListTile, 'Alpha')).dy -
        tester.getCenter(find.widgetWithText(ListTile, 'Beta')).dy;
    await tester.timedDrag(
        handle, Offset(0, delta - 10), const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    // Both changes persisted.
    final stored = await AppSettings.homeSections();
    final ids = [for (final s in stored) s.id];
    expect(ids.indexOf('list:b'), lessThan(ids.indexOf('list:a')));
    expect(stored.firstWhere((s) => s.id == 'recent').visible, isFalse);

    // Back to home: hidden row gone, lists in the new order.
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Recently Added'), findsNothing);
    expect(dy(tester, 'Beta'), lessThan(dy(tester, 'Alpha')));
  });

  testWidgets('unticking a list row writes MediaList.enabled',
      (tester) async {
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await seedLibrary();
    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Browse lists'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Media'));
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(
      of: find.widgetWithText(ListTile, 'Beta'),
      matching: find.byType(Checkbox),
    ));
    await tester.pumpAndSettle();

    // The shared flag flipped — the Media Lists screen sees it too.
    final lists = await LibraryStore.load();
    expect(lists.firstWhere((l) => l.id == 'b').enabled, isFalse);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Beta'), findsNothing);
    expect(find.text('Alpha'), findsOneWidget);
  });
}
