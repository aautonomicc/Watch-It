import 'package:flutter/material.dart';

import '../services/app_settings.dart';
import '../services/download_manager.dart';
import '../services/x0x_cellular.dart';
import '../theme/tokens.dart';

/// Settings → Network → Mobile data: one place for everything that may
/// use mobile data — streaming, downloads, and the two x0x features
/// (Channels and My W@tch). On Wi-Fi or wired connections nothing here
/// applies; only a cellular transport is ever gated, so desktop
/// machines are unaffected.
class MobileDataScreen extends StatefulWidget {
  const MobileDataScreen({super.key, this.gate});

  /// Test override; defaults to [X0xCellularGate.instance].
  final X0xCellularGate? gate;

  @override
  State<MobileDataScreen> createState() => _MobileDataScreenState();
}

class _MobileDataScreenState extends State<MobileDataScreen> {
  StreamingNetworkPolicy _streaming = StreamingNetworkPolicy.ask;
  DownloadNetworkPolicy _downloads = DownloadNetworkPolicy.wifiOnly;
  bool _channelsOnCellular = true;
  bool _myWatchOnCellular = true;
  bool _loaded = false;

  X0xCellularGate get _gate => widget.gate ?? X0xCellularGate.instance;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
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
      _loaded = true;
    });
  }

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

  Future<void> _setChannelsOnCellular(bool on) async {
    await AppSettings.setChannelsOnCellular(on);
    if (mounted) setState(() => _channelsOnCellular = on);
    // Apply immediately: on cellular right now, the agent pauses or
    // resumes without waiting for a transport change.
    await _gate.onPolicyChanged();
  }

  Future<void> _setMyWatchOnCellular(bool on) async {
    await AppSettings.setMyWatchOnCellular(on);
    if (mounted) setState(() => _myWatchOnCellular = on);
    await _gate.onPolicyChanged();
  }

  String _x0xSubtitle(bool allowed) => allowed
      ? 'May use mobile data'
      : 'Wi-Fi only — pauses on mobile data, resumes on Wi-Fi';

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Text('Mobile data',
            style: TextStyle(color: t.bone, fontSize: 18)),
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                  child: Text(
                    'What may use mobile data. These choices only apply '
                    'while the device is on a cellular connection — on '
                    'Wi-Fi and wired networks everything runs freely.',
                    style: TextStyle(fontSize: 12.5, color: t.boneDim),
                  ),
                ),
                // The two heavy consumers first (a stream or download
                // moves the whole file), then the two background ones.
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
                // Channels above My W@tch — the CONTENT section's order.
                SwitchListTile(
                  secondary: const Icon(Icons.podcasts,
                      color: WiTokens.channelAmber),
                  title: Text('Channels',
                      style: TextStyle(color: t.bone, fontSize: 15)),
                  subtitle: Text(
                    _x0xSubtitle(_channelsOnCellular),
                    style: TextStyle(color: t.ash, fontSize: 12),
                  ),
                  value: _channelsOnCellular,
                  onChanged: _setChannelsOnCellular,
                ),
                SwitchListTile(
                  secondary: Icon(Icons.devices_outlined, color: t.accent),
                  title: Text('My W@tch',
                      style: TextStyle(color: t.bone, fontSize: 15)),
                  subtitle: Text(
                    _x0xSubtitle(_myWatchOnCellular),
                    style: TextStyle(color: t.ash, fontSize: 12),
                  ),
                  value: _myWatchOnCellular,
                  onChanged: _setMyWatchOnCellular,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Text(
                    'Streaming and downloads move whole files — the '
                    'heavy traffic. Channels and My W@tch use a smaller '
                    'but constant background trickle whenever they are '
                    'on. Set to Wi-Fi only, a feature simply pauses '
                    'while you are on mobile data and picks up where it '
                    'left off on Wi-Fi — nothing is lost. The built-in '
                    'client keeps a few idle peer connections on any '
                    'network.',
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
