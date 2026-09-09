import 'package:flutter_test/flutter_test.dart';

import 'package:watchit/screens/player_screen.dart';
import 'package:watchit/services/embedded_client.dart';

void main() {
  group('connectivityErrorFor', () {
    test('healthy client keeps the raw player error', () {
      expect(
        connectivityErrorFor(const ClientHealth(state: 'ready', peers: 5)),
        isNull,
      );
    });

    test('ready with zero peers rewords (the VPN-blocking case)', () {
      final e =
          connectivityErrorFor(const ClientHealth(state: 'ready', peers: 0));
      expect(e, isNotNull);
      expect(e!.title, "Can't reach the Autonomi network");
      expect(e.message, contains('VPN'));
      expect(e.message, contains('Connected'));
    });

    test('connecting rewords with the wait-for-connection advice', () {
      final e = connectivityErrorFor(
        const ClientHealth(state: 'connecting', attempts: 2),
      );
      expect(e, isNotNull);
      expect(e!.title, "Can't reach the Autonomi network");
      expect(e.message, contains('VPN'));
    });

    test('paused gets its own settings-pointing message', () {
      final e = connectivityErrorFor(const ClientHealth(state: 'paused'));
      expect(e, isNotNull);
      expect(e!.message, contains('paused'));
      expect(e.message, contains('Settings'));
      expect(e.message, isNot(contains('VPN')));
    });

    test('error and unavailable states reword too', () {
      for (final state in ['error', 'unavailable']) {
        expect(
          connectivityErrorFor(ClientHealth(state: state)),
          isNotNull,
          reason: state,
        );
      }
    });
  });
}
