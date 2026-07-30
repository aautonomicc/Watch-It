import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:watchit/services/network_events.dart';

void main() {
  group('classifyTransports', () {
    test('single results map to their transports', () {
      expect(classifyTransports([ConnectivityResult.wifi]),
          NetworkTransport.wifi);
      expect(classifyTransports([ConnectivityResult.ethernet]),
          NetworkTransport.ethernet);
      expect(classifyTransports([ConnectivityResult.mobile]),
          NetworkTransport.cellular);
      expect(classifyTransports([ConnectivityResult.none]),
          NetworkTransport.none);
      expect(classifyTransports([]), NetworkTransport.none);
    });

    test('wifi with mobile on standby is wifi (not metered)', () {
      expect(
          classifyTransports(
              [ConnectivityResult.mobile, ConnectivityResult.wifi]),
          NetworkTransport.wifi);
    });

    test('vpn-only or bluetooth counts as usable-but-unknown', () {
      expect(classifyTransports([ConnectivityResult.vpn]),
          NetworkTransport.other);
      expect(classifyTransports([ConnectivityResult.bluetooth]),
          NetworkTransport.other);
    });
  });

  group('NetworkEvents', () {
    test('notifies on transport change and exposes cellular state',
        () async {
      final controller =
          StreamController<List<ConnectivityResult>>.broadcast();
      final events = NetworkEvents(
        stream: controller.stream,
        check: () async => [ConnectivityResult.wifi],
      );
      final seen = <NetworkTransport>[];
      events.addListener(() => seen.add(events.transport));
      events.start();
      await Future<void>.delayed(Duration.zero);
      expect(events.transport, NetworkTransport.wifi);

      controller.add([ConnectivityResult.mobile]);
      await Future<void>.delayed(Duration.zero);
      expect(events.onCellular, isTrue);
      expect(events.hasNetwork, isTrue);

      controller.add([ConnectivityResult.mobile]); // no change → no notify
      controller.add([ConnectivityResult.none]);
      await Future<void>.delayed(Duration.zero);
      expect(events.hasNetwork, isFalse);

      expect(seen, [
        NetworkTransport.wifi,
        NetworkTransport.cellular,
        NetworkTransport.none,
      ]);
      await controller.close();
      events.dispose();
    });
  });
}
