import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_list.dart';
import '../services/channels_api.dart';
import '../services/embedded_client.dart';
import '../services/my_watch_api.dart';
import '../theme/tokens.dart';

/// Settings → Network → Data usage: how much data the app has moved
/// since the period start, total and per component (Autonomi client /
/// My W@tch / Channels), with a current-rate row derived from
/// consecutive polls and a period reset.
///
/// Numbers come from `GET /stats` (native datausage.rs), polled every
/// 5 s while the screen is visible. The Autonomi row folds a 5-minute
/// traffic summary, so it carries an "updated N ago" caption; the
/// media split and the x0x rows are live.
class DataUsageScreen extends StatefulWidget {
  const DataUsageScreen(
      {super.key, this.baseOverride, this.tokenOverride, this.clock});

  /// Test overrides; default to the embedded client's own base/token.
  final String? baseOverride;
  final String? tokenOverride;

  /// Test clock for the rate row (fake-async pumps don't advance
  /// [DateTime.now]); defaults to the real clock.
  final DateTime Function()? clock;

  @override
  State<DataUsageScreen> createState() => _DataUsageScreenState();
}

class _DataUsageScreenState extends State<DataUsageScreen> {
  DataUsageStats? _stats;
  bool _loaded = false;
  Timer? _pollTimer;

  // Previous poll, for the current-rate row.
  DataUsageStats? _prev;
  DateTime? _prevAt;
  DateTime? _statsAt;

  /// Whether the two x0x agents are switched on (null while unknown —
  /// then the rows just show their totals without an "Off" tag).
  bool? _myWatchOn;
  bool? _channelsOn;

  @override
  void initState() {
    super.initState();
    _load();
    _loadAgentStates();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) => _load());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  DateTime _now() => widget.clock?.call() ?? DateTime.now();

  Future<void> _load() async {
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

  Future<void> _loadAgentStates() async {
    // Best-effort: an unreachable client just leaves the tags off.
    bool? myWatchOn;
    bool? channelsOn;
    try {
      myWatchOn = (await MyWatchApi(
              base: widget.baseOverride, token: widget.tokenOverride)
          .status())
          .enabled;
    } catch (_) {}
    try {
      channelsOn = (await ChannelsApi(
              base: widget.baseOverride, token: widget.tokenOverride)
          .status())
          .enabled;
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _myWatchOn = myWatchOn;
      _channelsOn = channelsOn;
    });
  }

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

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final stats = _stats;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title:
            Text('Data usage', style: TextStyle(color: t.bone, fontSize: 18)),
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : stats == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Data usage is not available — the built-in client '
                      'is not running.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: t.ash, fontSize: 13.5),
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  children: [
                    _totalCard(t, stats),
                    const SizedBox(height: 16),
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
                      off: _myWatchOn == false,
                    ),
                    _componentTile(
                      t,
                      icon: Icons.podcasts,
                      iconColor: WiTokens.channelAmber,
                      name: 'Channels',
                      usage: stats.channels,
                      off: _channelsOn == false,
                    ),
                    const SizedBox(height: 8),
                    if (_rateLine != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 6),
                        child: Row(
                          children: [
                            Icon(Icons.speed_outlined,
                                color: t.ash, size: 18),
                            const SizedBox(width: 8),
                            Text('Current rate: $_rateLine',
                                style: TextStyle(
                                    color: t.boneDim, fontSize: 13)),
                          ],
                        ),
                      ),
                    const SizedBox(height: 4),
                    Row(
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
                    const SizedBox(height: 8),
                    Text(
                      'Measured inside the app: the My W@tch and Channels '
                      'rows count raw connection bytes, the Autonomi row '
                      'counts protocol data. System-level meters read a '
                      'few percent higher.',
                      style: TextStyle(color: t.ash, fontSize: 11.5),
                    ),
                  ],
                ),
    );
  }

  String _antFreshnessLine(int? staleSecs) {
    if (staleSecs == null) {
      return 'first update within ~5 minutes of connecting';
    }
    if (staleSecs < 90) return 'updated just now';
    return 'updated ${(staleSecs / 60).round()} min ago';
  }

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
}

/// `4 Sep 2026` — the period-start caption (no intl dependency).
String sinceDateLabel(DateTime d) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${d.day} ${months[d.month - 1]} ${d.year}';
}
