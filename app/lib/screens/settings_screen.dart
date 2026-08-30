import 'dart:async';
import 'dart:io' show exit;

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/media_list.dart';
import '../services/app_settings.dart';
import '../services/bundle.dart' show kTmdbAttributionNotice;
import '../services/channels_api.dart';
import '../services/download_manager.dart';
import '../services/library_store.dart';
import '../services/embedded_client.dart';
import '../services/exit_info.dart';
import '../services/metadata_service.dart';
import '../services/my_watch_api.dart';
import '../services/storage_usage.dart';
import '../services/update_check.dart';
import '../theme/tokens.dart';
import '../widgets/brand_mark.dart';
import 'channels_screen.dart';
import 'downloads_screen.dart';
import 'exit_info_screen.dart';
import 'media_lists_screen.dart';
import 'my_watch_screen.dart';
import 'publish_screen.dart' show PublishScreen, isDesktopPlatform;
import 'terms_screen.dart';
import 'wallet_screen.dart';
import 'x0x_client_screen.dart';

/// Settings: content, network, metadata, appearance, and about sections.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  List<MediaList>? _lists;
  ClientHealth? _health;
  String? _version;
  Timer? _healthTimer;
  int _bufferSizeMb = AppSettings.defaultBufferSizeMb;
  TmdbKeySource _tmdbKeySource = TmdbKeySource.none;
  DownloadNetworkPolicy _downloadNetwork = DownloadNetworkPolicy.wifiOnly;
  StreamingNetworkPolicy _streamingNetwork = StreamingNetworkPolicy.ask;
  int? _dataSizeBytes;
  bool _dataSizeKnown = false;
  bool _updateCheckEnabled = true;

  /// The two x0x switches, for the Built-in x0x client tile's subtitle
  /// (null until the statuses have answered).
  bool? _myWatchOn;
  bool? _channelsOn;

  @override
  void initState() {
    super.initState();
    _reload();
    _loadVersion();
    UpdateCheck.enabled().then((v) {
      if (mounted) setState(() => _updateCheckEnabled = v);
    });
    _loadDataSize();
    _scheduleHealthPoll();
    DownloadManager.instance.ensureLoaded();
  }

  @override
  void dispose() {
    _healthTimer?.cancel();
    super.dispose();
  }

  /// Keep the status tile live: fast poll while connecting, relaxed once
  /// ready (localhost call, so polling is cheap).
  void _scheduleHealthPoll() {
    _healthTimer = Timer(
      Duration(seconds: _health?.state == 'ready' ? 15 : 3),
      () async {
        await _refreshHealth();
        if (mounted && _health?.state != 'unavailable') _scheduleHealthPoll();
      },
    );
  }

  Future<void> _reload() async {
    final lists = await LibraryStore.load();
    final health = await EmbeddedClient.health();
    final bufferSizeMb = await AppSettings.bufferSizeMb();
    final tmdbKeySource = await AppSettings.tmdbKeySource();
    final downloadNetwork = await AppSettings.downloadNetworkPolicy();
    final streamingNetwork = await AppSettings.streamingNetworkPolicy();
    // The x0x switches, for the tile subtitle. Best-effort: an
    // unreachable embedded client just leaves the subtitle generic.
    bool? myWatchOn;
    bool? channelsOn;
    try {
      myWatchOn = (await MyWatchApi().status()).enabled;
    } catch (_) {}
    try {
      channelsOn = (await ChannelsApi().status()).enabled;
    } catch (_) {}
    if (mounted) {
      setState(() {
        _lists = lists;
        _health = health;
        _bufferSizeMb = bufferSizeMb;
        _tmdbKeySource = tmdbKeySource;
        _downloadNetwork = downloadNetwork;
        _streamingNetwork = streamingNetwork;
        _myWatchOn = myWatchOn;
        _channelsOn = channelsOn;
      });
    }
  }

  /// "Channels on · My W@tch off" once the switches are known (Channels
  /// first — the CONTENT section's order); a generic description before
  /// that (or when the client is down).
  String get _x0xSubtitle {
    final mw = _myWatchOn;
    final ch = _channelsOn;
    if (mw == null || ch == null) {
      return 'The peer-to-peer network behind Channels and My W@tch';
    }
    return 'Channels ${ch ? 'on' : 'off'} · '
        'My W@tch ${mw ? 'on' : 'off'}';
  }

  Future<void> _openX0xClient() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const X0xClientScreen()),
    );
    await _reload();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() => _version = '${info.version} (build ${info.buildNumber})');
      }
    } catch (_) {
      // Platform channel unavailable (tests, bare desktop builds).
    }
  }

  Future<void> _refreshHealth() async {
    final health = await EmbeddedClient.health();
    if (mounted) setState(() => _health = health);
  }

  Future<void> _pickBufferSize() async {
    final t = WiTokens.of(context);
    final picked = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        backgroundColor: t.ink2,
        title: Text('Buffer size',
            style: TextStyle(color: t.bone, fontSize: 16)),
        children: [
          RadioGroup<int>(
            groupValue: _bufferSizeMb,
            onChanged: (v) => Navigator.of(context).pop(v),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final mb in AppSettings.bufferSizeOptionsMb)
                  RadioListTile<int>(
                    value: mb,
                    activeColor: t.accent,
                    title: Text(
                      '$mb MB'
                      '${mb == AppSettings.defaultBufferSizeMb ? '  ·  default' : ''}',
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
    await AppSettings.setBufferSizeMb(picked);
    if (mounted) setState(() => _bufferSizeMb = picked);
  }

  /// The key in use is never prefilled or displayed — only where it came
  /// from — so the bundled key can't be copied out of the app.
  Future<void> _editTmdbApiKey() async {
    final entered = await promptForText(
      context,
      title: 'TMDB API key',
      hint: _tmdbKeySource == TmdbKeySource.user
          ? 'New key (leave empty to remove yours)'
          : 'API key or read access token',
      note: 'Get a free key at themoviedb.org/settings/api '
          '(a TMDB account is free too).',
    );
    if (entered == null) return;
    // An empty save only means something when a user key exists to remove.
    if (entered.trim().isEmpty && _tmdbKeySource != TmdbKeySource.user) {
      return;
    }
    await AppSettings.setTmdbApiKey(entered);
    // Re-run matching with the new credential (also clears cached misses).
    await MetadataService.instance.reset();
    final source = await AppSettings.tmdbKeySource();
    if (mounted) setState(() => _tmdbKeySource = source);
  }

  Future<void> _loadDataSize() async {
    final size = await appDataSizeBytes();
    if (mounted) {
      setState(() {
        _dataSizeBytes = size;
        _dataSizeKnown = true;
      });
    }
  }

  /// Factory reset behind a two-step confirmation: the first dialog says
  /// what gets deleted, the second spells out that lists are unrecoverable
  /// unless exported. The app closes afterwards — open database handles
  /// (ours and the embedded client's) still point at the deleted files.
  Future<void> _clearAllData() async {
    final t = WiTokens.of(context);
    final first = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: t.ink2,
        title: Text('Clear all data?',
            style: TextStyle(color: t.bone, fontSize: 16)),
        content: Text(
          'This resets W@tch to factory defaults, deleting everything '
          'stored on this device:\n\n'
          '•  all media lists and their entries\n'
          '•  all settings, including a TMDB key you entered\n'
          '•  cached artwork and descriptions\n'
          '•  imported data maps and network state\n\n'
          'Media on Autonomi is not affected — only this device\'s data.',
          style: TextStyle(color: t.boneDim, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel', style: TextStyle(color: t.ash)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Continue', style: TextStyle(color: t.rust)),
          ),
        ],
      ),
    );
    if (first != true || !mounted) return;
    final second = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: t.ink2,
        title: Text('Are you sure?',
            style: TextStyle(color: t.rust, fontSize: 16)),
        content: Text(
          'Your media lists exist only on this device — they are not '
          'stored on the network. Unless you exported them to a file, '
          'there is no way to get them back after this.\n\n'
          'W@tch will close when the reset finishes; open it again to '
          'start fresh.',
          style: TextStyle(color: t.boneDim, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Keep my data', style: TextStyle(color: t.accent)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child:
                Text('Delete everything', style: TextStyle(color: t.rust)),
          ),
        ],
      ),
    );
    if (second != true) return;
    await factoryReset();
    exit(0);
  }

  Future<void> _openMediaLists() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const MediaListsScreen()),
    );
    await _reload();
  }

  /// Colour-scheme picker: dark (the app's original look, still the
  /// default), light, or follow the OS. Applies instantly app-wide.
  Future<void> _pickThemeMode() async {
    final t = WiTokens.of(context);
    final picked = await showDialog<ThemeMode>(
      context: context,
      builder: (context) => SimpleDialog(
        backgroundColor: t.ink2,
        title: Text('Colour scheme',
            style: TextStyle(color: t.bone, fontSize: 16)),
        children: [
          RadioGroup<ThemeMode>(
            groupValue: wiThemeMode.value,
            onChanged: (v) => Navigator.of(context).pop(v),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final mode in const [
                  ThemeMode.dark,
                  ThemeMode.light,
                  ThemeMode.system,
                ])
                  RadioListTile<ThemeMode>(
                    value: mode,
                    activeColor: t.accent,
                    title: Text(
                      _themeModeLabel(mode),
                      style: TextStyle(color: t.bone, fontSize: 14),
                    ),
                    subtitle: mode == ThemeMode.system
                        ? Text('Follows the device setting',
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
    await AppSettings.setThemeMode(picked);
    wiThemeMode.value = picked;
    if (mounted) setState(() {});
  }

  static String _themeModeLabel(ThemeMode mode) => switch (mode) {
        ThemeMode.dark => 'Dark  ·  default',
        ThemeMode.light => 'Light',
        ThemeMode.system => 'System default',
      };

  Future<void> _pickDownloadNetwork() async {
    final t = WiTokens.of(context);
    final picked = await showDialog<DownloadNetworkPolicy>(
      context: context,
      builder: (context) => SimpleDialog(
        backgroundColor: t.ink2,
        title: Text('Download over',
            style: TextStyle(color: t.bone, fontSize: 16)),
        children: [
          RadioGroup<DownloadNetworkPolicy>(
            groupValue: _downloadNetwork,
            onChanged: (v) => Navigator.of(context).pop(v),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final option in DownloadNetworkPolicy.values)
                  RadioListTile<DownloadNetworkPolicy>(
                    value: option,
                    activeColor: t.accent,
                    title: Text(
                      switch (option) {
                        DownloadNetworkPolicy.wifiOnly => 'Wi-Fi only',
                        DownloadNetworkPolicy.any => 'Wi-Fi + mobile data',
                      },
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
    if (mounted) setState(() => _downloadNetwork = picked);
  }

  Future<void> _pickStreamingNetwork() async {
    final t = WiTokens.of(context);
    final picked = await showDialog<StreamingNetworkPolicy>(
      context: context,
      builder: (context) => SimpleDialog(
        backgroundColor: t.ink2,
        title: Text('Streaming on mobile data',
            style: TextStyle(color: t.bone, fontSize: 16)),
        children: [
          RadioGroup<StreamingNetworkPolicy>(
            groupValue: _streamingNetwork,
            onChanged: (v) => Navigator.of(context).pop(v),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final option in StreamingNetworkPolicy.values)
                  RadioListTile<StreamingNetworkPolicy>(
                    value: option,
                    activeColor: t.accent,
                    title: Text(
                      switch (option) {
                        StreamingNetworkPolicy.ask => 'Ask first',
                        StreamingNetworkPolicy.allow => 'Allowed',
                        StreamingNetworkPolicy.wifiOnly => 'Wi-Fi only',
                      },
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
    if (mounted) setState(() => _streamingNetwork = picked);
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final lists = _lists;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Text('Settings', style: TextStyle(color: t.bone, fontSize: 18)),
      ),
      body: lists == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                // Renamed from LIBRARY (2026-08-30): the section covers
                // everything your content does — channels, device sync,
                // your media, uploads, and downloads.
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                  child: Text(
                    'CONTENT',
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w700,
                      color: t.ash,
                    ),
                  ),
                ),
                // Channels — the PUBLIC space, amber; leads the section
                // (2026-08-29), above the private tiles.
                ListTile(
                  leading:
                      const Icon(Icons.podcasts, color: WiTokens.channelAmber),
                  title: Text('Channels',
                      style: TextStyle(color: t.bone, fontSize: 15)),
                  subtitle: Text(
                    'Public · anyone with the code',
                    style: TextStyle(color: t.ash, fontSize: 12),
                  ),
                  trailing: Icon(Icons.chevron_right, color: t.ash),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ChannelsScreen()),
                  ),
                ),
                // My W@tch directly under Channels (2026-08-29): the two
                // sharing surfaces sit together — public above, private
                // below.
                ListTile(
                  leading: Icon(Icons.devices_outlined, color: t.accent),
                  title: Text('My W@tch',
                      style: TextStyle(color: t.bone, fontSize: 15)),
                  subtitle: Text(
                    'Link your devices — watch lists, viewing positions, '
                    'and detail edits sync automatically',
                    style: TextStyle(color: t.ash, fontSize: 12),
                  ),
                  trailing: Icon(Icons.chevron_right, color: t.ash),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const MyWatchScreen()),
                  ),
                ),
                // One door for the whole library: lists AND the home-row
                // order/visibility (the separate "Home screen" page
                // merged in here).
                ListTile(
                  leading: Icon(Icons.video_library_outlined, color: t.accent),
                  title: Text('My Media',
                      style: TextStyle(color: t.bone, fontSize: 15)),
                  subtitle: Text(
                    lists.isEmpty
                        ? 'No lists yet — home row order and visibility'
                        : '${lists.length} '
                            '${lists.length == 1 ? 'list' : 'lists'} · '
                            '${lists.where((l) => l.enabled).length} shown '
                            'on home · row order and visibility',
                    style: TextStyle(color: t.ash, fontSize: 12),
                  ),
                  trailing: Icon(Icons.chevron_right, color: t.ash),
                  onTap: _openMediaLists,
                ),
                // Upload — moved out of the home drawer (2026-08-29);
                // desktop-only like the Publish flow it opens.
                if (isDesktopPlatform)
                  ListTile(
                    leading:
                        Icon(Icons.cloud_upload_outlined, color: t.accent),
                    title: Text('Upload',
                        style: TextStyle(color: t.bone, fontSize: 15)),
                    subtitle: Text(
                      'Private · only your devices',
                      style: TextStyle(color: t.ash, fontSize: 12),
                    ),
                    trailing: Icon(Icons.chevron_right, color: t.ash),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const PublishScreen()),
                    ),
                  ),
                // Downloads closes the section (2026-08-30, moved out of
                // its own DOWNLOADS section): below My Media, and below
                // Upload where that tile shows (desktop).
                ListenableBuilder(
                  listenable: DownloadManager.instance,
                  builder: (context, _) {
                    final manager = DownloadManager.instance;
                    final active = manager.activeCount;
                    final done = manager.doneCount;
                    return ListTile(
                      leading:
                          Icon(Icons.download_outlined, color: t.accent),
                      title: Text('Downloads',
                          style: TextStyle(color: t.bone, fontSize: 15)),
                      subtitle: Text(
                        manager.tasks.isEmpty
                            ? 'Queue, storage, and playback behaviour'
                            : '$active active · $done downloaded',
                        style: TextStyle(color: t.ash, fontSize: 12),
                      ),
                      trailing: Icon(Icons.chevron_right, color: t.ash),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const DownloadsScreen()),
                      ),
                    );
                  },
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 28, 16, 8),
                  child: Text(
                    'NETWORK',
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w700,
                      color: t.ash,
                    ),
                  ),
                ),
                // Buffer size leads the section (2026-08-30, moved in
                // from the former STREAMING section), then the two
                // embedded network clients: Autonomi streams/downloads
                // media, x0x carries My W@tch and Channels gossip.
                ListTile(
                  leading: Icon(Icons.memory_outlined, color: t.accent),
                  title: Text('Buffer size',
                      style: TextStyle(color: t.bone, fontSize: 15)),
                  subtitle: Text(
                    '$_bufferSizeMb MB',
                    style: TextStyle(color: t.ash, fontSize: 12),
                  ),
                  trailing: Icon(Icons.chevron_right, color: t.ash),
                  onTap: _pickBufferSize,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Text(
                    'How much video the player keeps in memory while '
                    'streaming. Larger buffers ride out slow patches of the '
                    'network but use more RAM (the same amount again is kept '
                    'behind the play position for instant rewind). Takes '
                    'effect the next time you press Play.',
                    style: TextStyle(fontSize: 11.5, color: t.ash),
                  ),
                ),
                ListTile(
                  leading: Icon(Icons.cloud_outlined, color: t.accent),
                  title: Text('Built-in Autonomi client',
                      style: TextStyle(color: t.bone, fontSize: 15)),
                  subtitle: Text(
                    _health?.label ?? 'Checking…',
                    style: TextStyle(color: t.ash, fontSize: 12),
                  ),
                  trailing: Icon(Icons.refresh, color: t.ash, size: 18),
                  onTap: _refreshHealth,
                ),
                ListTile(
                  leading: Icon(Icons.hub_outlined, color: t.accent),
                  title: Text('Built-in x0x client',
                      style: TextStyle(color: t.bone, fontSize: 15)),
                  subtitle: Text(
                    _x0xSubtitle,
                    style: TextStyle(color: t.ash, fontSize: 12),
                  ),
                  trailing: Icon(Icons.chevron_right, color: t.ash),
                  onTap: _openX0xClient,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Text(
                    'Playback streams through the Autonomi client — '
                    'nothing to set up; tap it to refresh the connection '
                    'status. The x0x client is the peer-to-peer network '
                    'behind Channels and My W@tch — open it to switch '
                    'either off.',
                    style: TextStyle(fontSize: 11.5, color: t.ash),
                  ),
                ),
                ListTile(
                  leading: Icon(Icons.wifi_outlined, color: t.accent),
                  title: Text('Downloads',
                      style: TextStyle(color: t.bone, fontSize: 15)),
                  subtitle: Text(
                    switch (_downloadNetwork) {
                      DownloadNetworkPolicy.wifiOnly => 'Wi-Fi only',
                      DownloadNetworkPolicy.any => 'Wi-Fi + mobile data',
                    },
                    style: TextStyle(color: t.ash, fontSize: 12),
                  ),
                  trailing: Icon(Icons.chevron_right, color: t.ash),
                  onTap: _pickDownloadNetwork,
                ),
                ListTile(
                  leading:
                      Icon(Icons.network_cell_outlined, color: t.accent),
                  title: Text('Streaming on mobile data',
                      style: TextStyle(color: t.bone, fontSize: 15)),
                  subtitle: Text(
                    switch (_streamingNetwork) {
                      StreamingNetworkPolicy.ask => 'Ask first',
                      StreamingNetworkPolicy.allow => 'Allowed',
                      StreamingNetworkPolicy.wifiOnly => 'Wi-Fi only',
                    },
                    style: TextStyle(color: t.ash, fontSize: 12),
                  ),
                  trailing: Icon(Icons.chevron_right, color: t.ash),
                  onTap: _pickStreamingNetwork,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Text(
                    'These control the heavy traffic (streams and '
                    'downloads). The built-in client keeps a few idle '
                    'peer connections on any network.',
                    style: TextStyle(fontSize: 11.5, color: t.ash),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 28, 16, 8),
                  child: Text(
                    'METADATA',
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w700,
                      color: t.ash,
                    ),
                  ),
                ),
                ListTile(
                  leading: Icon(Icons.image_search_outlined, color: t.accent),
                  title: Text('TMDB API key',
                      style: TextStyle(color: t.bone, fontSize: 15)),
                  subtitle: Text(
                    switch (_tmdbKeySource) {
                      TmdbKeySource.user => 'Using your key',
                      TmdbKeySource.none =>
                        'Not set — titles come from file names only',
                    },
                    style: TextStyle(color: t.ash, fontSize: 12),
                  ),
                  trailing: Icon(Icons.chevron_right, color: t.ash),
                  onTap: _editTmdbApiKey,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Text(
                    'Artwork, descriptions, and categories are matched from '
                    'TMDB using each entry\'s file name, then cached on this '
                    'device. W@tch ships without a key: create a free one '
                    'at themoviedb.org (Settings → API) and paste either the '
                    'API key or the read access token here — it is never '
                    'displayed. Imported bundles carry metadata and posters, '
                    'so a key is only needed for titles a bundle doesn\'t '
                    'cover.',
                    style: TextStyle(fontSize: 11.5, color: t.ash),
                  ),
                ),
                // Appearance sits below Metadata (2026-08-30, moved down
                // from second place).
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 28, 16, 8),
                  child: Text(
                    'APPEARANCE',
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w700,
                      color: t.ash,
                    ),
                  ),
                ),
                ListTile(
                  leading: Icon(Icons.dark_mode_outlined, color: t.accent),
                  title: Text('Colour scheme',
                      style: TextStyle(color: t.bone, fontSize: 15)),
                  subtitle: Text(
                    _themeModeLabel(wiThemeMode.value)
                        .replaceFirst('  ·  default', ' (default)'),
                    style: TextStyle(color: t.ash, fontSize: 12),
                  ),
                  trailing: Icon(Icons.chevron_right, color: t.ash),
                  onTap: _pickThemeMode,
                ),
                // Desktop-only this edition (Upload is): see
                // docs/PLAN-alpha55.md. Section named WALLET (not
                // PUBLISHING) since the Publish→Upload rename — one
                // wallet funds both spaces
                // (docs/PLAN-personal-vs-channels.md).
                if (isDesktopPlatform) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 28, 16, 8),
                    child: Text(
                      'WALLET',
                      style: TextStyle(
                        fontSize: 11,
                        letterSpacing: 1.5,
                        fontWeight: FontWeight.w700,
                        color: t.ash,
                      ),
                    ),
                  ),
                  ListTile(
                    leading: Icon(Icons.account_balance_wallet_outlined,
                        color: t.accent),
                    title: Text('Wallet',
                        style: TextStyle(color: t.bone, fontSize: 15)),
                    subtitle: Text(
                      'The ANT wallet that pays for uploading files to '
                      'the network',
                      style: TextStyle(color: t.ash, fontSize: 12),
                    ),
                    trailing: Icon(Icons.chevron_right, color: t.ash),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const WalletScreen()),
                    ),
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 28, 16, 8),
                  child: Text(
                    'ABOUT',
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w700,
                      color: t.ash,
                    ),
                  ),
                ),
                ListTile(
                  leading: Icon(Icons.play_circle_outline, color: t.accent),
                  title: const Align(
                    alignment: Alignment.centerLeft,
                    child: BrandWordmark(fontSize: 16),
                  ),
                  subtitle: Text(
                    'Media player for the Autonomi network. Client-only: '
                    'your library is a set of lists you hold on this '
                    'device — no server, no accounts, no telemetry.',
                    style: TextStyle(color: t.ash, fontSize: 12),
                  ),
                ),
                // TMDB terms require this attribution wherever their data
                // or images appear (metadata matching + bundle exports).
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Image.asset(
                        'assets/tmdb_logo.png',
                        height: 13,
                        semanticLabel: 'TMDB logo',
                      ),
                      const SizedBox(height: 8),
                      Text(
                        kTmdbAttributionNotice,
                        style: TextStyle(fontSize: 11.5, color: t.ash),
                      ),
                    ],
                  ),
                ),
                ListTile(
                  leading: Icon(Icons.info_outline, color: t.accent),
                  title: Text('Version',
                      style: TextStyle(color: t.bone, fontSize: 15)),
                  subtitle: Text(
                    _version ?? 'Unknown',
                    style: TextStyle(color: t.ash, fontSize: 12),
                  ),
                ),
                // Android-only: the OS's record of why the app last
                // closed — lets a device without adb report a crash.
                if (ExitInfoService.instance.supported)
                  ListTile(
                    leading:
                        Icon(Icons.report_gmailerrorred_outlined,
                            color: t.accent),
                    title: Text('Why did the app close?',
                        style: TextStyle(color: t.bone, fontSize: 15)),
                    subtitle: Text(
                      'Android\'s record of recent app exits — use it '
                      'to report a crash',
                      style: TextStyle(color: t.ash, fontSize: 12),
                    ),
                    trailing: Icon(Icons.chevron_right, color: t.ash),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const ExitInfoScreen()),
                    ),
                  ),
                if (isDesktopPlatform) ...[
                  ListenableBuilder(
                    listenable: UpdateCheck.instance,
                    builder: (context, _) {
                      final tag = UpdateCheck.instance.availableTag;
                      if (tag == null) return const SizedBox.shrink();
                      return ListTile(
                        leading:
                            Icon(Icons.system_update_alt, color: t.accent),
                        title: Text('Update available',
                            style:
                                TextStyle(color: t.accent, fontSize: 15)),
                        subtitle: Text(
                          '$tag — open the release page to download',
                          style: TextStyle(color: t.ash, fontSize: 12),
                        ),
                        trailing: Icon(Icons.open_in_new,
                            color: t.ash, size: 18),
                        onTap: () => launchUrl(Uri.parse(
                            UpdateCheck.instance.releaseUrl ??
                                UpdateCheck.releasePage)),
                      );
                    },
                  ),
                  SwitchListTile(
                    secondary: Icon(Icons.update, color: t.accent),
                    title: Text('Check for updates on startup',
                        style: TextStyle(color: t.bone, fontSize: 15)),
                    subtitle: Text(
                      'At most once a day, W@tch asks GitHub for the '
                      'latest release and mentions it here if it is '
                      'newer. This is the app\'s only server contact '
                      'besides the Autonomi network and your own '
                      'TMDB key.',
                      style: TextStyle(color: t.ash, fontSize: 12),
                    ),
                    value: _updateCheckEnabled,
                    onChanged: (v) async {
                      await UpdateCheck.setEnabled(v);
                      if (mounted) {
                        setState(() => _updateCheckEnabled = v);
                      }
                    },
                  ),
                ],
                ListTile(
                  leading: Icon(Icons.gavel_outlined, color: t.accent),
                  title: Text('Open-source licenses',
                      style: TextStyle(color: t.bone, fontSize: 15)),
                  subtitle: Text(
                    'W@tch code is MIT; the app as a whole is '
                    'distributed under GPLv3',
                    style: TextStyle(color: t.ash, fontSize: 12),
                  ),
                  trailing: Icon(Icons.chevron_right, color: t.ash),
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: 'W@tch',
                    applicationVersion: _version,
                  ),
                ),
                ListTile(
                  leading: Icon(Icons.policy_outlined, color: t.accent),
                  title: Text('Terms of Use & Disclaimer',
                      style: TextStyle(color: t.bone, fontSize: 15)),
                  subtitle: Text(
                    'The terms you accepted on first launch',
                    style: TextStyle(color: t.ash, fontSize: 12),
                  ),
                  trailing: Icon(Icons.chevron_right, color: t.ash),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const TermsScreen()),
                  ),
                ),
                ListTile(
                  leading: Icon(Icons.sd_storage_outlined, color: t.accent),
                  title: Text('Size on disk',
                      style: TextStyle(color: t.bone, fontSize: 15)),
                  subtitle: Text(
                    !_dataSizeKnown
                        ? 'Measuring…'
                        : _dataSizeBytes == null
                            ? 'Unknown on this platform'
                            : '${formatBytes(_dataSizeBytes!)} — lists, '
                                'artwork, metadata, data maps and network '
                                'state',
                    style: TextStyle(color: t.ash, fontSize: 12),
                  ),
                  trailing: Icon(Icons.refresh, color: t.ash, size: 18),
                  onTap: _loadDataSize,
                ),
                ListTile(
                  leading: Icon(Icons.delete_forever_outlined, color: t.rust),
                  title: Text('Clear all data',
                      style: TextStyle(color: t.rust, fontSize: 15)),
                  subtitle: Text(
                    'Reset W@tch to factory defaults',
                    style: TextStyle(color: t.ash, fontSize: 12),
                  ),
                  onTap: _clearAllData,
                ),
                const SizedBox(height: 80),
              ],
            ),
    );
  }
}

/// Single-field text prompt used for list titles and renames. An
/// optional [note] renders as small print above the field.
Future<String?> promptForText(
  BuildContext context, {
  required String title,
  required String hint,
  String initial = '',
  String? note,
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) {
      final t = WiTokens.of(context);
      return AlertDialog(
        backgroundColor: t.ink2,
        title: Text(title, style: TextStyle(color: t.bone, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (note != null) ...[
              Text(note, style: TextStyle(color: t.boneDim, fontSize: 12)),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: controller,
              autofocus: true,
              style: TextStyle(color: t.bone),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: TextStyle(color: t.ash),
              ),
              onSubmitted: (v) => Navigator.of(context).pop(v),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Cancel', style: TextStyle(color: t.ash)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: Text('Save', style: TextStyle(color: t.accent)),
          ),
        ],
      );
    },
  );
}
