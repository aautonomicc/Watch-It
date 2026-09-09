import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/main.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/screens/list_home_screen.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata_service.dart';
import 'package:watchit/services/terms.dart';
import 'package:watchit/services/watch_state.dart';
import 'package:watchit/widgets/brand_mark.dart';
import 'package:watchit/widgets/library_drawer.dart';

String _addr(int i) => i.toRadixString(16).padLeft(64, '0');

/// The home screen pins the library drawer open as a side panel on wide
/// desktop windows (burger far LEFT toggles it, persisted), and falls
/// back to the modal far-right-burger layout on narrow windows. These
/// tests run on a desktop host, so isDesktopPlatform is true — the
/// window width alone flips the two layouts.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'defaults_seeded_v4': true,
      'terms_accepted_version_v1': kTermsVersion,
    });
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    MetadataService.instance = MetadataService(
      apiKeyProvider: () async => '',
      postersDirProvider: () async => Directory.systemTemp,
    );
    WatchStateStore.instance = WatchStateStore();
  });

  Future<void> seedLibrary() => LibraryStore.save([
        MediaList(id: 'l1', title: 'Favourites', entries: [
          MediaEntry(name: 'Alpha (2020).mkv', address: _addr(1)),
        ]),
      ]);

  // Above kPinnedDrawerMinWindowWidth → the pinned layout.
  void wideWindow(WidgetTester tester) {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Finder inPanel(Finder matching) =>
      find.descendant(of: find.byType(WiLibraryDrawer), matching: matching);

  testWidgets(
      'wide desktop window pins the drawer open with the burger far left '
      'and search in the actions', (tester) async {
    wideWindow(tester);
    await seedLibrary();
    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();

    // Panel is present without opening anything.
    expect(find.byType(WiLibraryDrawer), findsOneWidget);
    expect(inPanel(find.text('Library')), findsOneWidget);
    expect(inPanel(find.text('Favourites')), findsOneWidget);

    // Burger far left of the brand lockup; search moved to the actions
    // (right of the title); no far-right modal burger.
    final burger = find.byTooltip('Hide library panel');
    expect(burger, findsOneWidget);
    expect(tester.getTopLeft(burger).dx,
        lessThan(tester.getTopLeft(find.byType(BrandMark)).dx));
    final search = find.byTooltip('Search');
    expect(search, findsOneWidget);
    expect(tester.getTopLeft(search).dx,
        greaterThan(tester.getTopLeft(find.byType(BrandMark)).dx));
    expect(find.byTooltip('Browse lists'), findsNothing);
  });

  testWidgets('the burger closes and reopens the pinned panel, persisted',
      (tester) async {
    wideWindow(tester);
    await seedLibrary();
    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Hide library panel'));
    await tester.pumpAndSettle();
    expect(find.byType(WiLibraryDrawer), findsNothing);
    expect(find.byTooltip('Show library panel'), findsOneWidget);
    var prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('drawer_pinned_v1'), isFalse);

    await tester.tap(find.byTooltip('Show library panel'));
    await tester.pumpAndSettle();
    expect(inPanel(find.text('Favourites')), findsOneWidget);
    prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('drawer_pinned_v1'), isTrue);
  });

  testWidgets('a remembered closed panel stays closed at launch',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'defaults_seeded_v4': true,
      'terms_accepted_version_v1': kTermsVersion,
      'drawer_pinned_v1': false,
    });
    wideWindow(tester);
    await seedLibrary();
    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();

    expect(find.byType(WiLibraryDrawer), findsNothing);
    expect(find.byTooltip('Show library panel'), findsOneWidget);
  });

  testWidgets('tapping a list in the pinned panel opens the list page '
      'and the panel survives the return', (tester) async {
    wideWindow(tester);
    await seedLibrary();
    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();

    await tester.tap(inPanel(find.text('Favourites')));
    await tester.pumpAndSettle();
    expect(find.byType(ListHomeScreen), findsOneWidget);

    // Back to home: the panel is still pinned (nothing was popped off
    // under it — the pinned drawer must not `pop` like the modal one).
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(ListHomeScreen), findsNothing);
    expect(inPanel(find.text('Favourites')), findsOneWidget);
  });

  testWidgets('narrow windows keep the modal layout: search leading, '
      'burger far right', (tester) async {
    // Default 800x600 test window — below the pin threshold.
    await seedLibrary();
    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();

    expect(find.byType(WiLibraryDrawer), findsNothing);
    expect(find.byTooltip('Hide library panel'), findsNothing);
    expect(find.byTooltip('Show library panel'), findsNothing);
    final search = find.byTooltip('Search');
    expect(tester.getTopLeft(search).dx,
        lessThan(tester.getTopLeft(find.byType(BrandMark)).dx));
    final burger = find.byTooltip('Browse lists');
    expect(tester.getTopLeft(burger).dx,
        greaterThan(tester.getTopLeft(find.byType(BrandMark)).dx));

    await tester.tap(burger);
    await tester.pumpAndSettle();
    expect(inPanel(find.text('Favourites')), findsOneWidget);
  });
}
