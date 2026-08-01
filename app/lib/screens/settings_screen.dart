import 'dart:async';
import 'dart:io' show exit;

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../models/media_list.dart';
import '../services/app_settings.dart';
import '../services/bundle.dart' show kTmdbAttributionNotice;
import '../services/download_manager.dart';
import '../services/library_store.dart';
import '../services/embedded_client.dart';
import '../services/metadata_service.dart';
import '../services/storage_usage.dart';
import '../theme/tokens.dart';
import '../widgets/brand_mark.dart';
import 'downloads_screen.dart';
import 'home_layout_screen.dart';
import 'media_lists_screen.dart';

/// Settings: library, streaming, metadata, and about sections.
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

  @override
  void initState() {
    super.initState();
    _reload();
    _loadVersion();
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
    if (mounted) {
      setState(() {
        _lists = lists;
        _health = health;
        _bufferSizeMb = bufferSizeMb;
        _tmdbKeySource = tmdbKeySource;
        _downloadNetwork = downloadNetwork;
        _streamingNetwork = streamingNetwork;
      });
    }
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

  /// Reloads on return — the layout screen can change list visibility,
  /// which the Media Lists subtitle counts.
  Future<void> _openHomeLayout() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const HomeLayoutScreen()),
    );
    await _reload();
  }

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
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                  child: Text(
                    'LIBRARY',
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w700,
                      color: t.ash,
                    ),
                  ),
                ),
                ListTile(
                  leading: Icon(Icons.video_library_outlined, color: t.accent),
                  title: Text('Media Lists',
                      style: TextStyle(color: t.bone, fontSize: 15)),
                  subtitle: Text(
                    lists.isEmpty
                        ? 'No lists yet'
                        : '${lists.length} '
                            '${lists.length == 1 ? 'list' : 'lists'} · '
                            '${lists.where((l) => l.enabled).length} shown '
                            'on home',
                    style: TextStyle(color: t.ash, fontSize: 12),
                  ),
                  trailing: Icon(Icons.chevron_right, color: t.ash),
                  onTap: _openMediaLists,
                ),
                ListTile(
                  leading: Icon(Icons.view_agenda_outlined, color: t.accent),
                  title: Text('Home screen',
                      style: TextStyle(color: t.bone, fontSize: 15)),
                  subtitle: Text(
                    'Row order and visibility',
                    style: TextStyle(color: t.ash, fontSize: 12),
                  ),
                  trailing: Icon(Icons.chevron_right, color: t.ash),
                  onTap: _openHomeLayout,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 28, 16, 8),
                  child: Text(
                    'DOWNLOADS',
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w700,
                      color: t.ash,
                    ),
                  ),
                ),
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
                    'STREAMING',
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w700,
                      color: t.ash,
                    ),
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
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Text(
                    'Playback streams through the Autonomi client embedded '
                    'in the app — nothing to set up. Tap to refresh the '
                    'connection status.',
                    style: TextStyle(fontSize: 11.5, color: t.ash),
                  ),
                ),
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
