import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_settings.dart';
import 'channels_api.dart';
import 'download_manager.dart';
import 'embedded_client.dart';
import 'my_watch_api.dart';
import 'x0x_cellular.dart' show X0xAgent;

/// The Settings → Network "Pause all network activity" switch.
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
class NetworkPause extends ChangeNotifier {
  NetworkPause({
    String? base,
    String? token,
    MyWatchApi? myWatchApi,
    ChannelsApi? channelsApi,
  })  : _baseOverride = base,
        _tokenOverride = token,
        _myWatchApiOverride = myWatchApi,
        _channelsApiOverride = channelsApi;

  /// Replaceable for tests (fresh instance per test).
  static NetworkPause instance = NetworkPause();

  static const _agentsKey = 'network_pause_x0x_v1';

  final String? _baseOverride;
  final String? _tokenOverride;
  final MyWatchApi? _myWatchApiOverride;
  final ChannelsApi? _channelsApiOverride;

  bool _paused = false;
  bool _loaded = false;
  final Set<X0xAgent> _pausedAgents = {};

  /// Whether the user's network pause is on.
  bool get paused => _paused;

  /// Whether [agent] is switched off by this pause (as opposed to by
  /// the user's own x0x toggle) — for status-row wording.
  bool isAgentPaused(X0xAgent agent) => _pausedAgents.contains(agent);

  /// Call once from main() after [EmbeddedClient.start]: re-applies a
  /// persisted pause to the freshly started core. The Rust-side flag is
  /// process state; the x0x agents' off state persists on its own.
  Future<void> start() async {
    await ensureLoaded();
    if (_paused) {
      notifyListeners();
      await _postCorePause(true);
    }
  }

  /// Loads the persisted state (idempotent). UI reading [paused] before
  /// [start] ran may call it to avoid a stale first frame.
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    _paused = await AppSettings.networkPaused();
    final prefs = await SharedPreferences.getInstance();
    for (final name in prefs.getStringList(_agentsKey) ?? const []) {
      final agent = X0xAgent.values.asNameMap()[name];
      if (agent != null) _pausedAgents.add(agent);
    }
  }

  /// Flip the pause. Each surface is best-effort on its own, so one
  /// unreachable piece never wedges the rest; the persisted flag is the
  /// source of truth either way.
  Future<void> setPaused(bool value) async {
    await ensureLoaded();
    _paused = value;
    await AppSettings.setNetworkPaused(value);
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
