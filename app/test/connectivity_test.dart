import 'package:flutter_test/flutter_test.dart';

import 'package:watchit/services/connectivity.dart';
import 'package:watchit/services/embedded_client.dart';

ClientHealth _health(String state, {int peers = 0}) =>
    ClientHealth(state: state, peers: peers);

void main() {
  group('ConnectivityMonitor.isOffline', () {
    test('connecting is offline', () {
      expect(ConnectivityMonitor.isOffline(_health('connecting')), isTrue);
    });

    test('ready with zero peers is offline', () {
      expect(
          ConnectivityMonitor.isOffline(_health('ready', peers: 0)), isTrue);
    });

    test('ready with peers is online', () {
      expect(
          ConnectivityMonitor.isOffline(_health('ready', peers: 5)), isFalse);
    });

    test('unavailable and error are not gated', () {
      // The rule was written for lost connections; other states keep
      // their own error surfaces and must never disable Play.
      expect(ConnectivityMonitor.isOffline(_health('unavailable')), isFalse);
      expect(ConnectivityMonitor.isOffline(_health('error')), isFalse);
    });
  });

  group('ConnectivityMonitor.refresh', () {
    test('flips offline and notifies on change only', () async {
      var health = _health('ready', peers: 3);
      final monitor = ConnectivityMonitor(probe: () async => health);
      var notified = 0;
      monitor.addListener(() => notified++);

      expect(monitor.offline, isFalse); // optimistic start
      expect(await monitor.refresh(), isFalse);
      expect(notified, 0); // online → online: no notify

      health = _health('ready', peers: 0);
      expect(await monitor.refresh(), isTrue);
      expect(monitor.offline, isTrue);
      expect(notified, 1);

      health = _health('ready', peers: 7);
      expect(await monitor.refresh(), isFalse);
      expect(notified, 2);
    });
  });

  group('onExternalNetworkEvent', () {
    test('offline after re-probe kicks the reconnect supervisor', () async {
      var kicks = 0;
      final monitor = ConnectivityMonitor(
        probe: () async => _health('ready', peers: 0),
        kick: () async => kicks++,
      );
      await monitor.onExternalNetworkEvent();
      expect(monitor.offline, isTrue);
      expect(kicks, 1);
    });

    test('online after re-probe does not kick', () async {
      var kicks = 0;
      final monitor = ConnectivityMonitor(
        probe: () async => _health('ready', peers: 5),
        kick: () async => kicks++,
      );
      await monitor.onExternalNetworkEvent();
      expect(kicks, 0);
    });
  });

  group('canChainInto', () {
    test('downloaded next episode always chains, without probing', () async {
      var probed = false;
      final monitor = ConnectivityMonitor(probe: () async {
        probed = true;
        return _health('connecting');
      });
      expect(
          await canChainInto(nextIsLocal: true, monitor: monitor), isTrue);
      expect(probed, isFalse);
    });

    test('streamed next episode chains online', () async {
      final monitor =
          ConnectivityMonitor(probe: () async => _health('ready', peers: 4));
      expect(
          await canChainInto(nextIsLocal: false, monitor: monitor), isTrue);
    });

    test('streamed next episode stops the chain offline', () async {
      final monitor =
          ConnectivityMonitor(probe: () async => _health('ready', peers: 0));
      expect(
          await canChainInto(nextIsLocal: false, monitor: monitor), isFalse);
    });

    test('probe is live, not the cached sample', () async {
      // Connection lost mid-episode: the background poll still says
      // online, but the chain decision must see the drop.
      var health = _health('ready', peers: 4);
      final monitor = ConnectivityMonitor(probe: () async => health);
      await monitor.refresh();
      health = _health('connecting');
      expect(
          await canChainInto(nextIsLocal: false, monitor: monitor), isFalse);
    });
  });
}
