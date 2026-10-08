import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'my_watch_api.dart';
import 'my_watch_sync.dart';
import 'x0x_cellular.dart';

/// Low-data mode (per device): the My W@tch x0x agent stays OFF on this
/// device and the shared-backup follower (backup_follow.dart) carries
/// the sync instead — it polls the master's backup pointer directly
/// from the network (free reads, roughly one pointer peek per poll),
/// while the live gossip mesh costs tens of MB per minute just by
/// being connected (the 2026-10-08 upstream status check: that floor
/// is Critical-class traffic no app-side policy can shed).
///
/// What the mode gives up, honestly: changes made ON this device (its
/// own watch points, edits, profile changes) reach the other devices
/// only during a live session — the backup is one-way, master to
/// followers. "Sync now" therefore runs a bounded x0x BURST: switch
/// the agent on, join the mesh, run one full sync cycle both ways,
/// linger briefly so the published changes gossip out, then switch
/// the agent off again — whatever happened. Joining takes a minute or
/// two and the mesh moves ~50 MB/min while connected, so a session
/// costs roughly 100–150 MB; the UI says so before starting one.
///
/// Interplay with the other switches: turning the mode on goes through
/// the same POST /mywatch/enabled switch as the Data page's pill (so
/// that pill honestly reads Off), and tells the mobile-data gate to
/// forget any pause it holds (otherwise Wi-Fi's return would switch
/// the agent back on behind the mode's back). Any MANUAL change on the
/// Data page pill clears the mode — touching the pill means the user
/// took direct control. Unlinking clears it too: the mode is a
/// property of being linked.
class LowDataMode extends ChangeNotifier {
  LowDataMode({
    MyWatchApi? api,
    this._gate,
    this._syncNow,
  }) : _api = api ?? MyWatchApi();

  /// Replaceable for tests.
  static LowDataMode instance = LowDataMode();

  static const _prefKey = 'low_data_mode_v1';

  final MyWatchApi _api;
  final X0xCellularGate? _gate;
  final Future<String> Function()? _syncNow;

  /// Burst tuning — fields so tests can shrink the real-time waits.
  /// Joining the mesh takes ~1–2 minutes on real networks.
  Duration joinTimeout = const Duration(minutes: 4);
  Duration joinPollInterval = const Duration(seconds: 3);

  /// After the sync cycle publishes, the agent stays up this long so
  /// the published store deltas gossip out before the disconnect.
  Duration linger = const Duration(seconds: 25);

  bool _enabled = false;
  bool _bursting = false;
  String? _burstStage;

  bool get enabled => _enabled;
  bool get bursting => _bursting;

  /// What the running burst is doing, for the screen; null when idle.
  String? get burstStage => _burstStage;

  /// Load the persisted mode and, when it is on, make sure the agent
  /// really is off (defensive — the core's own off marker persists, so
  /// this only matters after a failed burst teardown). Called once from
  /// main().
  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_prefKey) ?? false;
    notifyListeners();
    if (!_enabled) return;
    try {
      final s = await _api.status();
      if (s.supported && s.linked && s.enabled) {
        await _api.setEnabled(false);
      }
    } catch (_) {
      // Embedded client still booting — the core-side marker covers it.
    }
  }

  /// Flip the mode. Switching the agent happens FIRST, so a failure
  /// (embedded client unreachable) surfaces to the caller and leaves
  /// the stored mode unchanged.
  Future<void> setEnabled(bool on) async {
    if (on) {
      await (_gate ?? X0xCellularGate.instance)
          .noteManualChange(X0xAgent.myWatch);
      await _api.setEnabled(false);
    } else {
      await _api.setEnabled(true);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey, on);
    _enabled = on;
    notifyListeners();
  }

  /// The user changed the agent's own switch (the Data page pill):
  /// their direct control wins — the mode turns itself off without
  /// touching the agent again.
  Future<void> noteAgentManualChange() => clear();

  /// Forget the mode (pref off, agent untouched) — on manual pill
  /// changes and on unlink.
  Future<void> clear() async {
    if (!_enabled) return;
    _enabled = false;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey, false);
  }

  void _setStage(String? stage) {
    _burstStage = stage;
    notifyListeners();
  }

  /// One bounded live sync session (the mode's "Sync now"): agent on →
  /// wait for ready → one full sync cycle both ways → linger so the
  /// published deltas gossip out → agent off, no matter what happened.
  /// Returns the sync summary; throws with the agent back off on
  /// failure.
  Future<String> runBurst() async {
    if (_bursting) return 'A sync session is already running.';
    _bursting = true;
    _setStage('Joining your devices…');
    try {
      await _api.setEnabled(true);
      final deadline = DateTime.now().add(joinTimeout);
      var ready = false;
      while (!DateTime.now().isAfter(deadline)) {
        MyWatchStatus? s;
        try {
          s = await _api.status();
        } catch (_) {}
        if (s != null && s.linked && s.state == 'ready') {
          ready = true;
          break;
        }
        await Future<void>.delayed(joinPollInterval);
      }
      if (!ready) {
        throw MyWatchApiException(
            'Could not join your devices in time — try again later.');
      }
      _setStage('Syncing with your devices…');
      final summary = await (_syncNow ?? MyWatchSync.instance.syncNow)();
      _setStage('Finishing — letting the changes reach your devices…');
      await Future<void>.delayed(linger);
      return summary;
    } finally {
      // The whole point of the mode: the agent never stays on. Best
      // effort — initialize()'s enforcement catches a failure here at
      // the next launch.
      try {
        await _api.setEnabled(false);
      } catch (_) {}
      _bursting = false;
      _setStage(null);
    }
  }
}
