import 'dart:async';

import 'package:flutter/material.dart';

import '../screens/channels_screen.dart';
import '../screens/my_watch_screen.dart';
import '../services/channels_api.dart';
import '../services/embedded_client.dart';
import '../services/my_watch_sync.dart';
import '../theme/tokens.dart';

/// Connection/status rows at the bottom of the library drawer, below
/// the Settings tile — one per network surface, top to bottom: the
/// Autonomi client (peer count), My W@tch (device sync), and Channels
/// (public gossip network). Same dot-plus-plain-words style as the
/// home-screen status bar this replaces; the My W@tch and Channels
/// rows open their pages on tap.
class WiDrawerStatus extends StatefulWidget {
  const WiDrawerStatus({
    super.key,
    this.healthProvider,
    this.channelsStatusProvider,
  });

  /// Test override for [EmbeddedClient.health].
  final Future<ClientHealth> Function()? healthProvider;

  /// Test override for [ChannelsApi.status].
  final Future<ChannelsStatus> Function()? channelsStatusProvider;

  @override
  State<WiDrawerStatus> createState() => _WiDrawerStatusState();
}

class _WiDrawerStatusState extends State<WiDrawerStatus> {
  ClientHealth? _health;
  ChannelsStatus? _channels;
  Timer? _healthTimer;
  Timer? _channelsTimer;

  @override
  void initState() {
    super.initState();
    _pollHealth();
    _pollChannels();
  }

  @override
  void dispose() {
    _healthTimer?.cancel();
    _channelsTimer?.cancel();
    super.dispose();
  }

  Future<void> _pollHealth() async {
    final health = await (widget.healthProvider ?? EmbeddedClient.health)();
    if (!mounted) return;
    setState(() => _health = health);
    if (health.state == 'unavailable') return; // no native library; stop
    _healthTimer = Timer(
      Duration(seconds: health.state == 'ready' ? 15 : 3),
      _pollHealth,
    );
  }

  Future<void> _pollChannels() async {
    final ChannelsStatus status;
    try {
      status = await (widget.channelsStatusProvider ??
          ChannelsApi().status)();
    } catch (_) {
      return; // embedded client unreachable; row stays hidden
    }
    if (!mounted) return;
    setState(() => _channels = status);
    if (!status.supported) return;
    _channelsTimer = Timer(
      Duration(seconds: status.state == 'starting' ? 5 : 30),
      _pollChannels,
    );
  }

  /// Short "x min ago"-style stamp for the My W@tch row.
  static String _relative(int ms) {
    final delta =
        DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (delta.inSeconds < 60) return 'just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes} min ago';
    if (delta.inHours < 48) return '${delta.inHours} h ago';
    return '${delta.inDays} days ago';
  }

  void _openPage(Widget page) {
    final navigator = Navigator.of(context);
    navigator.pop(); // close the drawer
    navigator.push(MaterialPageRoute<void>(builder: (_) => page));
  }

  Widget _row(
    WiTokens t, {
    required Color color,
    required String text,
    bool spinner = false,
    VoidCallback? onTap,
  }) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          if (spinner)
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(strokeWidth: 1.5, color: color),
            )
          else
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: t.boneDim),
            ),
          ),
        ],
      ),
    );
    return onTap == null ? row : InkWell(onTap: onTap, child: row);
  }

  Widget _peersRow(WiTokens t) {
    final h = _health;
    if (h == null || h.state == 'unavailable') return const SizedBox.shrink();
    final (color, text) = switch (h.state) {
      'ready' => (
          const Color(0xff4caf50),
          'Connected · ${h.peers} ${h.peers == 1 ? 'peer' : 'peers'}',
        ),
      'connecting' => (t.accent, 'Connecting…'),
      _ => (const Color(0xffe57373), 'Connection error'),
    };
    return _row(t, color: color, text: text);
  }

  Widget _myWatchRow(WiTokens t, MyWatchSyncStatus s) {
    if (!s.supported) return const SizedBox.shrink();
    final (color, text) = switch (s) {
      MyWatchSyncStatus(linked: false) => (t.ash, 'My W@tch: not linked'),
      MyWatchSyncStatus(enabled: false) => (t.ash, 'My W@tch: switched off'),
      MyWatchSyncStatus(agentState: != 'ready') => (
          t.accent,
          'My W@tch: connecting…',
        ),
      MyWatchSyncStatus(syncing: true) => (t.accent, 'My W@tch: syncing…'),
      MyWatchSyncStatus(problems: [_, ...]) => (
          const Color(0xffffb74d),
          'My W@tch: sync issue',
        ),
      MyWatchSyncStatus(:final lastSyncMs?) => (
          const Color(0xff4caf50),
          'My W@tch: synced ${_relative(lastSyncMs)}',
        ),
      _ => (const Color(0xff4caf50), 'My W@tch: linked'),
    };
    return _row(t,
        color: color,
        text: text,
        onTap: () => _openPage(const MyWatchScreen()));
  }

  Widget _channelsRow(WiTokens t) {
    final c = _channels;
    if (c == null || !c.supported) return const SizedBox.shrink();
    final (color, text) = switch (c) {
      ChannelsStatus(enabled: false) => (t.ash, 'Channels: switched off'),
      ChannelsStatus(state: 'ready') => (
          const Color(0xff4caf50),
          'Channels: connected',
        ),
      ChannelsStatus(state: 'starting') => (
          WiTokens.channelAmber,
          'Channels: connecting…',
        ),
      _ => (t.ash, 'Channels: not connected'),
    };
    return _row(t,
        color: color,
        text: text,
        spinner: c.state == 'starting',
        onTap: () => _openPage(const ChannelsScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _peersRow(t),
        ValueListenableBuilder<MyWatchSyncStatus>(
          valueListenable: MyWatchSync.status,
          builder: (context, s, _) => _myWatchRow(t, s),
        ),
        _channelsRow(t),
      ],
    );
  }
}
