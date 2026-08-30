import 'dart:async';

import 'package:flutter/material.dart';

import '../services/channels_api.dart';
import '../services/my_watch_api.dart';
import '../services/my_watch_sync.dart';
import '../services/x0x_cellular.dart';
import '../theme/tokens.dart';
import '../widgets/messenger.dart';

/// Settings → Network → Built-in x0x client: the peer-to-peer gossip
/// agent My W@tch and Channels ride on. Two independent switches stop
/// either feature's agent — and all of its background network traffic —
/// without touching the link, channel key or subscriptions, so
/// switching one back on picks up exactly where it left off.
class X0xClientScreen extends StatefulWidget {
  const X0xClientScreen(
      {super.key, this.myWatchApi, this.channelsApi, this.gate});

  /// Test overrides.
  final MyWatchApi? myWatchApi;
  final ChannelsApi? channelsApi;
  final X0xCellularGate? gate;

  @override
  State<X0xClientScreen> createState() => _X0xClientScreenState();
}

class _X0xClientScreenState extends State<X0xClientScreen> {
  MyWatchStatus? _myWatch;
  ChannelsStatus? _channels;
  bool _busyMyWatch = false;
  bool _busyChannels = false;
  Timer? _pollTimer;

  MyWatchApi get _myWatchApi => widget.myWatchApi ?? MyWatchApi();
  ChannelsApi get _channelsApi => widget.channelsApi ?? ChannelsApi();
  X0xCellularGate get _gate => widget.gate ?? X0xCellularGate.instance;

  @override
  void initState() {
    super.initState();
    // Paused-on-mobile-data flags can flip while the page is open.
    _gate.ensureLoaded().then((_) {
      if (mounted) setState(() {});
    });
    _gate.addListener(_onGateChanged);
    _reload();
  }

  @override
  void dispose() {
    _gate.removeListener(_onGateChanged);
    _pollTimer?.cancel();
    super.dispose();
  }

  void _onGateChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _reload() async {
    _pollTimer?.cancel();
    MyWatchStatus? myWatch;
    ChannelsStatus? channels;
    try {
      myWatch = await _myWatchApi.status();
    } catch (_) {
      // Embedded client unreachable; the tile says "checking".
    }
    try {
      channels = await _channelsApi.status();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _myWatch = myWatch ?? _myWatch;
      _channels = channels ?? _channels;
    });
    // Keep the state lines live while an agent is still coming up.
    final starting = _myWatch?.state == 'starting' ||
        _channels?.state == 'starting';
    _pollTimer = Timer(Duration(seconds: starting ? 5 : 30), _reload);
  }

  Future<void> _setMyWatchEnabled(bool on) async {
    setState(() => _busyMyWatch = true);
    try {
      // An explicit flip wins over the mobile-data gate: forget any
      // pause it holds so Wi-Fi's return won't override this choice.
      await _gate.noteManualChange(X0xAgent.myWatch);
      await _myWatchApi.setEnabled(on);
    } catch (e) {
      wiMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text('Could not change the switch: $e')),
      );
    }
    if (mounted) setState(() => _busyMyWatch = false);
    await _reload();
    // Refresh the sync service's status too, so the drawer row and the
    // My W@tch page reflect the switch without waiting a cycle.
    unawaited(
        MyWatchSync.instance.syncNow().then((_) {}, onError: (_) {}));
  }

  Future<void> _setChannelsEnabled(bool on) async {
    setState(() => _busyChannels = true);
    try {
      await _gate.noteManualChange(X0xAgent.channels);
      await _channelsApi.setEnabled(on);
    } catch (e) {
      wiMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text('Could not change the switch: $e')),
      );
    }
    if (mounted) setState(() => _busyChannels = false);
    await _reload();
  }

  /// One line of plain words under each switch: what the feature is
  /// doing right now.
  String _myWatchStateLine(MyWatchStatus? s) {
    if (s == null) return 'Checking…';
    if (!s.supported) return 'Not available on this platform';
    if (!s.enabled) {
      // Off because Settings → Network → Mobile data said Wi-Fi only,
      // not because the user flipped this switch.
      return _gate.isPaused(X0xAgent.myWatch)
          ? 'Paused on mobile data — resumes on Wi-Fi'
          : 'Switched off — nothing syncs between devices';
    }
    if (!s.linked) return 'On — no devices linked yet';
    return switch (s.state) {
      'ready' => 'On — connected to your devices',
      'starting' => 'On — connecting…',
      _ => 'On',
    };
  }

  String _channelsStateLine(ChannelsStatus? s) {
    if (s == null) return 'Checking…';
    if (!s.supported) return 'Not available on this platform';
    if (!s.enabled) {
      return _gate.isPaused(X0xAgent.channels)
          ? 'Paused on mobile data — resumes on Wi-Fi'
          : 'Switched off — channels get no updates; your own '
              'publishes wait here until it is back on';
    }
    final count = s.subs.length + (s.own != null ? 1 : 0);
    if (count == 0) return 'On — no channels yet';
    return switch (s.state) {
      'ready' => 'On — connected to the channel network',
      'starting' => 'On — connecting…',
      _ => 'On',
    };
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final myWatch = _myWatch;
    final channels = _channels;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Text('Built-in x0x client',
            style: TextStyle(color: t.bone, fontSize: 18)),
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
            child: Text(
              'Channels and My W@tch talk to each other over x0x, a '
              'peer-to-peer gossip network embedded in the app '
              '(separate from the Autonomi client that streams and '
              'downloads media). Keeping a feature on uses some '
              'background data even while you are not using the app '
              'screen — switch one off here to stop its network '
              'traffic entirely. Your device links, channel key and '
              'subscriptions are kept, so switching back on picks up '
              'exactly where it left off.',
              style: TextStyle(fontSize: 12.5, color: t.boneDim),
            ),
          ),
          // Channels above My W@tch — same order as Settings' CONTENT
          // section, so the two lists read alike.
          SwitchListTile(
            secondary:
                const Icon(Icons.podcasts, color: WiTokens.channelAmber),
            title: Text('Channels',
                style: TextStyle(color: t.bone, fontSize: 15)),
            subtitle: Text(
              _channelsStateLine(channels),
              style: TextStyle(color: t.ash, fontSize: 12),
            ),
            value: channels?.enabled ?? true,
            onChanged:
                _busyChannels || channels == null || !channels.supported
                    ? null
                    : _setChannelsEnabled,
          ),
          SwitchListTile(
            secondary: Icon(Icons.devices_outlined, color: t.accent),
            title: Text('My W@tch',
                style: TextStyle(color: t.bone, fontSize: 15)),
            subtitle: Text(
              _myWatchStateLine(myWatch),
              style: TextStyle(color: t.ash, fontSize: 12),
            ),
            value: myWatch?.enabled ?? true,
            onChanged:
                _busyMyWatch || myWatch == null || !myWatch.supported
                    ? null
                    : _setMyWatchEnabled,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              'While a switch is off the feature simply pauses: linked '
              'devices stop hearing from this one, subscribed channels '
              'stop updating, and nothing you do here is lost. Joining '
              'a link, creating a channel or subscribing turns the '
              'matching switch back on automatically.',
              style: TextStyle(fontSize: 11.5, color: t.ash),
            ),
          ),
        ],
      ),
    );
  }
}
