import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:package_info_plus/package_info_plus.dart';

import '../services/channels_api.dart';
import '../services/embedded_client.dart';
import '../services/my_watch_api.dart';
import '../services/my_watch_sync.dart';
import '../services/x0x_cellular.dart';
import '../theme/tokens.dart';
import '../widgets/messenger.dart';

/// Settings → Network → Built-in clients: the two networks embedded in
/// the app on one page. The Autonomi client streams and downloads
/// media; the x0x client is the peer-to-peer gossip network behind
/// Channels and My W@tch, with two independent switches that stop
/// either feature's agent — and all of its background network traffic —
/// without touching the link, channel key or subscriptions. Each
/// client's version is read live from the native library
/// (`GET /versions`, baked out of Cargo.lock at build time — never
/// hardcoded here), with the deeper stack behind a Details expansion
/// and a copy button for bug reports.
class BuiltInClientsScreen extends StatefulWidget {
  const BuiltInClientsScreen({
    super.key,
    this.myWatchApi,
    this.channelsApi,
    this.gate,
    this.healthProvider,
    this.versionsProvider,
  });

  /// Test overrides.
  final MyWatchApi? myWatchApi;
  final ChannelsApi? channelsApi;
  final X0xCellularGate? gate;
  final Future<ClientHealth> Function()? healthProvider;
  final Future<ClientVersions?> Function()? versionsProvider;

  @override
  State<BuiltInClientsScreen> createState() => _BuiltInClientsScreenState();
}

class _BuiltInClientsScreenState extends State<BuiltInClientsScreen> {
  ClientHealth? _health;
  ClientVersions? _versions;
  String? _appVersion;
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
    _loadVersions();
    _loadAppVersion();
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

  /// Versions never change while the process runs — fetch once.
  Future<void> _loadVersions() async {
    final v = await (widget.versionsProvider ?? EmbeddedClient.versions)();
    if (mounted) setState(() => _versions = v);
  }

  Future<void> _loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(
            () => _appVersion = '${info.version} (build ${info.buildNumber})');
      }
    } catch (_) {
      // Platform channel unavailable (tests, bare desktop builds).
    }
  }

  Future<void> _reload() async {
    _pollTimer?.cancel();
    ClientHealth? health;
    MyWatchStatus? myWatch;
    ChannelsStatus? channels;
    try {
      health = await (widget.healthProvider ?? EmbeddedClient.health)();
    } catch (_) {
      // Embedded client unreachable; the tiles say "checking".
    }
    try {
      myWatch = await _myWatchApi.status();
    } catch (_) {}
    try {
      channels = await _channelsApi.status();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _health = health ?? _health;
      _myWatch = myWatch ?? _myWatch;
      _channels = channels ?? _channels;
    });
    // Keep the state lines live while anything is still coming up.
    final busy = _health?.state == 'connecting' ||
        _myWatch?.state == 'starting' ||
        _channels?.state == 'starting';
    _pollTimer = Timer(Duration(seconds: busy ? 5 : 30), _reload);
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

  /// Everything a bug report wants, one clipboard payload.
  String get _copyText {
    final v = _versions;
    return [
      'W@tch ${_appVersion ?? 'unknown'}',
      if (v != null) ...[
        'ant-core ${v.antCore}',
        'x0x ${v.x0x}',
        'saorsa-core ${v.saorsaCore}',
        'saorsa-gossip ${v.saorsaGossip}',
        'ant-quic ${v.antQuic}',
      ],
    ].join('\n');
  }

  Future<void> _copyVersions() async {
    await Clipboard.setData(ClipboardData(text: _copyText));
    wiMessengerKey.currentState?.showSnackBar(
      const SnackBar(content: Text('Versions copied')),
    );
  }

  Widget _sectionHeader(WiTokens t, String label) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            letterSpacing: 1.5,
            fontWeight: FontWeight.w700,
            color: t.ash,
          ),
        ),
      );

  Widget _versionRow(WiTokens t, String name, String version) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
        child: Row(
          children: [
            Expanded(
              child: Text(name,
                  style: TextStyle(color: t.boneDim, fontSize: 12.5)),
            ),
            Text(
              version,
              style: TextStyle(
                  color: t.bone, fontSize: 12.5, fontFamily: 'monospace'),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final myWatch = _myWatch;
    final channels = _channels;
    final versions = _versions;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Text('Built-in clients',
            style: TextStyle(color: t.bone, fontSize: 18)),
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
            child: Text(
              'Two networks are built into the app. The Autonomi client '
              'streams and downloads your media — nothing to set up. The '
              'x0x client is a separate peer-to-peer gossip network that '
              'Channels and My W@tch talk over; keeping a feature on uses '
              'some background data even while you are not using the app '
              'screen, so each has its own switch here.',
              style: TextStyle(fontSize: 12.5, color: t.boneDim),
            ),
          ),
          _sectionHeader(t, 'AUTONOMI CLIENT'),
          ListTile(
            leading: Icon(Icons.cloud_outlined, color: t.accent),
            title: Text('Connection',
                style: TextStyle(color: t.bone, fontSize: 15)),
            subtitle: Text(
              _health?.label ?? 'Checking…',
              style: TextStyle(color: t.ash, fontSize: 12),
            ),
            trailing: Icon(Icons.refresh, color: t.ash, size: 18),
            onTap: _reload,
          ),
          if (versions != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'ant-core ${versions.antCore}',
                style: TextStyle(
                    color: t.ash, fontSize: 11.5, fontFamily: 'monospace'),
              ),
            ),
          _sectionHeader(t, 'X0X CLIENT'),
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
          if (versions != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'x0x ${versions.x0x}',
                style: TextStyle(
                    color: t.ash, fontSize: 11.5, fontFamily: 'monospace'),
              ),
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
          if (versions != null)
            ExpansionTile(
              leading: Icon(Icons.commit_outlined, color: t.accent),
              title: Text('Version details',
                  style: TextStyle(color: t.bone, fontSize: 15)),
              subtitle: Text(
                'The full network stack in this build',
                style: TextStyle(color: t.ash, fontSize: 12),
              ),
              iconColor: t.ash,
              collapsedIconColor: t.ash,
              childrenPadding: const EdgeInsets.only(bottom: 8),
              children: [
                _versionRow(t, 'App', _appVersion ?? 'unknown'),
                _versionRow(t, 'ant-core', versions.antCore),
                _versionRow(t, 'x0x', versions.x0x),
                _versionRow(t, 'saorsa-core', versions.saorsaCore),
                _versionRow(t, 'saorsa-gossip', versions.saorsaGossip),
                _versionRow(t, 'ant-quic', versions.antQuic),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                    child: TextButton.icon(
                      onPressed: _copyVersions,
                      icon: Icon(Icons.copy, size: 16, color: t.accent),
                      label: Text('Copy versions',
                          style:
                              TextStyle(color: t.accent, fontSize: 13)),
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
