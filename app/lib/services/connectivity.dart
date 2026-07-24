import 'dart:async';

import 'package:flutter/foundation.dart';

import 'embedded_client.dart';

/// App-wide view of whether the embedded Autonomi client has a usable
/// network connection, polled from `/health` in the background.
///
/// "Offline" uses the same rule as the download manager's auto-pause:
/// still `connecting`, or `ready` with zero peers. Anything else —
/// including `unavailable` (no native library, e.g. widget tests) and
/// `error` — counts as online, so gating never blocks a state the rule
/// was not written for; those paths keep their existing error surfaces.
///
/// Browsing is never gated. Consumers (Play buttons, the Up-next chain)
/// listen and re-check [offline] when it flips.
class ConnectivityMonitor extends ChangeNotifier {
  ConnectivityMonitor({Future<ClientHealth> Function()? probe})
      : _probe = probe ?? EmbeddedClient.health;

  /// Replaceable for tests (fresh instance per test).
  static ConnectivityMonitor instance = ConnectivityMonitor();

  final Future<ClientHealth> Function() _probe;
  Timer? _timer;
  bool _offline = false;

  /// Last known verdict; starts optimistic so nothing is gated before
  /// the first health sample lands.
  bool get offline => _offline;

  static bool isOffline(ClientHealth health) =>
      health.state == 'connecting' ||
      (health.state == 'ready' && health.peers == 0);

  /// Begin background polling (call once from main). Re-polls quickly
  /// while offline so recovery is noticed fast, relaxed while online.
  void start() {
    if (_timer != null) return;
    unawaited(_poll());
  }

  Future<void> _poll() async {
    final health = await _probe();
    if (health.state == 'unavailable') return; // no native library; stop
    _apply(health);
    _timer = Timer(Duration(seconds: _offline ? 4 : 15), _poll);
  }

  /// One-shot live probe — refreshes [offline] and returns it. Used where
  /// a decision must not act on a stale sample (the Up-next chain).
  Future<bool> refresh() async {
    _apply(await _probe());
    return _offline;
  }

  void _apply(ClientHealth health) {
    final offline = isOffline(health);
    if (offline == _offline) return;
    _offline = offline;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}

/// Whether the player's Up-next chain may roll into the next episode:
/// a downloaded episode always plays; a streamed one needs the network,
/// checked with a live probe so a connection lost mid-episode stops the
/// chain instead of handing mpv a dead stream. Offline + not downloaded
/// = stop (no skipping ahead); online falls back to streaming.
Future<bool> canChainInto({
  required bool nextIsLocal,
  ConnectivityMonitor? monitor,
}) async {
  if (nextIsLocal) return true;
  return !await (monitor ?? ConnectivityMonitor.instance).refresh();
}
