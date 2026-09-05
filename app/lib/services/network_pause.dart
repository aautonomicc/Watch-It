import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_settings.dart';
import 'batch_upload.dart';
import 'channels_api.dart';
import 'download_manager.dart';
import 'embedded_client.dart';
import 'my_watch_api.dart';
import 'x0x_cellular.dart' show X0xAgent;

/// The Settings → Network "Offline mode" switch (named "Pause all
/// network activity" before the 2026-09-05 reorg).
///
/// Pausing disconnects the embedded Autonomi client (POST /network/pause
/// — streaming stops, the reconnect supervisor parks, the DHT/keepalive
/// trickle of an idle-but-connected app goes away) and switches off both
/// x0x agents through the same POST /…/enabled switch their own toggles
/// use. Which agents THIS pause switched off is remembered (prefs), so
/// resuming re-enables exactly those: a user's own "off" is never
/// overridden, mirroring [X0xCellularGate]. The pause itself persists
/// across restarts ([AppSettings.networkPaused]); the agents' off state
/// persists in the core's own marker files, so [start] only needs to
/// re-apply the Autonomi pause.
///
/// Downloads park themselves: a transfer failing while the core reports
/// `paused` counts as lost connectivity (pausedBySystem), and resuming
/// restarts them via [DownloadManager.onAppResumed].
///
/// AUTO-PAUSE (2026-09-03): the same pause also engages on its own after
/// [idleMinutes] with nothing playing, downloading or uploading (an
/// idle-but-connected app trickles 10–25 MB/h of DHT/keepalive traffic).
/// An auto pause lifts itself the moment the user does something that
/// needs the network — [noteActivity] runs before every playback open
/// and download start — while a pause the user flipped by hand is never
/// auto-resumed. [autoPaused] persists so a restart keeps the
/// distinction.
class NetworkPause extends ChangeNotifier {
  NetworkPause({
    String? base,
    String? token,
    MyWatchApi? myWatchApi,
    ChannelsApi? channelsApi,
    DateTime Function()? now,
    bool Function()? downloadsActive,
    bool Function()? uploadsActive,
  })  : _baseOverride = base,
        _tokenOverride = token,
        _myWatchApiOverride = myWatchApi,
        _channelsApiOverride = channelsApi,
        _now = now ?? DateTime.now,
        _downloadsActiveOverride = downloadsActive,
        _uploadsActiveOverride = uploadsActive {
    _lastActivity = _now();
  }

  /// Replaceable for tests (fresh instance per test).
  static NetworkPause instance = NetworkPause();

  static const _agentsKey = 'network_pause_x0x_v1';
  static const _autoPausedKey = 'network_autopaused_v1';

  final String? _baseOverride;
  final String? _tokenOverride;
  final MyWatchApi? _myWatchApiOverride;
  final ChannelsApi? _channelsApiOverride;
  final DateTime Function() _now;
  final bool Function()? _downloadsActiveOverride;
  final bool Function()? _uploadsActiveOverride;

  bool _paused = false;
  bool _autoPaused = false;
  bool _loaded = false;
  int _idleMinutes = 30;
  late DateTime _lastActivity;
  Timer? _idleTimer;
  final Set<X0xAgent> _pausedAgents = {};

  /// Playback surfaces currently streaming/playing (see
  /// [setStreamingActive]).
  final Set<Object> _streamers = {};

  /// Whether the network pause is on.
  bool get paused => _paused;

  /// Whether the current pause was applied by the idle timer (as
  /// opposed to the user's own flip) — only such a pause is lifted by
  /// [noteActivity].
  bool get autoPaused => _autoPaused;

  /// Minutes of idle time before the automatic pause; 0 = off.
  int get idleMinutes => _idleMinutes;

  /// Whether [agent] is switched off by this pause (as opposed to by
  /// the user's own x0x toggle) — for status-row wording.
  bool isAgentPaused(X0xAgent agent) => _pausedAgents.contains(agent);

  /// Call once from main() after [EmbeddedClient.start]: re-applies a
  /// persisted pause to the freshly started core and starts the idle
  /// timer. The Rust-side flag is process state; the x0x agents' off
  /// state persists on its own.
  Future<void> start() async {
    await ensureLoaded();
    if (_paused) {
      notifyListeners();
      await _postCorePause(true);
    }
    _idleTimer ??=
        Timer.periodic(const Duration(minutes: 1), (_) => checkIdle());
  }

  /// Loads the persisted state (idempotent). UI reading [paused] before
  /// [start] ran may call it to avoid a stale first frame.
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    _paused = await AppSettings.networkPaused();
    _idleMinutes = await AppSettings.networkAutoPauseMinutes();
    final prefs = await SharedPreferences.getInstance();
    _autoPaused = _paused && (prefs.getBool(_autoPausedKey) ?? false);
    for (final name in prefs.getStringList(_agentsKey) ?? const []) {
      final agent = X0xAgent.values.asNameMap()[name];
      if (agent != null) _pausedAgents.add(agent);
    }
  }

  /// Flip the pause. Each surface is best-effort on its own, so one
  /// unreachable piece never wedges the rest; the persisted flag is the
  /// source of truth either way. `auto` marks an idle-timer pause,
  /// which user activity may lift again.
  Future<void> setPaused(bool value, {bool auto = false}) async {
    await ensureLoaded();
    _paused = value;
    _autoPaused = value && auto;
    if (!value) _lastActivity = _now();
    await AppSettings.setNetworkPaused(value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoPausedKey, _autoPaused);
    notifyListeners();
    await _postCorePause(value);
    if (value) {
      await _pauseAgents();
    } else {
      await _resumeAgents();
      // Downloads the pause parked restart now, policy permitting.
      await DownloadManager.instance.onAppResumed();
    }
  }

  /// Set the idle threshold (Settings → Network → Auto-pause when
  /// idle); 0 switches the automatic pause off.
  Future<void> setIdleMinutes(int minutes) async {
    await ensureLoaded();
    _idleMinutes = minutes;
    _lastActivity = _now();
    await AppSettings.setNetworkAutoPauseMinutes(minutes);
    notifyListeners();
  }

  /// The user did something that needs the network (opened a stream,
  /// started a download): stamp the idle clock and lift an automatic
  /// pause. A manual pause stays — the user asked for silence.
  Future<void> noteActivity() async {
    await ensureLoaded();
    _lastActivity = _now();
    if (_paused && _autoPaused) {
      await setPaused(false);
    }
  }

  /// Playback surfaces report themselves here (keyed by identity so a
  /// video player and the album player can't clear each other's state).
  /// While any is active the idle timer never fires; becoming active
  /// also counts as activity, lifting an automatic pause.
  void setStreamingActive(Object source, bool active) {
    _lastActivity = _now();
    if (active) {
      _streamers.add(source);
      if (_paused && _autoPaused) unawaited(noteActivity());
    } else {
      _streamers.remove(source);
    }
  }

  /// One idle-timer tick (public so tests can drive it): pauses
  /// automatically once [idleMinutes] have passed with no playback, no
  /// active download and no upload batch in flight.
  Future<void> checkIdle() async {
    await ensureLoaded();
    if (_paused || _idleMinutes <= 0) return;
    if (_networkBusy) {
      _lastActivity = _now();
      return;
    }
    if (_now().difference(_lastActivity) >=
        Duration(minutes: _idleMinutes)) {
      await setPaused(true, auto: true);
    }
  }

  bool get _networkBusy =>
      _streamers.isNotEmpty ||
      (_downloadsActiveOverride?.call() ??
          DownloadManager.instance.hasActive) ||
      (_uploadsActiveOverride?.call() ?? _uploadBusy);

  /// A batch mid-prepare or mid-upload must never be paused under
  /// (uploads spend real money); review/done pages just sit there.
  static bool get _uploadBusy {
    final stage = BatchUploadSession.instance.stage;
    return stage == BatchStage.preparing || stage == BatchStage.uploading;
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    super.dispose();
  }

  MyWatchApi get _myWatch => _myWatchApiOverride ?? MyWatchApi();
  ChannelsApi get _channels => _channelsApiOverride ?? ChannelsApi();

  /// Switch off each agent that is actually on, remembering it — a
  /// user's own "off" stays theirs and is not re-enabled on resume.
  Future<void> _pauseAgents() async {
    try {
      final s = await _myWatch.status();
      if (s.supported && s.enabled) {
        await _myWatch.setEnabled(false);
        _pausedAgents.add(X0xAgent.myWatch);
      }
    } catch (_) {
      // Embedded client unreachable — nothing running to pause.
    }
    try {
      final s = await _channels.status();
      if (s.supported && s.enabled) {
        await _channels.setEnabled(false);
        _pausedAgents.add(X0xAgent.channels);
      }
    } catch (_) {}
    await _persistAgents();
    notifyListeners();
  }

  Future<void> _resumeAgents() async {
    for (final agent in _pausedAgents.toList()) {
      try {
        switch (agent) {
          case X0xAgent.myWatch:
            await _myWatch.setEnabled(true);
          case X0xAgent.channels:
            await _channels.setEnabled(true);
        }
        _pausedAgents.remove(agent);
      } catch (_) {
        // Keep the memory so the next resume attempt retries.
      }
    }
    await _persistAgents();
    notifyListeners();
  }

  Future<void> _persistAgents() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        _agentsKey, [for (final a in _pausedAgents) a.name]);
  }

  /// POST /network/pause on the embedded core (auth-guarded route).
  Future<void> _postCorePause(bool paused) async {
    final base = _baseOverride ?? EmbeddedClient.baseUrl();
    if (base == null) return; // no native library (tests, bare desktop)
    final token = _tokenOverride ?? EmbeddedClient.authToken();
    final client = http.Client();
    try {
      await client.post(
        Uri.parse('${base.replaceFirst(RegExp(r'/+$'), '')}/network/pause'),
        headers: {
          'content-type': 'application/json',
          'x-watchit-auth': ?token,
        },
        body: jsonEncode({'paused': paused}),
      );
    } catch (_) {
      // Core unreachable; the persisted flag re-applies on next start.
    } finally {
      client.close();
    }
  }
}
