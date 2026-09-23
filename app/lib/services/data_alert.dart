import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_list.dart';
import '../widgets/messenger.dart';
import 'app_settings.dart';
import 'embedded_client.dart';

/// The Daily data alert (Settings → Network → Data): a quiet
/// once-per-day notice when the current local day's usage passes the
/// chosen level. ALERT-ONLY by design — nothing is ever paused or cut
/// off; streaming, downloads and sync all continue (pausing belongs to
/// the user's own Offline mode / auto-pause choices).
///
/// The check polls `GET /stats` on a slow timer (the counters live in
/// the native core; today's total comes from its daily buckets, so the
/// day boundary and a period reset are both handled for free). One
/// notice per local day, remembered in prefs across restarts.
class DataAlert {
  DataAlert({
    Future<DataUsageStats?> Function()? stats,
    DateTime Function()? clock,
  })  : _stats = stats ?? EmbeddedClient.stats,
        _clock = clock ?? DateTime.now;

  /// Replaceable for tests (fresh instance per test).
  static DataAlert instance = DataAlert();

  static const _notifiedDayKey = 'data_alert_notified_day_v1';

  final Future<DataUsageStats?> Function() _stats;
  final DateTime Function() _clock;
  Timer? _first;
  Timer? _timer;

  /// Begin the background checks (call once from main). The first check
  /// waits a moment so app startup isn't the thing it races.
  void start({
    Duration first = const Duration(minutes: 1),
    Duration every = const Duration(minutes: 5),
  }) {
    if (_timer != null || _first != null) return;
    _first = Timer(first, () {
      unawaited(check());
      _timer = Timer.periodic(every, (_) => unawaited(check()));
    });
  }

  void dispose() {
    _first?.cancel();
    _first = null;
    _timer?.cancel();
    _timer = null;
  }

  /// One check: today's usage vs the chosen level; shows the once-a-day
  /// snackbar when passed. Public so tests (and the Data page, if it
  /// ever wants an immediate re-check) can drive it directly.
  Future<void> check() async {
    final gb = await AppSettings.dataAlertGb();
    if (gb <= 0) return;
    final stats = await _stats();
    final today = stats?.dayFor(_clock());
    if (today == null) return; // old core (no days), or nothing counted
    final threshold = gb * 1024 * 1024 * 1024;
    if (today.total.total < threshold) return;
    final prefs = await SharedPreferences.getInstance();
    final key = localDayKey(_clock());
    if (prefs.getString(_notifiedDayKey) == key) return;
    final messenger = wiMessengerKey.currentState;
    if (messenger == null) return; // no UI yet — retry next check
    messenger.showSnackBar(SnackBar(
      duration: const Duration(seconds: 8),
      content: Text(
        "Today's data usage is ${formatBytes(today.total.total)} — over "
        'your $gb GB daily alert. Details in Settings → Network → Data.',
      ),
    ));
    // Marked only after the snackbar actually showed, so a headless
    // start can't burn the day's one notice.
    await prefs.setString(_notifiedDayKey, key);
  }
}
