import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_settings.dart';
import 'channels_api.dart';
import 'my_watch_api.dart';
import 'network_events.dart';

/// The two features riding x0x gossip agents.
enum X0xAgent { myWatch, channels }

/// Enforces the Settings → Network → Mobile data switches for the two
/// x0x agents: while the device is on cellular and a feature is set to
/// Wi-Fi only, its agent is paused (all gossip/relay traffic stops) and
/// switched back on the moment Wi-Fi returns.
///
/// The pause goes through the same POST /…/enabled switch the user's
/// own Built-in x0x client toggles use, so which agents THIS gate
/// switched off is remembered separately (prefs): a user's manual
/// "off" is never overridden by Wi-Fi returning, and an agent the gate
/// paused comes back even across an app restart. The gate only acts on
/// transport or policy changes, never continuously — a manual switch
/// flip (or the core's auto-re-enable on subscribe/link) always wins
/// until the next change.
class X0xCellularGate extends ChangeNotifier {
  X0xCellularGate({this._myWatchApi, this._channelsApi, this._network});

  /// Replaceable for tests (fresh instance per test).
  static X0xCellularGate instance = X0xCellularGate();

  static const _pausedKey = 'x0x_cellular_paused_v1';

  final MyWatchApi? _myWatchApi;
  final ChannelsApi? _channelsApi;
  final NetworkEvents? _network;

  NetworkEvents get _net => _network ?? NetworkEvents.instance;

  final Set<X0xAgent> _paused = {};
  bool _loaded = false;
  // Serializes applies so a policy change racing a transport flip can't
  // interleave status reads and enabled writes.
  Future<void> _ops = Future<void>.value();

  /// Whether [agent] is currently switched off by this gate (as opposed
  /// to by the user's own toggle).
  bool isPaused(X0xAgent agent) => _paused.contains(agent);

  /// Call once from main() after NetworkEvents.instance.start(). The
  /// initial apply is delayed: at launch the transport is still the
  /// permissive unknown until connectivity_plus answers, and applying
  /// then would flap a paused agent on and straight back off when the
  /// real (cellular) transport lands a moment later.
  void start({Duration initialDelay = const Duration(seconds: 2)}) {
    _net.addListener(_onTransportChange);
    Timer(initialDelay, _schedule);
  }

  void _onTransportChange() => _schedule();

  /// A Mobile data switch changed. Returns when the resulting apply has
  /// finished (tests await it; production fire-and-forgets).
  Future<void> onPolicyChanged() {
    _schedule();
    return _ops;
  }

  /// The user flipped [agent]'s own x0x switch: their intent wins —
  /// forget any pause this gate holds so Wi-Fi's return won't override
  /// their choice.
  Future<void> noteManualChange(X0xAgent agent) async {
    await ensureLoaded();
    if (_paused.remove(agent)) {
      await _persist();
      notifyListeners();
    }
  }

  /// Loads the persisted paused set (idempotent). start() and every
  /// apply do this themselves; UI that reads [isPaused] early may call
  /// it to avoid a stale first frame.
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    for (final name in prefs.getStringList(_pausedKey) ?? const []) {
      final agent = X0xAgent.values.asNameMap()[name];
      if (agent != null) _paused.add(agent);
    }
  }

  void _schedule() {
    // Swallow errors so one failed apply can't poison the chain.
    _ops = _ops.then((_) => _applyAll()).catchError((_) {});
  }

  Future<void> _applyAll() async {
    await ensureLoaded();
    await _apply(X0xAgent.myWatch);
    await _apply(X0xAgent.channels);
  }

  Future<void> _apply(X0xAgent agent) async {
    final allowed = switch (agent) {
      X0xAgent.myWatch => await AppSettings.myWatchOnCellular(),
      X0xAgent.channels => await AppSettings.channelsOnCellular(),
    };
    final wantPaused = _net.onCellular && !allowed;
    if (wantPaused == _paused.contains(agent)) return;
    try {
      if (wantPaused) {
        // Only pause an agent that is actually on: a user's own "off"
        // stays theirs (and stays off when Wi-Fi returns), and an
        // unsupported platform is never touched.
        final (supported, enabled) = await _agentState(agent);
        if (!supported || !enabled) return;
        await _setEnabled(agent, false);
        _paused.add(agent);
      } else {
        // Clear the flag only after the enable succeeded, so a client
        // hiccup here leaves the pause for the next change to retry.
        await _setEnabled(agent, true);
        _paused.remove(agent);
      }
      await _persist();
      notifyListeners();
    } catch (_) {
      // Embedded client unreachable — the next transport or policy
      // change retries.
    }
  }

  Future<(bool, bool)> _agentState(X0xAgent agent) async {
    switch (agent) {
      case X0xAgent.myWatch:
        final s = await (_myWatchApi ?? MyWatchApi()).status();
        return (s.supported, s.enabled);
      case X0xAgent.channels:
        final s = await (_channelsApi ?? ChannelsApi()).status();
        return (s.supported, s.enabled);
    }
  }

  Future<void> _setEnabled(X0xAgent agent, bool on) => switch (agent) {
        X0xAgent.myWatch => (_myWatchApi ?? MyWatchApi()).setEnabled(on),
        X0xAgent.channels => (_channelsApi ?? ChannelsApi()).setEnabled(on),
      };

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        _pausedKey, [for (final a in _paused) a.name]);
  }
}
