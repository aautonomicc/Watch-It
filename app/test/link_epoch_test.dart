import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/models/media_list.dart';
import 'package:watchit/screens/detail_screen.dart';
import 'package:watchit/services/embedded_client.dart';
import 'package:watchit/services/link_epoch.dart';
import 'package:watchit/services/low_data_mode.dart';
import 'package:watchit/services/my_watch_api.dart';
import 'package:watchit/services/network_pause.dart';
import 'package:watchit/services/play_queue.dart';
import 'package:watchit/theme/tokens.dart';

import 'fake_embedded_http.dart';

/// The link epoch (a release with an x0x that cannot sync with the old
/// one removes the My W@tch link and says so) and the offline-mode
/// question asked before a streamed title plays.
void main() {
  late FakeEmbeddedHttp fake;
  late MyWatchApi api;

  setUp(() {
    fake = FakeEmbeddedHttp();
    HttpOverrides.global = fake;
    api = MyWatchApi(base: FakeEmbeddedHttp.base);
    final pause = NetworkPause.instance;
    final lowData = LowDataMode.instance;
    NetworkPause.instance = NetworkPause(
      base: FakeEmbeddedHttp.base,
      token: 'test',
      myWatchApi: api,
    );
    LowDataMode.instance = LowDataMode(api: api);
    addTearDown(() {
      NetworkPause.instance = pause;
      LowDataMode.instance = lowData;
      HttpOverrides.global = null;
    });
  });

  void link() => fake.myWatchStatus = {
    'supported': true,
    'enabled': true,
    'linked': true,
    'state': 'ready',
    'devices': const [],
  };

  test('the reviewed x0x line matches Cargo.toml', () {
    // Fails after an x0x minor bump until someone has read its release
    // notes and decided whether kLinkEpoch must go up (see
    // lib/services/link_epoch.dart).
    final toml = File('../native/watchit_core/Cargo.toml').readAsStringSync();
    final version = RegExp(
      r'^x0x\s*=\s*(?:"|\{[^}]*(?:version|tag)\s*=\s*")[=v]?(\d+\.\d+)',
      multiLine: true,
    ).firstMatch(toml)?.group(1);
    expect(version, isNotNull, reason: 'x0x dependency not found');
    expect(
      version,
      kLinkEpochReviewedX0x,
      reason:
          'x0x moved to $version. Check whether it still syncs with the '
          'previous release: if not, bump kLinkEpoch; then set '
          'kLinkEpochReviewedX0x to "$version".',
    );
  });

  test('same epoch keeps the link', () async {
    SharedPreferences.setMockInitialValues({});
    link();
    expect(await LinkEpoch.enforce(api: api, epoch: 1), isFalse);
    expect(fake.myWatchStatus['linked'], isTrue);
    expect(await LinkEpoch.noticePending(), isFalse);
  });

  test('a newer epoch removes the link once and flags the notice', () async {
    SharedPreferences.setMockInitialValues({'low_data_mode_v1': true});
    link();
    expect(await LinkEpoch.enforce(api: api, epoch: 2), isTrue);
    expect(fake.myWatchStatus['linked'], isFalse);
    expect(await LinkEpoch.noticePending(), isTrue);
    // Paired again on the new release: the next launch leaves it alone.
    link();
    expect(await LinkEpoch.enforce(api: api, epoch: 2), isFalse);
    expect(fake.myWatchStatus['linked'], isTrue);
  });

  test('an unlinked device is stamped without a notice', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await LinkEpoch.enforce(api: api, epoch: 2), isFalse);
    expect(await LinkEpoch.noticePending(), isFalse);
    link();
    expect(await LinkEpoch.enforce(api: api, epoch: 2), isFalse);
    expect(fake.myWatchStatus['linked'], isTrue);
  });

  test('an unreachable client is retried on the next launch', () async {
    SharedPreferences.setMockInitialValues({});
    final dead = MyWatchApi(base: 'http://127.0.0.1:1');
    HttpOverrides.global = null;
    expect(await LinkEpoch.enforce(api: dead, epoch: 2), isFalse);
    HttpOverrides.global = fake;
    link();
    expect(await LinkEpoch.enforce(api: api, epoch: 2), isTrue);
  });

  Widget host(Widget child) => MaterialApp(
    theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
    home: Scaffold(body: child),
  );

  testWidgets('the notice shows until answered', (tester) async {
    SharedPreferences.setMockInitialValues({'mywatch_relink_notice_v1': true});
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => offerRelinkNotice(context),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('Pair your devices again'), findsOneWidget);
    // Not dismissible by tapping outside.
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('Pair your devices again'), findsOneWidget);
    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
    expect(await LinkEpoch.noticePending(), isFalse);
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('Pair your devices again'), findsNothing);
  });

  group('offline mode before streaming', () {
    Future<bool?> ask(WidgetTester tester, {String? answer}) async {
      bool? result;
      await tester.pumpWidget(
        host(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await confirmLeaveOfflineMode(
                  context,
                  probe: () async => const ClientHealth(state: 'ready'),
                );
              },
              child: const Text('play'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('play'));
      await tester.pumpAndSettle();
      if (answer != null) {
        expect(find.text('Offline mode is on'), findsOneWidget);
        await tester.tap(find.text(answer));
        await tester.pumpAndSettle();
      }
      return result;
    }

    testWidgets('online: no question', (tester) async {
      SharedPreferences.setMockInitialValues({});
      expect(await ask(tester), isTrue);
      expect(find.text('Offline mode is on'), findsNothing);
    });

    testWidgets('Go online lifts the pause and plays', (tester) async {
      SharedPreferences.setMockInitialValues({'network_paused_v1': true});
      expect(await ask(tester, answer: 'Go online'), isTrue);
      expect(NetworkPause.instance.paused, isFalse);
      expect(fake.networkPausePosts.last, contains('false'));
    });

    testWidgets('Cancel stays offline and does not play', (tester) async {
      SharedPreferences.setMockInitialValues({'network_paused_v1': true});
      expect(await ask(tester, answer: 'Cancel'), isFalse);
      expect(NetworkPause.instance.paused, isTrue);
      expect(fake.networkPausePosts, isEmpty);
    });

    testWidgets('an automatic pause lifts without asking', (tester) async {
      SharedPreferences.setMockInitialValues({
        'network_paused_v1': true,
        'network_autopaused_v1': true,
      });
      expect(await ask(tester), isTrue);
      expect(find.text('Offline mode is on'), findsNothing);
      expect(NetworkPause.instance.paused, isFalse);
    });
  });

  test('the inline queue does not play when the question is declined',
      () async {
    SharedPreferences.setMockInitialValues({});
    var asked = 0;
    final queue = PlayQueueController(
      tracks: () => const [],
      trackInfo: (_) => throw StateError('must not play'),
      sourceOverride: (_) => (url: 'http://x/y', local: false),
      playerFactory: () => throw StateError('must not play'),
      confirmOffline: () async {
        asked++;
        return false;
      },
    );
    await queue.playTrack(
      const MediaEntry(name: 'Song.mp3', address: 'ab'),
    );
    expect(asked, 1);
    expect(queue.current, isNull);
  });
}
