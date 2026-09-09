import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/main.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/screens/detail_screen.dart';
import 'package:watchit/screens/profile_picker_screen.dart';
import 'package:watchit/services/connectivity.dart';
import 'package:watchit/services/download_manager.dart';
import 'package:watchit/services/embedded_client.dart';
import 'package:watchit/services/favourites.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata_service.dart';
import 'package:watchit/services/profiles.dart';
import 'package:watchit/services/terms.dart';
import 'package:watchit/services/watch_state.dart';
import 'package:watchit/theme/tokens.dart';

String _addr(int i) => i.toRadixString(16).padLeft(64, '0');

MediaEntry _e(String name, int i) => MediaEntry(name: name, address: _addr(i));

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory dlDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'defaults_seeded_v4': true,
      'terms_accepted_version_v1': kTermsVersion,
    });
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    MetadataService.instance = MetadataService(apiKeyProvider: () async => '');
    WatchStateStore.instance = WatchStateStore();
    FavouritesStore.instance = FavouritesStore();
    ProfileStore.onSwitch = null;
    ProfileStore.instance = ProfileStore();
    dlDir = Directory.systemTemp.createTempSync('wi-profiles');
    DownloadManager.instance = DownloadManager(directory: dlDir);
    ConnectivityMonitor.instance = ConnectivityMonitor(
        probe: () async => const ClientHealth(state: 'ready', peers: 5));
    await ConnectivityMonitor.instance.refresh();
  });

  tearDown(() {
    try {
      dlDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  // ALL database touches live inside the test bodies: opening drift in
  // setUp and querying it again inside the fake-async zone deadlocks on
  // the cached cross-zone open future (the home_rows_flow_test gotcha).
  Future<void> boot() async {
    await LibraryStore.save([
      MediaList(id: 'movies', title: 'Movies', entries: [_e('A.2020.mkv', 1)]),
      MediaList(
          id: 'kids', title: 'Kids Films', entries: [_e('B.2021.mkv', 2)]),
    ]);
    await ProfileStore.instance.ensureLoaded();
  }

  testWidgets('single profile: gate is invisible, home renders directly',
      (tester) async {
    await boot();
    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();
    expect(find.text('Who\'s watching?'), findsNothing);
    expect(find.text('Movies'), findsOneWidget);
    // No switch button while only the Admin exists.
    expect(find.byTooltip('Switch profile'), findsNothing);
  });

  testWidgets(
      'multi-profile launch without auto-login asks "Who\'s watching?" '
      'and tapping a profile signs in', (tester) async {
    await boot();
    await ProfileStore.instance
        .create(name: 'Ellie', kind: ProfileKind.adult);
    ProfileStore.instance.signOut();

    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();
    expect(find.text('Who\'s watching?'), findsOneWidget);
    expect(find.text('Admin'), findsOneWidget);
    expect(find.text('Ellie'), findsOneWidget);

    await tester.tap(find.text('Ellie'));
    await tester.pumpAndSettle();
    expect(find.text('Who\'s watching?'), findsNothing);
    expect(find.text('Movies'), findsOneWidget);
    expect(find.byTooltip('Switch profile'), findsOneWidget);
  });

  testWidgets('a PIN-protected profile asks for its PIN at the picker',
      (tester) async {
    await boot();
    final store = ProfileStore.instance;
    final p = await store.create(name: 'Locked', kind: ProfileKind.adult);
    await store.setPin(p.id, '1234');
    store.signOut();

    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Locked'));
    await tester.pumpAndSettle();
    expect(find.text('PIN for Locked'), findsOneWidget);

    // Wrong PIN stays on the dialog with an error.
    await tester.enterText(find.byType(TextField), '9999');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(find.text('Wrong PIN — try again'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '1234');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(find.text('Movies'), findsOneWidget);
  });

  testWidgets('kid profile sees only its allow-listed lists on the wall',
      (tester) async {
    await boot();
    final store = ProfileStore.instance;
    final kid = await store.create(
        name: 'Kiddo', kind: ProfileKind.kid, allowedLists: {'kids'});
    await store.selectProfile(kid.id);

    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();
    expect(find.text('Kids Films'), findsOneWidget);
    expect(find.text('Movies'), findsNothing);
  });

  testWidgets(
      'kid settings are restricted: switch + appearance + buffer + about, '
      'no content management and no Clear all data', (tester) async {
    await boot();
    final store = ProfileStore.instance;
    final kid = await store.create(
        name: 'Kiddo', kind: ProfileKind.kid, allowedLists: {'kids'});
    await store.selectProfile(kid.id);

    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Browse lists'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('Switch profile'), findsOneWidget);
    expect(find.text('Colour scheme'), findsOneWidget);
    expect(find.text('Buffer size'), findsOneWidget);
    // The admin sections are gone entirely.
    expect(find.text('CONTENT'), findsNothing);
    expect(find.text('My Media'), findsNothing);
    expect(find.text('Channels'), findsNothing);
    expect(find.text('TMDB API key'), findsNothing);
    expect(find.text('Offline mode'), findsNothing);
    expect(find.text('Profiles'), findsNothing);
    // About stays, minus the factory reset.
    await tester.scrollUntilVisible(
        find.text('Size on disk'), 300,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Size on disk'), findsOneWidget);
    expect(find.text('Clear all data'), findsNothing);
  });

  testWidgets('adult (non-admin) settings are restricted too',
      (tester) async {
    await boot();
    final store = ProfileStore.instance;
    final adult =
        await store.create(name: 'Grown-up', kind: ProfileKind.adult);
    await store.selectProfile(adult.id);

    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Browse lists'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('Switch profile'), findsOneWidget);
    expect(find.text('CONTENT'), findsNothing);
    expect(find.text('Wallet'), findsNothing);
    expect(find.text('Clear all data'), findsNothing);
  });

  testWidgets(
      'kid detail page hides Download and Edit details; adult keeps '
      'Download', (tester) async {
    await boot();
    final store = ProfileStore.instance;
    final kid = await store.create(
        name: 'Kiddo', kind: ProfileKind.kid, allowedLists: {'kids'});
    final adult =
        await store.create(name: 'Grown-up', kind: ProfileKind.adult);

    Widget page(Widget child) => MaterialApp(
          theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
          home: child,
        );

    await store.selectProfile(kid.id);
    await tester.pumpWidget(page(DetailScreen(entry: _e('B.2021.mkv', 2))));
    await tester.pumpAndSettle();
    expect(find.text('Download'), findsNothing);
    expect(find.byTooltip('Edit details'), findsNothing);
    expect(find.text('Play'), findsOneWidget);

    await store.selectProfile(adult.id);
    await tester.pumpWidget(page(DetailScreen(entry: _e('A.2020.mkv', 1))));
    await tester.pumpAndSettle();
    expect(find.text('Download'), findsOneWidget);
  });

  testWidgets(
      'admin Settings has the Profiles door; creating the first profile '
      'offers the admin PIN', (tester) async {
    await boot();
    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Browse lists'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('PROFILES'), findsOneWidget);
    await tester.tap(find.text('Profiles'));
    await tester.pumpAndSettle();
    expect(find.text('Add profile'), findsOneWidget);
    expect(find.text('Admin PIN'), findsOneWidget);

    await tester.tap(find.text('Add profile'));
    await tester.pumpAndSettle();
    expect(find.text('New profile'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Junior');
    // Kid is the default type; pick a preset avatar and create.
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    // The agreed nudge: first extra profile → offer to set an admin PIN,
    // skippable with the explicit warning.
    expect(find.text('Set an admin PIN?'), findsOneWidget);
    expect(find.textContaining('Without a PIN anyone can switch'),
        findsOneWidget);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();

    // Back on the Profiles page with the new kid listed.
    expect(find.text('Junior'), findsOneWidget);
    expect(ProfileStore.instance.profiles, hasLength(2));
    expect(ProfileStore.instance.profiles.last.kind, ProfileKind.kid);
  });

  testWidgets(
      'switching away from a kid profile requires the admin PIN when set',
      (tester) async {
    await boot();
    final store = ProfileStore.instance;
    await store.setAdminPin('4321');
    final kid = await store.create(
        name: 'Kiddo', kind: ProfileKind.kid, allowedLists: {'kids'});
    await store.selectProfile(kid.id);

    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Switch profile'));
    await tester.pumpAndSettle();
    expect(find.text('Admin PIN to switch profile'), findsOneWidget);

    // Cancel keeps the kid signed in.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Who\'s watching?'), findsNothing);

    // The right PIN reaches the picker.
    await tester.tap(find.byTooltip('Switch profile'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '4321');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(find.text('Who\'s watching?'), findsOneWidget);
  });

  testWidgets('kid home hides the Downloads row and its indicator',
      (tester) async {
    await boot();
    // A finished download would badge the wall + downloads row for the
    // admin; the kid must never see the row.
    final store = ProfileStore.instance;
    final kid = await store.create(
        name: 'Kiddo', kind: ProfileKind.kid, allowedLists: {'kids'});
    await store.selectProfile(kid.id);

    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();
    expect(find.text('Downloads'), findsNothing);
  });

  testWidgets('switchProfileFlow pops pushed routes before the picker',
      (tester) async {
    await boot();
    final store = ProfileStore.instance;
    await store.create(name: 'Ellie', kind: ProfileKind.adult);

    await tester.pumpWidget(const WatchItApp());
    await tester.pumpAndSettle();
    // From Settings (a pushed route), Switch profile must land on the
    // picker, not leave Settings covering it.
    await tester.tap(find.byTooltip('Browse lists'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await switchProfileFlow(
        tester.element(find.text('Settings').first));
    await tester.pumpAndSettle();
    expect(find.text('Who\'s watching?'), findsOneWidget);
  });
}
