import 'dart:async';

import 'package:flutter/material.dart';

import '../screens/my_watch_screen.dart';
import '../services/backup_follow.dart';
import '../services/embedded_client.dart';
import '../services/low_data_mode.dart';
import '../services/my_watch_sync.dart';
import '../services/network_pause.dart';
import '../services/profiles.dart';
import '../services/x0x_cellular.dart';
import '../theme/tokens.dart';
import 'pair_dialogs.dart';

/// Connection/status rows at the top of the library drawer, above the
/// list section — one per network surface, top to bottom: the
/// Autonomi client (peer count) and My W@tch (device sync). Same
/// dot-plus-plain-words style as the home-screen status bar this
/// replaces; the My W@tch row opens its page on tap.
class WiDrawerStatus extends StatefulWidget {
  const WiDrawerStatus({
    super.key,
    this.pinned = false,
    this.healthProvider,
  });

  /// True inside the desktop pinned side panel. There is no modal drawer
  /// route to close there, so a tap must not pop — popping removed the
  /// HOME route under the pushed page, leaving it with no back arrow
  /// (tester report: "lose the arrow to get back, have to close app").
  final bool pinned;

  /// Test override for [EmbeddedClient.health].
  final Future<ClientHealth> Function()? healthProvider;

  @override
  State<WiDrawerStatus> createState() => _WiDrawerStatusState();
}

class _WiDrawerStatusState extends State<WiDrawerStatus> {
  ClientHealth? _health;
  Timer? _healthTimer;

  @override
  void initState() {
    super.initState();
    _pollHealth();
    // "Paused on mobile data" vs "switched off" wording can flip while
    // the drawer is open (walking out of Wi-Fi range); same for the
    // all-network pause — and the live-activity sources (a low-data
    // burst's stage, a running pairing, a backup follow fetch) all
    // change while the drawer sits open.
    X0xCellularGate.instance.addListener(_onGateChanged);
    NetworkPause.instance.addListener(_onGateChanged);
    LowDataMode.instance.addListener(_onGateChanged);
    BackupFollowService.status.addListener(_onGateChanged);
    MyWatchPairActivity.status.addListener(_onGateChanged);
  }

  @override
  void dispose() {
    X0xCellularGate.instance.removeListener(_onGateChanged);
    NetworkPause.instance.removeListener(_onGateChanged);
    LowDataMode.instance.removeListener(_onGateChanged);
    BackupFollowService.status.removeListener(_onGateChanged);
    MyWatchPairActivity.status.removeListener(_onGateChanged);
    _healthTimer?.cancel();
    super.dispose();
  }

  void _onGateChanged() {
    if (mounted) setState(() {});
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

  /// Short "x min ago"-style stamp for the My W@tch row.
  static String _relative(int ms) {
    final delta = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(ms),
    );
    if (delta.inSeconds < 60) return 'just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes} min ago';
    if (delta.inHours < 48) return '${delta.inHours} h ago';
    return '${delta.inDays} days ago';
  }

  void _openPage(Widget page) {
    final navigator = Navigator.of(context);
    if (!widget.pinned) navigator.pop(); // close the modal drawer
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
      'paused' => (t.ash, 'Network paused'),
      _ => (const Color(0xffe57373), 'Connection error'),
    };
    return _row(t, color: color, text: text);
  }

  /// Lowercase a stage line's first letter so it reads naturally after
  /// the "My W@tch: " prefix ("Joining your devices…" → "joining …").
  static String _lower(String s) =>
      s.isEmpty ? s : s[0].toLowerCase() + s.substring(1);

  Widget _myWatchRow(WiTokens t, MyWatchSyncStatus s) {
    if (!s.supported) return const SizedBox.shrink();
    // Status is fine for everyone; the page behind it is an admin
    // surface (device linking).
    final onTap = ProfileStore.instance.isAdmin
        ? () => _openPage(const MyWatchScreen())
        : null;

    // Live activity beats the resting states — the row narrates what
    // My W@tch is doing RIGHT NOW during a pairing, a low-data "Sync
    // now" burst, or a backup follow fetch (user ask 2026-10-12).
    final pairing = MyWatchPairActivity.status.value;
    if (pairing != null) {
      return _row(t,
          color: t.accent,
          spinner: true,
          text: 'My W@tch: $pairing',
          onTap: onTap);
    }
    if (s.linked) {
      final burst = LowDataMode.instance.burstStage;
      if (burst != null) {
        return _row(t,
            color: t.accent,
            spinner: true,
            text: 'My W@tch: ${_lower(burst)}',
            onTap: onTap);
      }
      final follow = BackupFollowService.status.value;
      if (follow.fetching) {
        final n = follow.total > 0
            ? ' (${follow.done} of ${follow.total})'
            : '…';
        return _row(t,
            color: t.accent,
            spinner: true,
            text:
                'My W@tch: ${follow.firstTime ? 'recovering the library from the backup' : 'catching up from the backup'}$n',
            onTap: onTap);
      }
    }
    final (color, text) = switch (s) {
      MyWatchSyncStatus(linked: false) => (t.ash, 'My W@tch: not linked'),
      MyWatchSyncStatus(enabled: false) => (
        t.ash,
        NetworkPause.instance.isAgentPaused(X0xAgent.myWatch)
            ? 'My W@tch: paused with the network'
            : LowDataMode.instance.enabled
            ? 'My W@tch: low-data mode'
            : X0xCellularGate.instance.isPaused(X0xAgent.myWatch)
            ? 'My W@tch: paused on mobile data'
            : 'My W@tch: switched off',
      ),
      MyWatchSyncStatus(agentState: != 'ready') => (
        t.accent,
        'My W@tch: connecting…',
      ),
      MyWatchSyncStatus(syncing: true, activity: final a?) => (
        t.accent,
        'My W@tch: ${_lower(a)}',
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
    return _row(
      t,
      color: color,
      text: text,
      onTap: onTap,
      spinner: s.syncing,
    );
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
      ],
    );
  }
}
