import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/main.dart';
import 'package:watchit/screens/channels_screen.dart';
import 'package:watchit/screens/my_watch_screen.dart';
import 'package:watchit/services/channels_api.dart';
import 'package:watchit/services/embedded_client.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/my_watch_sync.dart';
import 'package:watchit/services/terms.dart';
import 'package:watchit/services/x0x_cellular.dart';
import 'package:watchit/theme/tokens.dart';
import 'package:watchit/widgets/drawer_status.dart';
import 'package:watchit/widgets/library_drawer.dart';

Widget _status({
  String state = 'ready',
  int peers = 5,
  String channelsState = 'off',
  bool channelsSupported = true,
  bool channelsEnabled = true,
}) =>
    MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: Scaffold(
        body: WiDrawerStatus(
          healthProvider: () async => ClientHealth(state: state, peers: peers),
          channelsStatusProvider: () async => ChannelsStatus(
              supported: channelsSupported,
              enabled: channelsEnabled,
              state: channelsState),
        ),
      ),
    );

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() async {
    SharedPreferences.setMockInitialValues(
        {'terms_accepted_version_v1': kTermsVersion});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    MyWatchSync.status.value = const MyWatchSyncStatus();
  });

  group('WiDrawerStatus peers row', () {
    testWidgets('shows the peer count when ready', (tester) async {
      await tester.pumpWidget(_status());
      await tester.pump();
      expect(find.text('Connected · 5 peers'), findsOneWidget);
      await tester.pumpWidget(const SizedBox()); // cancel the poll timers
    });

    testWidgets('connecting and error states stay short', (tester) async {
      await tester.pumpWidget(_status(state: 'connecting'));
      await tester.pump();
      expect(find.text('Connecting…'), findsOneWidget);
      // Fresh state so the new provider is polled from initState.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_status(state: 'error'));
      await tester.pump();
      expect(find.text('Connection error'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('WiDrawerStatus My W@tch row', () {
    testWidgets('follows the sync status, shows not-linked', (tester) async {
      await tester.pumpWidget(_status());
      await tester.pump();
      // Not supported yet → hidden entirely.
      expect(find.textContaining('My W@tch'), findsNothing);

      MyWatchSync.status.value =
          const MyWatchSyncStatus(supported: true, linked: false);
      await tester.pump();
      expect(find.text('My W@tch: not linked'), findsOneWidget);

      MyWatchSync.status.value = MyWatchSyncStatus(
        supported: true,
        linked: true,
        agentState: 'ready',
        lastSyncMs: DateTime.now().millisecondsSinceEpoch - 30000,
      );
      await tester.pump();
      expect(find.text('My W@tch: synced just now'), findsOneWidget);

      MyWatchSync.status.value = const MyWatchSyncStatus(
          supported: true, linked: true, agentState: 'starting');
      await tester.pump();
      expect(find.text('My W@tch: connecting…'), findsOneWidget);

      MyWatchSync.status.value = const MyWatchSyncStatus(
          supported: true, linked: true, agentState: 'ready', syncing: true);
      await tester.pump();
      expect(find.text('My W@tch: syncing…'), findsOneWidget);

      MyWatchSync.status.value = const MyWatchSyncStatus(
        supported: true,
        linked: true,
        agentState: 'ready',
        problems: ['Artwork for "X" could not be fetched: refused'],
      );
      await tester.pump();
      expect(find.text('My W@tch: sync issue'), findsOneWidget);

      // The Settings switch beats the agent state: a linked device that
      // was switched off says so instead of "connecting…" forever.
      MyWatchSync.status.value = const MyWatchSyncStatus(
          supported: true, linked: true, enabled: false, agentState: 'off');
      await tester.pump();
      expect(find.text('My W@tch: switched off'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('tapping opens the My W@tch page', (tester) async {
      MyWatchSync.status.value = const MyWatchSyncStatus(
          supported: true, linked: true, agentState: 'ready');
      await tester.pumpWidget(_status());
      await tester.pump();
      await tester.tap(find.text('My W@tch: linked'));
      await tester.pumpAndSettle();
      expect(find.byType(MyWatchScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('WiDrawerStatus Channels row', () {
    testWidgets('off, starting, and ready states', (tester) async {
      await tester.pumpWidget(_status(channelsState: 'off'));
      await tester.pump();
      expect(find.text('Channels: not connected'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());

      await tester.pumpWidget(_status(channelsState: 'starting'));
      await tester.pump();
      expect(find.text('Channels: connecting…'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());

      await tester.pumpWidget(_status(channelsState: 'ready'));
      await tester.pump();
      expect(find.text('Channels: connected'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());

      // The Settings switch wins over every state.
      await tester.pumpWidget(
          _status(channelsState: 'off', channelsEnabled: false));
      await tester.pump();
      expect(find.text('Channels: switched off'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a mobile-data pause reads paused, not switched off',
        (tester) async {
      // Both agents disabled by the cellular gate, not the user.
      SharedPreferences.setMockInitialValues({
        'terms_accepted_version_v1': kTermsVersion,
        'x0x_cellular_paused_v1': ['myWatch', 'channels'],
      });
      X0xCellularGate.instance = X0xCellularGate();
      await X0xCellularGate.instance.ensureLoaded();
      addTearDown(() => X0xCellularGate.instance = X0xCellularGate());

      MyWatchSync.status.value = const MyWatchSyncStatus(
          supported: true, linked: true, enabled: false, agentState: 'off');
      await tester.pumpWidget(
          _status(channelsState: 'off', channelsEnabled: false));
      await tester.pump();
      expect(
          find.text('My W@tch: paused on mobile data'), findsOneWidget);
      expect(find.text('Channels: paused on mobile data'), findsOneWidget);
      expect(find.textContaining('switched off'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('hidden when the build has no channels support',
        (tester) async {
      await tester.pumpWidget(_status(channelsSupported: false));
      await tester.pump();
      expect(find.textContaining('Channels'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('tapping opens the Channels page', (tester) async {
      await tester.pumpWidget(_status(channelsState: 'ready'));
      await tester.pump();
      await tester.tap(find.text('Channels: connected'));
      await tester.pumpAndSettle();
      expect(find.byType(ChannelsScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('drawer placement', () {
    testWidgets('status rows sit at the top of the drawer, above the '
        'Library section', (tester) async {
      MyWatchSync.status.value = const MyWatchSyncStatus(
          supported: true, linked: true, agentState: 'ready');
      await tester.pumpWidget(MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: Scaffold(
          drawer: WiLibraryDrawer(
            healthProvider: () async =>
                const ClientHealth(state: 'ready', peers: 3),
            channelsStatusProvider: () async =>
                const ChannelsStatus(supported: true, state: 'ready'),
          ),
          body: const SizedBox(),
        ),
      ));
      final scaffold =
          tester.state<ScaffoldState>(find.byType(Scaffold).first);
      scaffold.openDrawer();
      await tester.pumpAndSettle();

      expect(find.text('Connected · 3 peers'), findsOneWidget);
      expect(find.text('My W@tch: linked'), findsOneWidget);
      expect(find.text('Channels: connected'), findsOneWidget);

      final libraryY = tester.getTopLeft(find.text('Library')).dy;
      final settingsY = tester.getTopLeft(find.text('Settings')).dy;
      final peersY = tester.getTopLeft(find.text('Connected · 3 peers')).dy;
      final watchY = tester.getTopLeft(find.text('My W@tch: linked')).dy;
      final channelsY =
          tester.getTopLeft(find.text('Channels: connected')).dy;
      expect(watchY, greaterThan(peersY));
      expect(channelsY, greaterThan(watchY));
      expect(libraryY, greaterThan(channelsY));
      expect(settingsY, greaterThan(libraryY));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('home screen no longer carries the status bar',
        (tester) async {
      await tester.pumpWidget(const WatchItApp());
      await tester.pumpAndSettle();
      // The old NetworkStatusBar wording is gone from the home body; the
      // drawer owns connection status now.
      expect(find.textContaining('Connected ·'), findsNothing);
      expect(find.textContaining('Connecting'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('Settings → Library', () {
    testWidgets(
        'My W@tch tile sits below Channels in the Library section and '
        'navigates', (tester) async {
      await tester.pumpWidget(const WatchItApp());
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Browse lists'));
      await tester.pumpAndSettle();
      // The drawer has no My W@tch *tile* — the page lives in Settings
      // (the status row only appears once sync reports supported).
      expect(find.text('My W@tch'), findsNothing);
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text('My W@tch'), 100);
      await tester.ensureVisible(find.text('My W@tch'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('My W@tch'));
      await tester.pumpAndSettle();
      expect(find.byType(MyWatchScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
