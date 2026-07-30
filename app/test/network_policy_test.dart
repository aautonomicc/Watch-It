import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/services/app_settings.dart';
import 'package:watchit/services/network_events.dart';
import 'package:watchit/services/network_policy.dart';

/// NetworkEvents driven by hand through an injected stream.
(NetworkEvents, StreamController<List<ConnectivityResult>>) makeEvents(
    List<ConnectivityResult> initial) {
  final controller = StreamController<List<ConnectivityResult>>.broadcast();
  final events =
      NetworkEvents(stream: controller.stream, check: () async => initial);
  events.start();
  return (events, controller);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    CellularStreamingConsent.granted = false;
  });

  group('streamingGateNow', () {
    test('never gates off cellular, whatever the policy', () async {
      final (events, controller) = makeEvents([ConnectivityResult.wifi]);
      await Future<void>.delayed(Duration.zero);
      await AppSettings.setStreamingNetworkPolicy(
          StreamingNetworkPolicy.wifiOnly);
      expect(await streamingGateNow(network: events), StreamingGate.allow);
      await controller.close();
    });

    test('cellular default policy asks, consent flips it to allow',
        () async {
      final (events, controller) = makeEvents([ConnectivityResult.mobile]);
      await Future<void>.delayed(Duration.zero);
      expect(await streamingGateNow(network: events), StreamingGate.ask);
      CellularStreamingConsent.granted = true;
      expect(await streamingGateNow(network: events), StreamingGate.allow);
      await controller.close();
    });

    test('cellular with wifiOnly blocks; with allow permits', () async {
      final (events, controller) = makeEvents([ConnectivityResult.mobile]);
      await Future<void>.delayed(Duration.zero);
      await AppSettings.setStreamingNetworkPolicy(
          StreamingNetworkPolicy.wifiOnly);
      expect(await streamingGateNow(network: events), StreamingGate.block);
      await AppSettings.setStreamingNetworkPolicy(
          StreamingNetworkPolicy.allow);
      expect(await streamingGateNow(network: events), StreamingGate.allow);
      await controller.close();
    });
  });
}
