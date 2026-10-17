import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/screens/settings_screen.dart';
import 'package:watchit/services/embedded_client.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/my_watch_sync.dart';
import 'package:watchit/theme/tokens.dart';
import 'package:watchit/widgets/autonomi_credit.dart';
import 'package:watchit/widgets/library_drawer.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late List<Uri> launched;
  late bool launchResult;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LibraryStore.useForTesting(
      AppDatabase.forTesting(NativeDatabase.memory()),
    );
    launched = [];
    launchResult = true;
    autonomiLinkLauncher = (uri) async {
      launched.add(uri);
      return launchResult;
    };
  });

  Widget app(Widget home) => MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: home,
      );

  testWidgets('About shows the Autonomi credit and a tap opens autonomi.com',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(const SettingsScreen()));
    await tester.pumpAndSettle();

    final tile = find.widgetWithText(ListTile, 'Powered by the Autonomi network');
    expect(tile, findsOneWidget);
    expect(find.textContaining('autonomi.com'), findsOneWidget);
    final logo = find.descendant(of: tile, matching: find.byType(AutonomiLogo));
    expect(logo, findsOneWidget);
    expect(
      tester.widget<Image>(
        find.descendant(of: logo, matching: find.byType(Image)),
      ).image,
      isA<AssetImage>().having((a) => a.assetName, 'asset', kAutonomiLogoAsset),
    );
    // The credit sits directly under the app's own identity row, above
    // the TMDB attribution.
    final brandY = tester.getTopLeft(find.text('W@tch', findRichText: true)).dy;
    final creditY = tester.getTopLeft(tile).dy;
    final tmdbY = tester
        .getTopLeft(find.image(const AssetImage('assets/tmdb_logo.png')))
        .dy;
    expect(creditY, greaterThan(brandY));
    expect(tmdbY, greaterThan(creditY));

    await tester.tap(tile);
    await tester.pump();
    expect(launched, [Uri.parse('https://autonomi.com/')]);
    expect(find.textContaining('Visit https://autonomi.com/'), findsNothing);
  });

  testWidgets('a failed launch names the address instead of dying quietly',
      (tester) async {
    launchResult = false;
    await tester.pumpWidget(app(const Scaffold(body: AutonomiCredit.tile())));
    await tester.tap(find.byType(ListTile));
    await tester.pump();
    expect(find.text('Visit https://autonomi.com/ in a browser'), findsOneWidget);
  });

  testWidgets('the library drawer carries the compact credit as its footer',
      (tester) async {
    MyWatchSync.status.value = const MyWatchSyncStatus(supported: false);
    await tester.pumpWidget(app(Scaffold(
      drawer: WiLibraryDrawer(
        healthProvider: () async => const ClientHealth(state: 'ready', peers: 3),
      ),
      body: const SizedBox(),
    )));
    tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
    await tester.pumpAndSettle();

    expect(find.text('Powered by'), findsOneWidget);
    expect(find.byType(AutonomiLogo), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Powered by')).dy,
      greaterThan(tester.getTopLeft(find.text('Settings')).dy),
    );
    // Anchored to the drawer's bottom edge, not the last scrolling row:
    // with only a few lists the credit must not hang mid-panel.
    final drawerBottom = tester.getBottomLeft(find.byType(Drawer)).dy;
    final creditBottom =
        tester.getBottomLeft(find.byType(AutonomiCredit)).dy;
    expect(creditBottom, closeTo(drawerBottom, 0.5));
    expect(
      tester.getBottomLeft(find.text('Settings')).dy,
      lessThan(drawerBottom - 60),
    );
    await tester.tap(find.text('Powered by'));
    await tester.pump();
    expect(launched, [Uri.parse('https://autonomi.com/')]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the pinned desktop drawer keeps the credit at its bottom edge',
      (tester) async {
    MyWatchSync.status.value = const MyWatchSyncStatus(supported: false);
    await tester.pumpWidget(app(Scaffold(
      body: Row(children: [
        WiLibraryDrawer(
          pinned: true,
          healthProvider: () async =>
              const ClientHealth(state: 'ready', peers: 3),
        ),
        const Expanded(child: SizedBox()),
      ]),
    )));
    await tester.pumpAndSettle();

    final panelBottom = tester.getBottomLeft(find.byType(WiLibraryDrawer)).dy;
    expect(
      tester.getBottomLeft(find.byType(AutonomiCredit)).dy,
      closeTo(panelBottom, 0.5),
    );
    expect(
      tester.getBottomLeft(find.text('Settings')).dy,
      lessThan(panelBottom - 60),
    );
    await tester.pumpWidget(const SizedBox());
  });
}
