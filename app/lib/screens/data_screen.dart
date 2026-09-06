import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_list.dart';
import '../services/app_settings.dart';
import '../services/channels_api.dart';
import '../services/download_manager.dart';
import '../services/embedded_client.dart';
import '../services/my_watch_api.dart';
import '../services/my_watch_sync.dart';
import '../services/network_pause.dart';
import '../services/x0x_cellular.dart';
import '../theme/tokens.dart';
import '../widgets/messenger.dart';

/// Choices for Auto-pause when idle (minutes of idle time before
/// [NetworkPause] pauses the network; 0 = off).
const kAutoPauseOptionsMinutes = [0, 10, 20, 30, 60];

/// Human label for an auto-pause threshold: `30 minutes`, `1 hour`.
String idleMinutesLabel(int minutes) =>
    minutes >= 60 ? '1 hour' : '$minutes minutes';

/// Where a built-in client's network use may happen — the three-way
/// pill under each x0x client (2026-09-06 reorg): Off stops the agent
/// entirely, Wi-Fi keeps it off cellular, Wi-Fi + mobile lets it run
/// anywhere.
enum ClientNetMode { off, wifi, wifiAndMobile }

/// Settings → Network → Data: everything data on one page (2026-09-06
/// reorg, replacing the Data usage / Data saving / Mobile data /
/// Built-in clients sub-pages). Top to bottom: the running usage
/// counters, Auto-pause when idle, the two built-in clients with a
/// compact Off / Wi-Fi / Wi-Fi + mobile pill each, and the streaming +
/// download mobile-data policies. The always-manual Offline mode
/// switch stays on the Network section above this page's tile.
class DataScreen extends StatefulWidget {
  const DataScreen({
    super.key,
    this.baseOverride,
    this.tokenOverride,
    this.clock,
    this.myWatchApi,
    this.channelsApi,
    this.gate,
    this.healthProvider,
  });

  /// Test overrides; default to the embedded client's own base/token.
  final String? baseOverride;
  final String? tokenOverride;

  /// Test clock for the rate row (fake-async pumps don't advance
  /// [DateTime.now]); defaults to the real clock.
  final DateTime Function()? clock;

  /// More test overrides.
  final MyWatchApi? myWatchApi;
  final ChannelsApi? channelsApi;
  final X0xCellularGate? gate;
  final Future<ClientHealth> Function()? healthProvider;

  @override
  State<DataScreen> createState() => _DataScreenState();
}

class _DataScreenState extends State<DataScreen> {
  // -- Usage counters (GET /stats, 5 s poll while visible). --
  DataUsageStats? _stats;
  bool _loaded = false;
  Timer? _pollTimer;
  DataUsageStats? _prev;
  DateTime? _prevAt;
  DateTime? _statsAt;

  // -- Built-in clients. --
  ClientHealth? _health;
  MyWatchStatus? _myWatch;
  ChannelsStatus? _channels;
  bool _busyMyWatch = false;
  bool _busyChannels = false;

  // -- Mobile-data policies. --
  StreamingNetworkPolicy _streaming = StreamingNetworkPolicy.ask;
  DownloadNetworkPolicy _downloads = DownloadNetworkPolicy.wifiOnly;
  bool _channelsOnCellular = true;
  bool _myWatchOnCellular = true;

  MyWatchApi get _myWatchApi =>
      widget.myWatchApi ??
      MyWatchApi(base: widget.baseOverride, token: widget.tokenOverride);
  ChannelsApi get _channelsApi =>
      widget.channelsApi ??
      ChannelsApi(base: widget.baseOverride, token: widget.tokenOverride);
  X0xCellularGate get _gate => widget.gate ?? X0xCellularGate.instance;

  @override
  void initState() {
    super.initState();
    // Paused-on-mobile-data flags can flip while the page is open.
    _gate.ensureLoaded().then((_) {
      if (mounted) setState(() {});
    });
    _gate.addListener(_onGateChanged);
    _loadPolicies();
    _tick();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) => _tick());
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

  DateTime _now() => widget.clock?.call() ?? DateTime.now();

  /// One poll fetches everything the page shows live: counters, the
  /// Autonomi connection, and the two agent states (all localhost
  /// calls, so a shared 5 s cadence is cheap).
  Future<void> _tick() async {
    await Future.wait([_loadStats(), _reloadClients()]);
  }

  Future<void> _loadStats() async {
    final stats = await EmbeddedClient.stats(
        baseOverride: widget.baseOverride,
        tokenOverride: widget.tokenOverride);
    if (!mounted) return;
    setState(() {
      if (stats != null) {
        _prev = _stats;
        _prevAt = _statsAt;
        _stats = stats;
        _statsAt = _now();
      }
      _loaded = true;
    });
  }

  Future<void> _reloadClients() async {
    ClientHealth? health;
    MyWatchStatus? myWatch;
    ChannelsStatus? channels;
    try {
      health = await (widget.healthProvider ?? EmbeddedClient.health)();
    } catch (_) {
      // Embedded client unreachable; the rows say "checking".
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
  }

  Future<void> _loadPolicies() async {
    final streaming = await AppSettings.streamingNetworkPolicy();
    final downloads = await AppSettings.downloadNetworkPolicy();
    final channels = await AppSettings.channelsOnCellular();
    final myWatch = await AppSettings.myWatchOnCellular();
    if (!mounted) return;
    setState(() {
      _streaming = streaming;
      _downloads = downloads;
      _channelsOnCellular = channels;
      _myWatchOnCellular = myWatch;
    });
  }

  // ---------------------------------------------------------------- usage

  Future<void> _confirmReset() async {
    final t = WiTokens.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: t.ink2,
        title: Text('Reset data usage?',
            style: TextStyle(color: t.bone, fontSize: 16)),
        content: Text(
          'All counters return to zero and a new period starts today. '
          'This only affects these statistics — nothing else changes.',
          style: TextStyle(color: t.boneDim, fontSize: 13.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel', style: TextStyle(color: t.ash)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final fresh = await EmbeddedClient.resetStats(
        baseOverride: widget.baseOverride,
        tokenOverride: widget.tokenOverride);
    if (!mounted) return;
    setState(() {
      if (fresh != null) {
        _stats = fresh;
        _statsAt = _now();
      }
      // A rate across the reset boundary would read negative — drop it.
      _prev = null;
      _prevAt = null;
    });
  }

  /// `↓ 240 KB/s · ↑ 12 KB/s` from the last two polls, or null while
  /// fewer than two polls have answered.
  String? get _rateLine {
    final prev = _prev, prevAt = _prevAt, cur = _stats, curAt = _statsAt;
    if (prev == null || prevAt == null || cur == null || curAt == null) {
      return null;
    }
    final secs = curAt.difference(prevAt).inMilliseconds / 1000.0;
    if (secs <= 0) return null;
    final down = (cur.total.rx - prev.total.rx).clamp(0, 1 << 62) / secs;
    final up = (cur.total.tx - prev.total.tx).clamp(0, 1 << 62) / secs;
    return '↓ ${formatBytes(down.round())}/s · ↑ ${formatBytes(up.round())}/s';
  }

  String _antFreshnessLine(int? staleSecs) {
    if (staleSecs == null) {
      return 'first update within ~5 minutes of connecting';
    }
    if (staleSecs < 90) return 'updated just now';
    return 'updated ${(staleSecs / 60).round()} min ago';
  }

  // ------------------------------------------------------------ auto-pause

  Future<void> _pickAutoPause() async {
    final t = WiTokens.of(context);
    final picked = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        backgroundColor: t.ink2,
        title: Text('Auto-pause when idle',
            style: TextStyle(color: t.bone, fontSize: 16)),
        children: [
          RadioGroup<int>(
            groupValue: NetworkPause.instance.idleMinutes,
            onChanged: (v) => Navigator.of(context).pop(v),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final mins in kAutoPauseOptionsMinutes)
                  RadioListTile<int>(
                    value: mins,
                    activeColor: t.accent,
                    title: Text(
                      mins <= 0
                          ? 'Off'
                          : 'After ${idleMinutesLabel(mins)}'
                              '${mins == 30 ? '  ·  default' : ''}',
                      style: TextStyle(color: t.bone, fontSize: 14),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked == null) return;
    await NetworkPause.instance.setIdleMinutes(picked);
  }

  // ---------------------------------------------------------------- clients

  /// The pill position a client's current state reads as: switched off
  /// by hand → Off; otherwise the mobile-data pref decides (an agent
  /// the gate paused on cellular is still in Wi-Fi mode — it resumes
  /// by itself).
  ClientNetMode _modeFor(
      {required bool enabled,
      required bool cellularAllowed,
      required bool gatePaused}) {
    if (!enabled && !gatePaused) return ClientNetMode.off;
    return cellularAllowed ? ClientNetMode.wifiAndMobile : ClientNetMode.wifi;
  }

  Future<void> _setChannelsMode(ClientNetMode mode) async {
    setState(() => _busyChannels = true);
    try {
      switch (mode) {
        case ClientNetMode.off:
          // An explicit Off wins over the mobile-data gate: forget any
          // pause it holds so Wi-Fi's return won't flip this back on.
          await _gate.noteManualChange(X0xAgent.channels);
          await _channelsApi.setEnabled(false);
        case ClientNetMode.wifi:
        case ClientNetMode.wifiAndMobile:
          final cellular = mode == ClientNetMode.wifiAndMobile;
          await AppSettings.setChannelsOnCellular(cellular);
          if (mounted) setState(() => _channelsOnCellular = cellular);
          if (!(_channels?.enabled ?? true) &&
              !_gate.isPaused(X0xAgent.channels)) {
            await _gate.noteManualChange(X0xAgent.channels);
            await _channelsApi.setEnabled(true);
          }
          // On cellular right now, the agent pauses or resumes without
          // waiting for a transport change.
          await _gate.onPolicyChanged();
      }
    } catch (e) {
      wiMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text('Could not change the setting: $e')),
      );
    }
    if (mounted) setState(() => _busyChannels = false);
    await _reloadClients();
  }

  Future<void> _setMyWatchMode(ClientNetMode mode) async {
    setState(() => _busyMyWatch = true);
    try {
      switch (mode) {
        case ClientNetMode.off:
          await _gate.noteManualChange(X0xAgent.myWatch);
          await _myWatchApi.setEnabled(false);
        case ClientNetMode.wifi:
        case ClientNetMode.wifiAndMobile:
          final cellular = mode == ClientNetMode.wifiAndMobile;
          await AppSettings.setMyWatchOnCellular(cellular);
          if (mounted) setState(() => _myWatchOnCellular = cellular);
          if (!(_myWatch?.enabled ?? true) &&
              !_gate.isPaused(X0xAgent.myWatch)) {
            await _gate.noteManualChange(X0xAgent.myWatch);
            await _myWatchApi.setEnabled(true);
          }
          await _gate.onPolicyChanged();
      }
    } catch (e) {
      wiMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text('Could not change the setting: $e')),
      );
    }
    if (mounted) setState(() => _busyMyWatch = false);
    await _reloadClients();
    // Refresh the sync service's status too, so the drawer row and the
    // My W@tch page reflect the change without waiting a cycle.
    unawaited(MyWatchSync.instance.syncNow().then((_) {}, onError: (_) {}));
  }

  /// One line of plain words under each client: what it is doing now.
  String _myWatchStateLine(MyWatchStatus? s) {
    if (s == null) return 'Checking…';
    if (!s.supported) return 'Not available on this platform';
    if (!s.enabled) {
      return _gate.isPaused(X0xAgent.myWatch)
          ? 'Paused on mobile data — resumes on Wi-Fi'
          : 'Off — nothing syncs between devices';
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
          : 'Off — channels get no updates; your own publishes '
              'wait here until it is back on';
    }
    final count = s.subs.length + (s.own != null ? 1 : 0);
    if (count == 0) return 'On — no channels yet';
    return switch (s.state) {
      'ready' => 'On — connected to the channel network',
      'starting' => 'On — connecting…',
      _ => 'On',
    };
  }

  // ------------------------------------------------------------ mobile data

  Future<void> _pickStreaming() async {
    final t = WiTokens.of(context);
    final picked = await showDialog<StreamingNetworkPolicy>(
      context: context,
      builder: (context) => SimpleDialog(
        backgroundColor: t.ink2,
        title: Text('Streaming on mobile data',
            style: TextStyle(color: t.bone, fontSize: 16)),
        children: [
          RadioGroup<StreamingNetworkPolicy>(
            groupValue: _streaming,
            onChanged: (v) => Navigator.of(context).pop(v),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final option in StreamingNetworkPolicy.values)
                  RadioListTile<StreamingNetworkPolicy>(
                    value: option,
                    activeColor: t.accent,
                    title: Text(
                      streamingPolicyLabel(option),
                      style: TextStyle(color: t.bone, fontSize: 14),
                    ),
                    subtitle: option == StreamingNetworkPolicy.ask
                        ? Text('Asks once per app session',
                            style: TextStyle(color: t.ash, fontSize: 11.5))
                        : null,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked == null) return;
    await AppSettings.setStreamingNetworkPolicy(picked);
    if (mounted) setState(() => _streaming = picked);
  }

  Future<void> _pickDownloads() async {
    final t = WiTokens.of(context);
    final picked = await showDialog<DownloadNetworkPolicy>(
      context: context,
      builder: (context) => SimpleDialog(
        backgroundColor: t.ink2,
        title: Text('Download over',
            style: TextStyle(color: t.bone, fontSize: 16)),
        children: [
          RadioGroup<DownloadNetworkPolicy>(
            groupValue: _downloads,
            onChanged: (v) => Navigator.of(context).pop(v),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final option in DownloadNetworkPolicy.values)
                  RadioListTile<DownloadNetworkPolicy>(
                    value: option,
                    activeColor: t.accent,
                    title: Text(
                      downloadPolicyLabel(option),
                      style: TextStyle(color: t.bone, fontSize: 14),
                    ),
                    subtitle: option == DownloadNetworkPolicy.wifiOnly
                        ? Text('On mobile data the queue waits for Wi-Fi',
                            style: TextStyle(color: t.ash, fontSize: 11.5))
                        : null,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked == null) return;
    await AppSettings.setDownloadNetworkPolicy(picked);
    // Apply immediately: a queue waiting for Wi-Fi starts right away
    // when mobile data is allowed now (and vice versa).
    DownloadManager.instance.onNetworkPolicyChanged();
    if (mounted) setState(() => _downloads = picked);
  }

  // ---------------------------------------------------------------- widgets

  Widget _sectionHeader(WiTokens t, String label) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
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

  Widget _totalCard(WiTokens t, DataUsageStats stats) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
        decoration: BoxDecoration(
          color: t.ink2,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          children: [
            Text('Total data usage',
                style: TextStyle(color: t.ash, fontSize: 12.5)),
            const SizedBox(height: 6),
            Text(
              formatBytes(stats.total.total),
              style: TextStyle(
                color: t.bone,
                fontSize: 34,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('↑ ${formatBytes(stats.total.tx)}',
                    style: TextStyle(color: t.ash, fontSize: 13)),
                const SizedBox(width: 16),
                Text('↓ ${formatBytes(stats.total.rx)}',
                    style: TextStyle(color: t.ash, fontSize: 13)),
              ],
            ),
          ],
        ),
      );

  Widget _componentTile(
    WiTokens t, {
    required IconData icon,
    Color? iconColor,
    required String name,
    required UsageBytes usage,
    bool off = false,
    List<String> extraLines = const [],
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: iconColor ?? t.accent, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(name,
                          style: TextStyle(color: t.bone, fontSize: 15)),
                      if (off)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Text('Off',
                              style:
                                  TextStyle(color: t.ash, fontSize: 12)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text('↑ ${formatBytes(usage.tx)}',
                          style: TextStyle(color: t.ash, fontSize: 12.5)),
                      const SizedBox(width: 14),
                      Text('↓ ${formatBytes(usage.rx)}',
                          style: TextStyle(color: t.ash, fontSize: 12.5)),
                    ],
                  ),
                  for (final line in extraLines)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(line,
                          style: TextStyle(color: t.ash, fontSize: 11.5)),
                    ),
                ],
              ),
            ),
            Text(
              formatBytes(usage.total),
              style: TextStyle(color: t.boneDim, fontSize: 14),
            ),
          ],
        ),
      );

  /// The compact three-segment pill: `Off | Wi-Fi | Wi-Fi + mobile`.
  Widget _modePill({
    required ClientNetMode mode,
    required bool enabled,
    required ValueChanged<ClientNetMode> onChanged,
  }) =>
      SegmentedButton<ClientNetMode>(
        segments: const [
          ButtonSegment(value: ClientNetMode.off, label: Text('Off')),
          ButtonSegment(value: ClientNetMode.wifi, label: Text('Wi-Fi')),
          ButtonSegment(
              value: ClientNetMode.wifiAndMobile,
              label: Text('Wi-Fi + mobile')),
        ],
        selected: {mode},
        showSelectedIcon: false,
        onSelectionChanged: enabled ? (s) => onChanged(s.first) : null,
        style: const ButtonStyle(
          visualDensity: VisualDensity.compact,
          textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12)),
          padding: WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 10)),
        ),
      );

  /// One client: icon + name + state line, with its pill underneath.
  Widget _clientBlock(
    WiTokens t, {
    required IconData icon,
    Color? iconColor,
    required String name,
    required String stateLine,
    required ClientNetMode mode,
    required bool pillEnabled,
    required ValueChanged<ClientNetMode> onChanged,
  }) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: iconColor ?? t.accent, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          style: TextStyle(color: t.bone, fontSize: 15)),
                      const SizedBox(height: 2),
                      Text(stateLine,
                          style: TextStyle(color: t.ash, fontSize: 12)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 34),
              child: _modePill(
                  mode: mode, enabled: pillEnabled, onChanged: onChanged),
            ),
          ],
        ),
      );

  List<Widget> _usageBlock(WiTokens t) {
    final stats = _stats;
    if (stats == null) {
      return [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            !_loaded
                ? 'Loading data usage…'
                : 'Data usage is not available — the built-in client is '
                    'not running.',
            style: TextStyle(color: t.ash, fontSize: 13.5),
          ),
        ),
      ];
    }
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: _totalCard(t, stats),
      ),
      const SizedBox(height: 8),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          children: [
            _componentTile(
              t,
              icon: Icons.cloud_outlined,
              name: 'Autonomi client',
              usage: stats.ant,
              extraLines: [
                'of which media: ${formatBytes(stats.antMediaRx)}',
                _antFreshnessLine(stats.antStaleSecs),
              ],
            ),
            _componentTile(
              t,
              icon: Icons.devices_outlined,
              name: 'My W@tch',
              usage: stats.myWatch,
              off: _myWatch?.enabled == false,
            ),
            _componentTile(
              t,
              icon: Icons.podcasts,
              iconColor: WiTokens.channelAmber,
              name: 'Channels',
              usage: stats.channels,
              off: _channels?.enabled == false,
            ),
          ],
        ),
      ),
      if (_rateLine != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 16, 0),
          child: Row(
            children: [
              Icon(Icons.speed_outlined, color: t.ash, size: 18),
              const SizedBox(width: 8),
              Text('Current rate: $_rateLine',
                  style: TextStyle(color: t.boneDim, fontSize: 13)),
            ],
          ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 16, 0),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Since ${sinceDateLabel(stats.periodStart)}',
                style: TextStyle(color: t.ash, fontSize: 12.5),
              ),
            ),
            TextButton(
              onPressed: _confirmReset,
              child: const Text('Reset'),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 16, 8),
        child: Text(
          'Measured inside the app: the My W@tch and Channels rows '
          'count raw connection bytes, the Autonomi row counts '
          'protocol data. System-level meters read a few percent '
          'higher.',
          style: TextStyle(color: t.ash, fontSize: 11.5),
        ),
      ),
    ];
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
        title: Text('Data', style: TextStyle(color: t.bone, fontSize: 18)),
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                ..._usageBlock(t),
                // Auto-pause directly under the counters — the rule
                // that most changes what they read.
                ListenableBuilder(
                  listenable: NetworkPause.instance,
                  builder: (context, _) => ListTile(
                    leading: Icon(Icons.timer_outlined, color: t.accent),
                    title: Text('Auto-pause when idle',
                        style: TextStyle(color: t.bone, fontSize: 15)),
                    subtitle: Text(
                      NetworkPause.instance.idleMinutes <= 0
                          ? 'Off — stays connected while the app is open'
                          : 'After ${idleMinutesLabel(NetworkPause.instance.idleMinutes)} '
                              'with nothing playing, downloading or '
                              'uploading. Playing something resumes '
                              'automatically.',
                      style: TextStyle(color: t.ash, fontSize: 12),
                    ),
                    trailing: Icon(Icons.chevron_right, color: t.ash),
                    onTap: _pickAutoPause,
                  ),
                ),
                _sectionHeader(t, 'BUILT-IN CLIENTS'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Text(
                    'Two networks are built into the app. The Autonomi '
                    'client streams and downloads your media. The x0x '
                    'client is a separate peer-to-peer gossip network '
                    'that Channels and My W@tch talk over; each has its '
                    'own pill — Off stops the feature entirely, Wi-Fi '
                    'keeps it off mobile data.',
                    style: TextStyle(fontSize: 12.5, color: t.boneDim),
                  ),
                ),
                ListTile(
                  leading: Icon(Icons.cloud_outlined, color: t.accent),
                  title: Text('Connection',
                      style: TextStyle(color: t.bone, fontSize: 15)),
                  subtitle: Text(
                    _health?.label ?? 'Checking…',
                    style: TextStyle(color: t.ash, fontSize: 12),
                  ),
                  trailing: Icon(Icons.refresh, color: t.ash, size: 18),
                  onTap: _reloadClients,
                ),
                // Channels above My W@tch — the CONTENT section's order.
                _clientBlock(
                  t,
                  icon: Icons.podcasts,
                  iconColor: WiTokens.channelAmber,
                  name: 'Channels',
                  stateLine: _channelsStateLine(channels),
                  mode: _modeFor(
                    enabled: channels?.enabled ?? true,
                    cellularAllowed: _channelsOnCellular,
                    gatePaused: _gate.isPaused(X0xAgent.channels),
                  ),
                  pillEnabled: !_busyChannels &&
                      channels != null &&
                      channels.supported,
                  onChanged: _setChannelsMode,
                ),
                _clientBlock(
                  t,
                  icon: Icons.devices_outlined,
                  name: 'My W@tch',
                  stateLine: _myWatchStateLine(myWatch),
                  mode: _modeFor(
                    enabled: myWatch?.enabled ?? true,
                    cellularAllowed: _myWatchOnCellular,
                    gatePaused: _gate.isPaused(X0xAgent.myWatch),
                  ),
                  pillEnabled:
                      !_busyMyWatch && myWatch != null && myWatch.supported,
                  onChanged: _setMyWatchMode,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(
                    'While a client is Off the feature simply pauses: '
                    'linked devices stop hearing from this one, '
                    'subscribed channels stop updating, and nothing you '
                    'do here is lost. On Wi-Fi it pauses only while the '
                    'device is on mobile data and picks up where it '
                    'left off. Joining a link, creating a channel or '
                    'subscribing turns the feature back on '
                    'automatically.',
                    style: TextStyle(fontSize: 11.5, color: t.ash),
                  ),
                ),
                _sectionHeader(t, 'MOBILE DATA'),
                ListTile(
                  leading:
                      Icon(Icons.play_circle_outline, color: t.accent),
                  title: Text('Streaming',
                      style: TextStyle(color: t.bone, fontSize: 15)),
                  subtitle: Text(
                    streamingPolicyLabel(_streaming),
                    style: TextStyle(color: t.ash, fontSize: 12),
                  ),
                  trailing: Icon(Icons.chevron_right, color: t.ash),
                  onTap: _pickStreaming,
                ),
                ListTile(
                  leading: Icon(Icons.download_outlined, color: t.accent),
                  title: Text('Downloads',
                      style: TextStyle(color: t.bone, fontSize: 15)),
                  subtitle: Text(
                    downloadPolicyLabel(_downloads),
                    style: TextStyle(color: t.ash, fontSize: 12),
                  ),
                  trailing: Icon(Icons.chevron_right, color: t.ash),
                  onTap: _pickDownloads,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: Text(
                    'Streaming and downloads move whole files — the '
                    'heavy traffic. These choices only apply while the '
                    'device is on a cellular connection; on Wi-Fi and '
                    'wired networks everything runs freely.',
                    style: TextStyle(fontSize: 11.5, color: t.ash),
                  ),
                ),
              ],
            ),
    );
  }
}

/// Option wording shared by the tiles and their pickers.
String streamingPolicyLabel(StreamingNetworkPolicy policy) =>
    switch (policy) {
      StreamingNetworkPolicy.ask => 'Ask first',
      StreamingNetworkPolicy.allow => 'Allowed',
      StreamingNetworkPolicy.wifiOnly => 'Wi-Fi only',
    };

String downloadPolicyLabel(DownloadNetworkPolicy policy) =>
    switch (policy) {
      DownloadNetworkPolicy.wifiOnly => 'Wi-Fi only',
      DownloadNetworkPolicy.any => 'Wi-Fi + mobile data',
    };

/// `4 Sep 2026` — the period-start caption (no intl dependency).
String sinceDateLabel(DateTime d) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${d.day} ${months[d.month - 1]} ${d.year}';
}
