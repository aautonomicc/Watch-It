import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../widgets/wi_qr.dart';

import '../models/media_list.dart';
import '../services/channel_service.dart';
import '../services/channels_api.dart';
import '../services/ffmpeg.dart';
import '../services/library_store.dart';
import '../services/metadata_service.dart';
import '../services/publish_api.dart';
import '../services/season_grouping.dart';
import '../services/x0x_cellular.dart';
import '../theme/tokens.dart';
import '../widgets/channel_avatar.dart';
import '../widgets/channel_badge.dart';
import '../widgets/poster_crop_dialog.dart';
import 'channel_publish_screen.dart';
import 'describe_item_screen.dart';
import 'list_home_screen.dart';
import 'publish_screen.dart' show isDesktopPlatform;
import 'qr_scan_screen.dart';

/// Channels — the PUBLIC content space (docs/PLAN-personal-vs-channels.md
/// Parts 2–4). Two segments, mirroring the "My lists | Auto" pattern:
///
/// * **Subscribed**: channel cards (name, description, item count,
///   update state) + Add channel by `wchn1-` code (paste or scan).
///   Subscribed content lands on the normal home wall as badged
///   read-only lists — subscribers just want to watch.
/// * **My Channel**: create (name → 12-word key ceremony → full-screen
///   public-permanence gate) / restore by phrase; then the code + QR,
///   the item list subscribers see, "+ Publish an item" (pick a LOCAL
///   FILE → encode qualities → required Describe-this-item → per-item
///   rights attestation → upload; see channel_publish_screen.dart —
///   already-uploaded library items keep a secondary picker path), and
///   Publish update with a cost preview. Everything publish-side is
///   desktop-only, like Upload.
///
/// Every surface here is amber ("PUBLIC") on purpose; the word
/// "publish" is reserved for this screen — the private flow is Upload.
class ChannelsScreen extends StatefulWidget {
  const ChannelsScreen(
      {super.key, this.apiBase, this.apiToken, this.ffmpeg});

  /// Test overrides for the embedded server base URL / auth token.
  final String? apiBase;
  final String? apiToken;

  /// Test override for the publish flow's ffmpeg integration.
  final FfmpegService? ffmpeg;

  @override
  State<ChannelsScreen> createState() => _ChannelsScreenState();
}

enum _Segment { subscribed, mine }

class _ChannelsScreenState extends State<ChannelsScreen> {
  late final ChannelsApi _api =
      ChannelsApi(base: widget.apiBase, token: widget.apiToken);
  late final PublishApi _publishApi =
      PublishApi(base: widget.apiBase, token: widget.apiToken);

  _Segment _segment = _Segment.subscribed;
  ChannelsStatus? _status;
  String? _error;
  List<ChannelRecord> _records = const [];
  List<MediaList> _lists = const [];
  List<MyChannelItem> _myItems = const [];
  File? _myAvatar;
  Timer? _poll;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    ChannelService.instance.api = _api;
    ChannelService.instance.publishApi = _publishApi;
    ChannelService.instance.addListener(_onServiceChange);
    _reload();
    // Heads gossip in within seconds of subscribing — keep the cards
    // fresh while the screen is open (localhost poll).
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _refreshStatus());
  }

  @override
  void dispose() {
    _poll?.cancel();
    ChannelService.instance.removeListener(_onServiceChange);
    super.dispose();
  }

  void _onServiceChange() {
    if (mounted) _reload();
  }

  Future<void> _reload() async {
    final records = await ChannelService.instance.records();
    final lists = await LibraryStore.load();
    final items = await ChannelService.instance.myItems();
    final avatar = await ChannelService.instance.myAvatarFile();
    if (!mounted) return;
    setState(() {
      _records = records;
      _lists = lists;
      _myItems = items;
      _myAvatar = avatar;
    });
    await _refreshStatus();
  }

  Future<void> _refreshStatus() async {
    try {
      final status = await _api.status();
      if (!mounted) return;
      setState(() {
        _status = status;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _status == null ? '$e' : _error);
    }
  }

  /// Manual sync, same shape as My W@tch's Sync now. checkNow waits
  /// out any in-flight background cycle and runs a fresh full pass, so
  /// the snackbar's claim holds even when a cycle was already running.
  Future<void> _checkNow() async {
    setState(() => _checking = true);
    try {
      await ChannelService.instance.checkNow();
    } finally {
      if (mounted) setState(() => _checking = false);
    }
    if (mounted) _snack('Checked all subscribed channels');
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Row(
          children: [
            Text('Channels',
                style: TextStyle(color: t.bone, fontSize: 18)),
            const SizedBox(width: 10),
            const ChannelBadge(text: 'PUBLIC'),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: SegmentedButton<_Segment>(
              segments: const [
                ButtonSegment(
                    value: _Segment.subscribed, label: Text('Subscribed')),
                ButtonSegment(
                    value: _Segment.mine, label: Text('My Channel')),
              ],
              selected: {_segment},
              onSelectionChanged: (s) =>
                  setState(() => _segment = s.first),
            ),
          ),
          _connectionBar(t),
          Expanded(
            child: _error != null && _status == null
                ? _errorRetry(t)
                : _segment == _Segment.subscribed
                    ? _subscribedBody(t)
                    : _myChannelBody(t),
          ),
        ],
      ),
    );
  }

  /// Always-visible connection state of the channel gossip network, on
  /// both segments — a dot + plain words, same language as the home
  /// screen's network bar, so "why is nothing updating?" answers itself.
  Widget _connectionBar(WiTokens t) {
    final state = _status?.state;
    final (color, text) = switch (state) {
      'ready' => (
          const Color(0xff4caf50),
          'Connected to the channel network',
        ),
      'starting' => (
          WiTokens.channelAmber,
          'Connecting to the channel network…',
        ),
      'off' when _status?.enabled == false => (
          t.ash,
          X0xCellularGate.instance.isPaused(X0xAgent.channels)
              ? 'Paused on mobile data — updates resume on Wi-Fi'
              : 'Switched off — turn Channels on in Settings → '
                  'Built-in clients',
        ),
      'off' => (
          t.ash,
          'Not connected — connects when you create or add a channel',
        ),
      // Status not fetched yet (or the fetch failed — _errorRetry has
      // the details in that case).
      _ => (t.ash, 'Checking connection…'),
    };
    return Container(
      width: double.infinity,
      color: t.ink2,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          if (state == 'starting')
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(
                  strokeWidth: 1.5, color: color),
            )
          else
            Container(
              width: 8,
              height: 8,
              decoration:
                  BoxDecoration(color: color, shape: BoxShape.circle),
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
  }

  Widget _errorRetry(WiTokens t) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error ?? '',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: t.boneDim, fontSize: 13)),
              const SizedBox(height: 16),
              OutlinedButton(
                  onPressed: _reload, child: const Text('Retry')),
            ],
          ),
        ),
      );

  // ---- Subscribed segment -----------------------------------------------

  Widget _subscribedBody(WiTokens t) {
    final status = _status;
    final subsByKey = {
      for (final s in status?.subs ?? const <SubscribedChannel>[])
        s.pubkey.toLowerCase(): s,
    };
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_records.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              'No subscribed channels yet. A channel is a public, '
              'signed media list you follow with its wchn1- code — its '
              'content appears on your home screen as a read-only list '
              'and updates automatically.',
              style: TextStyle(color: t.boneDim, fontSize: 13, height: 1.4),
            ),
          )
        else
          for (final record in _records)
            _channelCard(t, record, subsByKey[record.pubkey]),
        const SizedBox(height: 16),
        if (_records.isNotEmpty) ...[
          OutlinedButton.icon(
            icon: const Icon(Icons.sync),
            label: const Text('Sync now'),
            onPressed: _checking ? null : _checkNow,
          ),
          const SizedBox(height: 12),
        ],
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: WiTokens.channelAmber,
            foregroundColor: Colors.black,
          ),
          onPressed: _addChannel,
          icon: const Icon(Icons.add),
          label: const Text('Add channel'),
        ),
      ],
    );
  }

  Widget _channelCard(
      WiTokens t, ChannelRecord record, SubscribedChannel? sub) {
    final list = _lists
        .where((l) => l.channelPubkey == record.pubkey)
        .firstOrNull;
    final head = sub?.head;
    final problem = ChannelService.instance.lastProblem[record.pubkey];
    final title = record.name.isNotEmpty
        ? record.name
        : list?.title ?? 'Channel ${record.pubkey.substring(0, 8)}';
    // A fetch problem is almost always transient (a fresh publish still
    // propagating, or a network hiccup) and the 5-minute loop retries
    // until it succeeds — so read calm, not alarmed. The raw error stays
    // one hover/long-press away for reports.
    final updateLine = problem != null
        ? 'Update found — not fully reachable yet, retrying automatically'
        : head == null
            ? 'Waiting for the channel\'s current head to arrive…'
            : head.seq > record.importedSeq
                ? 'Update available (v${head.seq}) — importing…'
                : 'Up to date · v${record.importedSeq}';
    return Card(
      color: t.ink2,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: t.line),
      ),
      child: ListTile(
        leading: ChannelAvatar(memberName: record.avatar, size: 40),
        title: Row(
          children: [
            Flexible(
              child: Text(title,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.bone, fontSize: 15)),
            ),
            const SizedBox(width: 8),
            const ChannelBadge(),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (record.author.isNotEmpty)
              Text('by ${record.author}',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.boneDim, fontSize: 12)),
            if (record.description.isNotEmpty)
              Text(record.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.boneDim, fontSize: 12)),
            Builder(builder: (context) {
              final line = Text(
                '${list?.entries.length ?? 0} items · $updateLine',
                style: TextStyle(
                    color:
                        problem != null ? WiTokens.channelAmber : t.ash,
                    fontSize: 12),
              );
              return problem == null
                  ? line
                  : Tooltip(message: problem, child: line);
            }),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (sub != null && sub.code.isNotEmpty)
              IconButton(
                tooltip: 'Show QR code',
                icon: Icon(Icons.qr_code_2, color: t.ash, size: 20),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => _ChannelQrDialog(code: sub.code),
                ),
              ),
            PopupMenuButton<String>(
              tooltip: 'Channel options',
              icon: Icon(Icons.more_vert, color: t.ash),
              color: t.ink2,
              onSelected: (v) => switch (v) {
                'copy' => _copyCode(sub?.code ?? ''),
                'unsubscribe' => _unsubscribe(record, title),
                _ => null,
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'copy',
                  child: Text('Copy channel code',
                      style: TextStyle(color: t.bone, fontSize: 14)),
                ),
                PopupMenuItem(
                  value: 'unsubscribe',
                  child: Text('Unsubscribe',
                      style: TextStyle(color: t.rust, fontSize: 14)),
                ),
              ],
            ),
          ],
        ),
        onTap: list == null
            ? null
            : () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ListHomeScreen(list: list))),
      ),
    );
  }

  void _copyCode(String code) {
    if (code.isEmpty) return;
    Clipboard.setData(ClipboardData(text: code));
    _snack('Channel code copied');
  }

  Future<void> _unsubscribe(ChannelRecord record, String title) async {
    final t = WiTokens.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: t.ink2,
        title: Text('Unsubscribe from "$title"?',
            style: TextStyle(color: t.bone, fontSize: 16)),
        content: Text(
          'The channel\'s list disappears from your library and stops '
          'updating. You can re-add it any time with its code.',
          style: TextStyle(color: t.boneDim, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel', style: TextStyle(color: t.ash)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Unsubscribe', style: TextStyle(color: t.rust)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ChannelService.instance.unsubscribe(record.pubkey);
    _snack('Unsubscribed');
    await _reload();
  }

  Future<void> _addChannel() async {
    final code = await showDialog<String>(
      context: context,
      builder: (_) => const AddChannelDialog(),
    );
    if (code == null || !mounted) return;
    try {
      await ChannelService.instance.subscribe(code);
      _snack('Subscribed — the channel appears once its head arrives');
    } catch (e) {
      _snack('$e');
    }
    await _reload();
  }

  // ---- My Channel segment -----------------------------------------------

  Widget _myChannelBody(WiTokens t) {
    final status = _status;
    if (status == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!isDesktopPlatform) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Creating and publishing a channel is desktop-only in this '
          'version (it needs local files and the upload wallet). '
          'Subscribing works everywhere.',
          style: TextStyle(color: t.boneDim, fontSize: 13, height: 1.4),
        ),
      );
    }
    final own = status.own;
    return own == null ? _noChannelBody(t) : _ownChannelBody(t, own);
  }

  Widget _noChannelBody(WiTokens t) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'A channel publishes a signed list of media that anyone with '
          'its code can watch — like a public playlist you own.',
          style: TextStyle(color: t.bone, fontSize: 14, height: 1.4),
        ),
        const SizedBox(height: 10),
        Text(
          'Everything published to a channel is PUBLIC and PERMANENT: '
          'it can never be deleted from the network, and it is '
          'attributable to your channel key. Only publish what you '
          'created or hold the rights to distribute.',
          style: TextStyle(
              color: WiTokens.channelAmber, fontSize: 13, height: 1.4),
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: WiTokens.channelAmber,
            foregroundColor: Colors.black,
          ),
          onPressed: _createChannel,
          icon: const Icon(Icons.add),
          label: const Text('Create channel'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _restoreChannel,
          icon: const Icon(Icons.key_outlined),
          label: const Text('Restore channel'),
        ),
      ],
    );
  }

  Future<void> _createChannel() async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => CreateChannelScreen(api: _api)),
    );
    if (created == true) {
      _snack('Channel created');
      await _reload();
    }
  }

  Future<void> _restoreChannel() async {
    final restored = await showDialog<CreatedChannel>(
      context: context,
      builder: (_) => _RestoreChannelDialog(api: _api),
    );
    if (restored == null || !mounted) return;
    _snack('Channel restored — code ${restored.code}');
    await _reload();
    // Pull the published item list back once the head gossips in.
    unawaited(_tryRestoreItems());
  }

  Future<void> _tryRestoreItems() async {
    for (var attempt = 0; attempt < 12; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 5));
      ChannelsStatus status;
      try {
        status = await _api.status();
      } catch (_) {
        continue;
      }
      final head = status.own?.head;
      if (head == null) continue;
      try {
        final n = await ChannelService.instance
            .restoreMyItemsFromManifest(head);
        _snack('Recovered $n channel items from the network');
      } catch (e) {
        _snack('Could not fetch the channel\'s manifest yet: $e');
      }
      await _reload();
      return;
    }
  }

  Widget _ownChannelBody(WiTokens t, OwnChannel own) {
    Widget header(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(0, 22, 0, 6),
          child: Text(
            text,
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w700,
              color: t.ash,
            ),
          ),
        );
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            ChannelAvatar(file: _myAvatar, size: 44),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    own.name.isEmpty ? '(unnamed channel)' : own.name,
                    style: TextStyle(
                        color: t.bone,
                        fontSize: 18,
                        fontWeight: FontWeight.w600),
                  ),
                  if (own.author.isNotEmpty)
                    Text('by ${own.author}',
                        style:
                            TextStyle(color: t.boneDim, fontSize: 12.5)),
                ],
              ),
            ),
            const ChannelBadge(text: 'PUBLIC'),
          ],
        ),
        if (own.description.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(own.description,
                style: TextStyle(color: t.boneDim, fontSize: 13)),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _editChannel,
            icon: Icon(Icons.edit_outlined, color: t.ash, size: 16),
            label: Text('Edit channel details',
                style: TextStyle(color: t.ash, fontSize: 13)),
          ),
        ),
        header('CHANNEL CODE — SHARE THIS'),
        Row(
          children: [
            Expanded(
              child: SelectableText(
                own.code,
                style: TextStyle(
                  fontFamily: wiMonoFamily,
                  fontFamilyFallback: wiMonoFallback,
                  fontSize: 12,
                  color: WiTokens.channelAmber,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Copy code',
              icon: Icon(Icons.copy, color: t.ash, size: 18),
              onPressed: () => _copyCode(own.code),
            ),
            IconButton(
              tooltip: 'Show QR code',
              icon: Icon(Icons.qr_code_2, color: t.ash, size: 20),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => _ChannelQrDialog(code: own.code),
              ),
            ),
          ],
        ),
        Text(
          'Anyone with this code can subscribe and watch everything the '
          'channel publishes.',
          style: TextStyle(color: t.ash, fontSize: 12),
        ),
        header('BACKUP'),
        if (own.keyMissing)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.error_outline, color: t.rust),
            title: Text('Channel key is missing',
                style: TextStyle(color: t.rust, fontSize: 14)),
            subtitle: Text(
              'The signing key is gone from this computer — publishing '
              'is frozen until you restore from the recovery phrase.',
              style: TextStyle(color: t.boneDim, fontSize: 12),
            ),
          )
        else ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.verified_outlined, color: t.signalOk),
            title: Text('Recovery phrase backed up ✓',
                style: TextStyle(color: t.bone, fontSize: 14)),
            subtitle: Text(
              'Confirmed during creation. The phrase is never stored — '
              'losing it means the channel can never publish again '
              'if this computer dies. It restores the channel, not '
              'your wallet money.',
              style: TextStyle(color: t.ash, fontSize: 12),
            ),
          ),
          if (own.keyStorage == 'file')
            Text(
              'No system keychain was found, so the channel key is '
              'stored in an app file on this computer.',
              style: TextStyle(color: t.rust, fontSize: 12),
            ),
        ],
        header('ITEMS — WHAT SUBSCRIBERS SEE'),
        if (own.seq > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'Published: v${own.seq}. Removing an item only stops NEW '
              'subscribers from seeing it — old manifests stay on the '
              'network forever.',
              style: TextStyle(color: t.ash, fontSize: 12, height: 1.4),
            ),
          ),
        if (own.pendingAnnounce)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'The latest update is on the network but not announced yet '
              '— subscribers are told automatically when Channels is '
              'switched back on (Settings → Built-in clients).',
              style: TextStyle(
                  color: WiTokens.channelAmber, fontSize: 12, height: 1.4),
            ),
          ),
        if (_myItems.isEmpty)
          Text(
            'No items yet. Items are added one explicit pick at a time — '
            'there is no bulk publish.',
            style: TextStyle(color: t.boneDim, fontSize: 13),
          )
        else
          for (final item in _myItems)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(Icons.movie_outlined, color: t.boneDim, size: 20),
              title: Text(item.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.bone, fontSize: 13.5)),
              trailing: IconButton(
                tooltip: 'Remove from channel (next publish)',
                icon: Icon(Icons.close, color: t.ash, size: 18),
                onPressed: () async {
                  await ChannelService.instance.removeMyItem(item.address);
                  await _reload();
                },
              ),
            ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: own.keyMissing ? null : () => _publishItem(own),
          icon: const Icon(Icons.add, color: WiTokens.channelAmber),
          label: const Text('Publish an item',
              style: TextStyle(color: WiTokens.channelAmber)),
        ),
        const SizedBox(height: 4),
        TextButton(
          onPressed: own.keyMissing ? null : () => _addLibraryItem(own),
          child: Text('Add an item already in the library',
              style: TextStyle(color: t.ash, fontSize: 13)),
        ),
        const SizedBox(height: 6),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: WiTokens.channelAmber,
            foregroundColor: Colors.black,
          ),
          onPressed: _myItems.isEmpty || own.keyMissing
              ? null
              : () => _publishUpdate(own),
          icon: const Icon(Icons.publish),
          label: Text(own.seq == 0
              ? 'Publish channel · public & permanent'
              : 'Publish update · public & permanent'),
        ),
        header('DANGER ZONE'),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.delete_forever_outlined, color: t.rust),
          title: Text('Remove channel from this computer',
              style: TextStyle(color: t.rust, fontSize: 14)),
          subtitle: Text(
            'Subscribers keep the last published version; publishing '
            'freezes until the channel is restored from its phrase.',
            style: TextStyle(color: t.ash, fontSize: 12),
          ),
          onTap: () => _removeChannel(own),
        ),
        const SizedBox(height: 32),
      ],
    );
  }

  /// Avatar / name / author / description — staged locally, rides the
  /// next publish.
  Future<void> _editChannel() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => EditChannelScreen(api: _api)),
    );
    if (changed == true) {
      _snack('Saved — goes public with the next publish');
      await _reload();
    }
  }

  Future<void> _removeChannel(OwnChannel own) async {
    final t = WiTokens.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: t.ink2,
        title: Text('Remove channel?',
            style: TextStyle(color: t.bone, fontSize: 16)),
        content: Text(
          'The channel key and its item list are deleted from this '
          'computer. Without the 12-word recovery phrase the channel is '
          'frozen forever at what it last published — there is no other '
          'way back.',
          style: TextStyle(color: t.boneDim, fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Cancel', style: TextStyle(color: t.ash)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Remove channel', style: TextStyle(color: t.rust)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _api.removeOwn();
      await ChannelService.instance.clearMyItems();
      // Drops the channel's amber list from the library too.
      unawaited(ChannelService.instance.syncNow());
      _snack('Channel removed from this computer');
    } catch (e) {
      _snack('$e');
    }
    await _reload();
  }

  /// The add-to-channel flow, Upload-shaped: pick a LOCAL FILE → choose
  /// the qualities to encode → required Describe-this-item (Check TMDB
  /// available) → per-item rights attestation → encode + upload. The
  /// finished uploads land staged on the item list (with an optional
  /// add-to-library leg); Publish update ships them (cost preview
  /// first).
  Future<void> _publishItem(OwnChannel own) async {
    final staged = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ChannelPublishScreen(
            apiBase: widget.apiBase,
            apiToken: widget.apiToken,
            ffmpeg: widget.ffmpeg),
      ),
    );
    if (staged == true && mounted) {
      _snack('Staged — press "Publish update" to make it public');
    }
    await _reload();
  }

  /// Secondary path for content that is ALREADY uploaded: pick from the
  /// library → required Describe-this-item page → per-item rights
  /// attestation → staged. (The primary "Publish an item" starts from a
  /// local file instead.)
  Future<void> _addLibraryItem(OwnChannel own) async {
    final entry = await showDialog<MediaEntry>(
      context: context,
      builder: (_) => _PickItemDialog(
          lists: _lists,
          alreadyStaged: {for (final i in _myItems) i.address}),
    );
    if (entry == null || !mounted) return;
    // Required metadata BEFORE the attestation: fresh content is not in
    // TMDB, so subscribers only see what gets written here.
    final described = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
          builder: (_) => DescribeItemScreen(entry: entry)),
    );
    if (described != true || !mounted) return;
    final attested = await showDialog<bool>(
      context: context,
      builder: (_) => ChannelAttestationDialog(entryName: entry.name),
    );
    if (attested != true || !mounted) return;
    await ChannelService.instance.addMyItem(entry);
    _snack('Added — press "Publish update" to make it public');
    await _reload();
  }

  /// Build the manifest, preview the cost, publish, follow the job.
  Future<void> _publishUpdate(OwnChannel own) async {
    final ChannelManifestBuild build;
    try {
      build = await ChannelService.instance.buildMyManifest(own: own);
    } catch (e) {
      _snack('$e');
      return;
    }
    if (!mounted) return;
    try {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (_) => _CostPreviewDialog(
          api: _publishApi,
          build: build,
          firstPublish: own.seq == 0,
        ),
      );
      if (proceed != true || !mounted) return;
      // The manifest file stays on disk until the finally below, so a
      // failed publish can be retried from the progress dialog without
      // rebuilding (already-stored chunks are free on the network side).
      var again = true;
      while (again && mounted) {
        again = false;
        final id = await _api.publishManifest(build.path,
            name: '${own.name} manifest');
        if (!mounted) return;
        final outcome = await showDialog<Object>(
          context: context,
          barrierDismissible: false,
          builder: (_) => _PublishProgressDialog(api: _publishApi, id: id),
        );
        if (outcome is UploadResult) {
          _snack(outcome.announced
              ? 'Published v${outcome.seq ?? '?'} — subscribers update '
                  'automatically'
              : 'Published v${outcome.seq ?? '?'} — saved on this device; '
                  'subscribers are told when Channels is switched back on');
          // Refresh this machine's own amber list from the new manifest.
          unawaited(ChannelService.instance.syncNow());
        } else if (outcome == _PublishProgressDialog.retry) {
          again = true;
        }
      }
    } catch (e) {
      _snack('$e');
    } finally {
      try {
        File(build.path).parent.deleteSync(recursive: true);
      } catch (_) {}
    }
    await _reload();
  }
}

// ---------------------------------------------------------------------------
// Channel avatar picking (create form + edit screen)
// ---------------------------------------------------------------------------

/// Pick an image file and crop it square for the channel avatar.
/// Returns the crop bytes (≤512px, far under the 2 MB member cap) or
/// null on cancel/refusal. The crop is forced 1:1 — the stored bytes
/// are always square, so the circular render never surprises. A picked
/// GIF flattens to its first frame here, by design (avatars are still
/// images).
Future<Uint8List?> pickChannelAvatar(BuildContext context) async {
  final file = await openFile(acceptedTypeGroups: const [
    XTypeGroup(
        label: 'Images',
        extensions: ['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp']),
    XTypeGroup(label: 'All files'),
  ]);
  if (file == null) return null;
  final bytes = await file.readAsBytes();
  if (!context.mounted) return null;
  if (bytes.length > 10 * 1024 * 1024) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content:
            Text('That image is larger than 10 MB — pick a smaller one.')));
    return null;
  }
  final cropped = await showDialog<Uint8List>(
    context: context,
    builder: (_) => PosterCropDialog(
      bytes: bytes,
      aspect: 1,
      title: 'Crop your avatar',
      hint: 'The square becomes the circular avatar: drag to position, '
          'zoom to fill it. Square images of at least 256px work best.',
      allowWholeFrame: false,
      maxOutputDimension: 512,
    ),
  );
  if (cropped == null || !context.mounted) return null;
  if (cropped.length > kMaxChannelAvatarBytes) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('The cropped avatar is larger than the 2 MB limit — '
            'try a smaller image.')));
    return null;
  }
  return cropped;
}

/// The 96px circular avatar picker — amber 1px ring, camera overlay
/// badge; empty state is the podcasts icon in a dim circle. Shows
/// [bytes] when a fresh crop is staged, else [file] (the stored crop).
class ChannelAvatarPicker extends StatelessWidget {
  const ChannelAvatarPicker({
    super.key,
    this.bytes,
    this.file,
    required this.onPick,
    this.onClear,
  });

  final Uint8List? bytes;
  final File? file;
  final VoidCallback onPick;

  /// Offered (as a small "Remove" action) only while an avatar exists.
  final VoidCallback? onClear;

  bool get _hasAvatar =>
      bytes != null || (file != null && file!.existsSync());

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final image = bytes != null
        ? ClipOval(
            child: Image.memory(bytes!,
                width: 94, height: 94, fit: BoxFit.cover))
        : ChannelAvatar(file: file, size: 94);
    return Column(
      children: [
        Center(
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPick,
            child: Stack(
              children: [
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border:
                        Border.all(color: WiTokens.channelAmber, width: 1),
                  ),
                  child: Center(child: image),
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: t.ink2,
                      shape: BoxShape.circle,
                      border: Border.all(color: t.line),
                    ),
                    child: Icon(Icons.photo_camera_outlined,
                        color: t.boneDim, size: 15),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_hasAvatar && onClear != null)
          TextButton(
            onPressed: onClear,
            child: Text('Remove avatar',
                style: TextStyle(color: t.ash, fontSize: 12)),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Edit channel details (avatar / name / author / description)
// ---------------------------------------------------------------------------

/// Profile editing for the owner's channel. Everything here is staged
/// locally — the config + avatar file — and goes public with the NEXT
/// publish (the manifest is rebuilt on every head, so the profile rides
/// it; no separate mechanism). Pops true when something was saved.
class EditChannelScreen extends StatefulWidget {
  const EditChannelScreen({super.key, this.api});

  /// Test override; defaults to the service's live API.
  final ChannelsApi? api;

  @override
  State<EditChannelScreen> createState() => _EditChannelScreenState();
}

class _EditChannelScreenState extends State<EditChannelScreen> {
  ChannelsApi get _api => widget.api ?? ChannelService.instance.api;

  final _name = TextEditingController();
  final _author = TextEditingController();
  final _description = TextEditingController();
  File? _avatarFile;
  Uint8List? _pickedAvatar;
  bool _avatarRemoved = false;
  bool _loaded = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _author.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final status = await _api.status();
      final own = status.own;
      final avatar = await ChannelService.instance.myAvatarFile();
      if (!mounted) return;
      setState(() {
        _name.text = own?.name ?? '';
        _author.text = own?.author ?? '';
        _description.text = own?.description ?? '';
        _avatarFile = avatar;
        _loaded = true;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loaded = true;
        });
      }
    }
  }

  Future<void> _pick() async {
    final bytes = await pickChannelAvatar(context);
    if (bytes != null && mounted) {
      setState(() {
        _pickedAvatar = bytes;
        _avatarRemoved = false;
      });
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'The channel name cannot be empty.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _api.setMeta(
        name: name,
        description: _description.text.trim(),
        author: _author.text.trim(),
      );
      if (_pickedAvatar != null) {
        await ChannelService.instance.setMyAvatar(_pickedAvatar!);
      } else if (_avatarRemoved) {
        await ChannelService.instance.clearMyAvatar();
      }
      // The own amber list follows the staged profile right away.
      unawaited(ChannelService.instance.syncNow());
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Text('Edit channel details',
            style: TextStyle(color: t.bone, fontSize: 18)),
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                ChannelAvatarPicker(
                  bytes: _pickedAvatar,
                  file: _avatarRemoved ? null : _avatarFile,
                  onPick: _pick,
                  onClear: () => setState(() {
                    _pickedAvatar = null;
                    _avatarRemoved = true;
                  }),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _name,
                  maxLength: 80,
                  style: TextStyle(color: t.bone),
                  decoration: InputDecoration(
                    labelText: 'Channel name',
                    labelStyle: TextStyle(color: t.ash),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _author,
                  maxLength: 80,
                  style: TextStyle(color: t.bone),
                  decoration: InputDecoration(
                    labelText: 'Author name or handle',
                    labelStyle: TextStyle(color: t.ash),
                    helperText: 'Optional. Shown as "by <author>" on your '
                        'channel. Public and permanent.',
                    helperMaxLines: 2,
                    helperStyle: TextStyle(color: t.ash, fontSize: 11),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _description,
                  maxLines: 3,
                  maxLength: 500,
                  style: TextStyle(color: t.bone),
                  decoration: InputDecoration(
                    labelText: 'Description (optional)',
                    labelStyle: TextStyle(color: t.ash),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Changes are staged on this computer and go public with '
                  'the next publish. Old manifests — including an old '
                  'avatar — stay on the network; they just stop being '
                  'shown.',
                  style: TextStyle(
                      color: WiTokens.channelAmber,
                      fontSize: 12.5,
                      height: 1.4),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(_error!,
                        style: TextStyle(color: t.rust, fontSize: 13)),
                  ),
                const SizedBox(height: 16),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: WiTokens.channelAmber,
                    foregroundColor: Colors.black,
                  ),
                  onPressed: _busy ? null : _save,
                  child: Text(_busy ? 'Saving…' : 'Save'),
                ),
              ],
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// Add channel
// ---------------------------------------------------------------------------

/// Paste (or scan, on mobile) a `wchn1-` channel code. Carries the
/// subscriber-side note: content comes from the channel owner, not from
/// W@tch, and the standing prohibited-use terms apply.
class AddChannelDialog extends StatefulWidget {
  const AddChannelDialog({super.key});

  @override
  State<AddChannelDialog> createState() => _AddChannelDialogState();
}

class _AddChannelDialogState extends State<AddChannelDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final code = _controller.text.trim();
    if (code.isEmpty) return;
    Navigator.of(context).pop(code);
  }

  Future<void> _scan() async {
    final code = await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => QrScanScreen(
        title: 'Scan channel code',
        hint: 'Point at a wchn1- channel QR code',
        accept: (value) => value.toLowerCase().startsWith('wchn1-'),
      ),
    ));
    if (code != null && mounted) Navigator.of(context).pop(code);
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return AlertDialog(
      backgroundColor: t.ink2,
      title: Row(
        children: [
          Text('Add channel', style: TextStyle(color: t.bone, fontSize: 16)),
          const SizedBox(width: 8),
          const ChannelBadge(text: 'PUBLIC'),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              style: TextStyle(
                fontFamily: wiMonoFamily,
                fontFamilyFallback: wiMonoFallback,
                fontSize: 13,
                color: t.bone,
              ),
              decoration: InputDecoration(
                hintText: 'wchn1-…',
                hintStyle: TextStyle(color: t.ash),
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submit(),
            ),
            if (!isDesktopPlatform)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: OutlinedButton.icon(
                  onPressed: _scan,
                  icon: const Icon(Icons.qr_code_scanner, size: 18),
                  label: const Text('Scan QR code'),
                ),
              ),
            const SizedBox(height: 12),
            Text(
              'Channel content comes from the channel\'s owner, not from '
              'W@tch. The terms you accepted apply to what you watch and '
              're-share.',
              style: TextStyle(color: t.ash, fontSize: 11.5, height: 1.4),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Cancel', style: TextStyle(color: t.ash)),
        ),
        TextButton(
          onPressed: _submit,
          child: const Text('Subscribe',
              style: TextStyle(color: WiTokens.channelAmber)),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Create channel: form → key ceremony → public-permanence gate
// ---------------------------------------------------------------------------

class CreateChannelScreen extends StatefulWidget {
  const CreateChannelScreen({super.key, required this.api, this.confirmIndices});

  final ChannelsApi api;

  /// Word positions the ceremony's confirm step asks for; random when
  /// null. Fixed in tests.
  final List<int>? confirmIndices;

  @override
  State<CreateChannelScreen> createState() => _CreateChannelScreenState();
}

class _CreateChannelScreenState extends State<CreateChannelScreen> {
  final _name = TextEditingController();
  final _author = TextEditingController();
  final _description = TextEditingController();
  Uint8List? _avatar;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _author.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final bytes = await pickChannelAvatar(context);
    if (bytes != null && mounted) setState(() => _avatar = bytes);
  }

  Future<void> _next() async {
    final name = _name.text.trim();
    if (name.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final GeneratedChannel generated;
    try {
      generated = await widget.api.generate();
    } catch (e) {
      setState(() {
        _busy = false;
        _error = '$e';
      });
      return;
    }
    if (!mounted) return;
    final done = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => ChannelSeedBackupScreen(
        generated: generated,
        channelName: name,
        description: _description.text.trim(),
        author: _author.text.trim(),
        avatar: _avatar,
        api: widget.api,
        confirmIndices: widget.confirmIndices,
      ),
    ));
    if (!mounted) return;
    if (done == true) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Text('Create channel',
            style: TextStyle(color: t.bone, fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // The channel's face — optional but encouraged; forced 1:1
          // crop so the circle render never surprises.
          ChannelAvatarPicker(
            bytes: _avatar,
            onPick: _pickAvatar,
            onClear: () => setState(() => _avatar = null),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            autofocus: true,
            maxLength: 80,
            style: TextStyle(color: t.bone),
            decoration: InputDecoration(
              labelText: 'Channel name',
              labelStyle: TextStyle(color: t.ash),
              helperText: 'Shown to every subscriber',
              helperStyle: TextStyle(color: t.ash, fontSize: 11),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _author,
            maxLength: 80,
            style: TextStyle(color: t.bone),
            decoration: InputDecoration(
              labelText: 'Author name or handle',
              labelStyle: TextStyle(color: t.ash),
              helperText: 'Optional. Shown as "by <author>" on your '
                  'channel. Public and permanent.',
              helperMaxLines: 2,
              helperStyle: TextStyle(color: t.ash, fontSize: 11),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _description,
            maxLines: 3,
            maxLength: 500,
            style: TextStyle(color: t.bone),
            decoration: InputDecoration(
              labelText: 'Description (optional)',
              labelStyle: TextStyle(color: t.ash),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Next: the channel\'s recovery phrase — 12 words that are '
            'the ONLY way to ever move or restore this channel. The '
            'backup ceremony runs before the channel exists.',
            style: TextStyle(color: t.boneDim, fontSize: 12.5, height: 1.4),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child:
                  Text(_error!, style: TextStyle(color: t.rust, fontSize: 13)),
            ),
          const SizedBox(height: 20),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: WiTokens.channelAmber,
              foregroundColor: Colors.black,
            ),
            onPressed: _busy ? null : _next,
            child: Text(_busy ? 'Preparing…' : 'Continue'),
          ),
        ],
      ),
    );
  }
}

/// One-time display of the channel's 12 words + confirm-by-retyping,
/// mirroring the wallet ceremony — by the time the channel exists, its
/// backup exists. Deliberately a SEPARATE phrase from the wallet's: the
/// wallet is a disposable hot wallet, this phrase IS the channel.
class ChannelSeedBackupScreen extends StatefulWidget {
  const ChannelSeedBackupScreen({
    super.key,
    required this.generated,
    required this.channelName,
    required this.description,
    this.author = '',
    this.avatar,
    required this.api,
    this.confirmIndices,
  });

  final GeneratedChannel generated;
  final String channelName;
  final String description;

  /// Optional profile extras from the create form, carried through to
  /// the gate (where the channel is actually created).
  final String author;
  final Uint8List? avatar;
  final ChannelsApi api;
  final List<int>? confirmIndices;

  @override
  State<ChannelSeedBackupScreen> createState() =>
      _ChannelSeedBackupScreenState();
}

class _ChannelSeedBackupScreenState extends State<ChannelSeedBackupScreen> {
  bool _confirming = false;
  late final List<String> _words =
      widget.generated.mnemonic.split(RegExp(r'\s+'));
  late final List<int> _indices = _pickIndices();
  final List<TextEditingController> _controllers =
      List.generate(3, (_) => TextEditingController());
  String? _mismatch;

  List<int> _pickIndices() {
    final given = widget.confirmIndices;
    if (given != null) return List.of(given)..sort();
    final all = List<int>.generate(_words.length, (i) => i)..shuffle(Random());
    return all.take(3).toList()..sort();
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _checkWords() async {
    for (var i = 0; i < _indices.length; i++) {
      if (_controllers[i].text.trim().toLowerCase() != _words[_indices[i]]) {
        setState(() => _mismatch =
            'Word #${_indices[i] + 1} does not match — check your notes.');
        return;
      }
    }
    setState(() => _mismatch = null);
    // Words proven — the last wall before anything exists is the
    // public-permanence gate.
    final confirmed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => FirstPublishGateScreen(
          channelName: widget.channelName,
          description: widget.description,
          author: widget.author,
          avatar: widget.avatar,
          mnemonic: widget.generated.mnemonic,
          api: widget.api,
        ),
      ),
    );
    if (confirmed == true && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Text(
            _confirming ? 'Confirm backup' : 'Back up your channel',
            style: TextStyle(color: t.bone, fontSize: 18)),
      ),
      body: _confirming ? _confirmBody(t) : _wordsBody(t),
    );
  }

  Widget _wordsBody(WiTokens t) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Write these 12 words down on paper, in order. They are the '
          'only way to restore the channel on another computer — and '
          'the only way back if this one dies.',
          style: TextStyle(color: t.bone, fontSize: 14, height: 1.4),
        ),
        const SizedBox(height: 8),
        Text(
          'This phrase restores your CHANNEL, not your wallet money — '
          'keep it separately from the wallet phrase. Anyone who has it '
          'can publish as you, publicly and permanently.',
          style: TextStyle(color: t.rust, fontSize: 13, height: 1.4),
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < _words.length; i++)
              Container(
                width: 150,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: t.ink2,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: t.line),
                ),
                child: Text(
                  '${i + 1}. ${_words[i]}',
                  style: TextStyle(
                    fontFamily: wiMonoFamily,
                    fontFamilyFallback: wiMonoFallback,
                    fontSize: 13,
                    color: t.bone,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 20),
        Text(
          'Channel code: ${widget.generated.code}',
          style: TextStyle(
            fontFamily: wiMonoFamily,
            fontFamilyFallback: wiMonoFallback,
            fontSize: 11.5,
            color: t.boneDim,
          ),
        ),
        const SizedBox(height: 24),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: WiTokens.channelAmber,
            foregroundColor: Colors.black,
          ),
          onPressed: () => setState(() => _confirming = true),
          child: const Text("I've written them down"),
        ),
      ],
    );
  }

  Widget _confirmBody(WiTokens t) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Enter the requested words from your notes to prove the backup '
          'exists. The channel is created only after this step.',
          style: TextStyle(color: t.bone, fontSize: 14, height: 1.4),
        ),
        const SizedBox(height: 16),
        for (var i = 0; i < _indices.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: TextField(
              controller: _controllers[i],
              autocorrect: false,
              enableSuggestions: false,
              style: TextStyle(
                fontFamily: wiMonoFamily,
                fontFamilyFallback: wiMonoFallback,
                color: t.bone,
              ),
              decoration: InputDecoration(
                labelText: 'Word #${_indices[i] + 1}',
                labelStyle: TextStyle(color: t.ash),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
        if (_mismatch != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(_mismatch!,
                style: TextStyle(color: t.rust, fontSize: 13)),
          ),
        Row(
          children: [
            TextButton(
              onPressed: () => setState(() => _confirming = false),
              child:
                  Text('Show words again', style: TextStyle(color: t.ash)),
            ),
            const Spacer(),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: WiTokens.channelAmber,
                foregroundColor: Colors.black,
              ),
              onPressed: _checkWords,
              child: const Text('Continue'),
            ),
          ],
        ),
      ],
    );
  }
}

/// The dedicated full-screen warning before a channel exists: public,
/// permanent, attributable, you are the publisher legally. Confirmed by
/// typing the channel name — mirroring the wallet ceremony's weight.
class FirstPublishGateScreen extends StatefulWidget {
  const FirstPublishGateScreen({
    super.key,
    required this.channelName,
    required this.description,
    this.author = '',
    this.avatar,
    required this.mnemonic,
    required this.api,
  });

  final String channelName;
  final String description;

  /// Optional profile extras — the author name/handle and the avatar
  /// crop staged by the create form.
  final String author;
  final Uint8List? avatar;
  final String mnemonic;
  final ChannelsApi api;

  @override
  State<FirstPublishGateScreen> createState() =>
      _FirstPublishGateScreenState();
}

class _FirstPublishGateScreenState extends State<FirstPublishGateScreen> {
  final _typed = TextEditingController();
  bool _creating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _typed.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  bool get _nameMatches =>
      _typed.text.trim().toLowerCase() ==
      widget.channelName.trim().toLowerCase();

  Future<void> _create() async {
    if (!_nameMatches || _creating) return;
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      await widget.api.create(
        name: widget.channelName,
        description: widget.description,
        author: widget.author,
        mnemonic: widget.mnemonic,
      );
      // The avatar crop is staged best-effort — the channel exists
      // either way, and Edit channel details can retry it.
      final avatar = widget.avatar;
      if (avatar != null) {
        try {
          await ChannelService.instance.setMyAvatar(avatar);
        } catch (_) {}
      }
      // The new channel appears on the home wall (as its amber list)
      // right away, not on the next 5-minute tick.
      unawaited(ChannelService.instance.syncNow());
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _creating = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: t.ink,
        elevation: 0,
        title: Text('Before your channel exists',
            style: TextStyle(color: t.bone, fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  color: WiTokens.channelAmber, size: 30),
              SizedBox(width: 10),
              ChannelBadge(text: 'PUBLIC · PERMANENT'),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'Everything "${widget.channelName}" publishes:',
            style: TextStyle(
                color: t.bone, fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          for (final line in const [
            'is PUBLIC — anyone with the channel code can watch it, now '
                'and forever;',
            'is PERMANENT — the Autonomi network has no delete. Nothing '
                'published can ever be taken down, by you or anyone;',
            'is ATTRIBUTABLE — every publish is signed by your channel '
                'key;',
            'makes YOU the publisher, legally responsible for having '
                'the rights to distribute it.',
            'includes your channel name — and the author name and avatar '
                'if you set them — published publicly and permanently '
                'alongside everything in the channel.',
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('•  ',
                      style: TextStyle(color: WiTokens.channelAmber)),
                  Expanded(
                    child: Text(line,
                        style: TextStyle(
                            color: t.boneDim, fontSize: 13.5, height: 1.4)),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Text(
            'This is nothing like the private Upload flow. Only publish '
            'content you created yourself or hold the rights to '
            'distribute publicly.',
            style: TextStyle(
                color: WiTokens.channelAmber, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _typed,
            autocorrect: false,
            enableSuggestions: false,
            style: TextStyle(color: t.bone),
            decoration: InputDecoration(
              labelText: 'Type the channel name to confirm',
              hintText: widget.channelName,
              labelStyle: TextStyle(color: t.ash),
              hintStyle: TextStyle(color: t.line),
              border: const OutlineInputBorder(),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child:
                  Text(_error!, style: TextStyle(color: t.rust, fontSize: 13)),
            ),
          const SizedBox(height: 16),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: WiTokens.channelAmber,
              foregroundColor: Colors.black,
              disabledBackgroundColor: t.ink2,
            ),
            onPressed: _nameMatches && !_creating ? _create : null,
            child: Text(_creating
                ? 'Creating…'
                : 'I understand — create the channel'),
          ),
        ],
      ),
    );
  }
}

class _RestoreChannelDialog extends StatefulWidget {
  const _RestoreChannelDialog({required this.api});
  final ChannelsApi api;

  @override
  State<_RestoreChannelDialog> createState() => _RestoreChannelDialogState();
}

class _RestoreChannelDialogState extends State<_RestoreChannelDialog> {
  final _controller = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final restored = await widget.api.restore(text);
      if (mounted) Navigator.of(context).pop(restored);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return AlertDialog(
      backgroundColor: t.ink2,
      title: Text('Restore channel',
          style: TextStyle(color: t.bone, fontSize: 16)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Type the channel\'s 12-word recovery phrase. The same '
              'phrase always restores the same channel — same code, '
              'publishing resumes here.',
              style: TextStyle(color: t.boneDim, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              autofocus: true,
              maxLines: 3,
              autocorrect: false,
              enableSuggestions: false,
              style: TextStyle(
                fontFamily: wiMonoFamily,
                fontFamilyFallback: wiMonoFallback,
                fontSize: 13,
                color: t.bone,
              ),
              decoration: InputDecoration(
                hintText: 'twelve words separated by spaces',
                hintStyle: TextStyle(color: t.ash),
                border: const OutlineInputBorder(),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(_error!,
                    style: TextStyle(color: t.rust, fontSize: 12)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text('Cancel', style: TextStyle(color: t.ash)),
        ),
        TextButton(
          onPressed: _busy ? null : _submit,
          child: Text(_busy ? 'Restoring…' : 'Restore',
              style: const TextStyle(color: WiTokens.channelAmber)),
        ),
      ],
    );
  }
}

class _ChannelQrDialog extends StatelessWidget {
  const _ChannelQrDialog({required this.code});
  final String code;

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return AlertDialog(
      backgroundColor: t.ink2,
      title: Text('Share this code',
          style: TextStyle(color: t.bone, fontSize: 16)),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(8),
              child: WiQr(data: code, size: 220),
            ),
            const SizedBox(height: 12),
            SelectableText(
              code,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: wiMonoFamily,
                fontFamilyFallback: wiMonoFallback,
                fontSize: 11.5,
                color: WiTokens.channelAmber,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: code));
            Navigator.of(context).pop();
          },
          child: Text('Copy & close', style: TextStyle(color: t.ash)),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Add from library: picker → (describe, attestation live in the caller)
// ---------------------------------------------------------------------------

/// Pick one already-uploaded library entry for the channel (the
/// secondary path beside the file-first ChannelPublishScreen). One
/// explicit pick at a time — the "separate doors" wall means there is
/// deliberately no bulk selection and no channel toggle anywhere near
/// the Upload flow.
///
/// Two steps instead of one long flat list: pick the LIST first, then
/// browse it as the same nested tree the list editor shows — artist →
/// album → track, show → season → episode, same-title versions folded
/// — so a big library stays navigable. Tapping a leaf row returns that
/// entry.
class _PickItemDialog extends StatefulWidget {
  const _PickItemDialog({required this.lists, required this.alreadyStaged});

  final List<MediaList> lists;
  final Set<String> alreadyStaged;

  @override
  State<_PickItemDialog> createState() => _PickItemDialogState();
}

class _PickItemDialogState extends State<_PickItemDialog> {
  /// The list being browsed; null = still on the pick-a-list step.
  MediaList? _open;

  List<MediaEntry> _pickable(MediaList list) => [
        for (final e in list.entries)
          if (!widget.alreadyStaged.contains(e.address.toLowerCase())) e,
      ];

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final open = _open;
    // Channel lists are other people's content — not pickable.
    final lists = [
      for (final l in widget.lists)
        if (!l.isChannel && _pickable(l).isNotEmpty) l,
    ];
    return AlertDialog(
      backgroundColor: t.ink2,
      title: Row(
        children: [
          if (open != null)
            IconButton(
              tooltip: 'Back to lists',
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(() => _open = null),
              icon: Icon(Icons.arrow_back, color: t.boneDim, size: 20),
            ),
          Expanded(
            child: Text(open?.title ?? 'Pick an item to publish',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: t.bone, fontSize: 16)),
          ),
        ],
      ),
      content: SizedBox(
        width: 480,
        height: 380,
        child: lists.isEmpty
            ? Center(
                child: Text(
                  'Nothing to pick — upload your content first '
                  '(drawer → Upload).',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: t.boneDim, fontSize: 13),
                ),
              )
            : open == null
                ? _listStep(t, lists)
                : _treeStep(t, open),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Cancel', style: TextStyle(color: t.ash)),
        ),
      ],
    );
  }

  Widget _listStep(WiTokens t, List<MediaList> lists) => ListView(
        children: [
          for (final list in lists)
            ListTile(
              dense: true,
              leading: Icon(Icons.video_library_outlined,
                  color: t.boneDim, size: 20),
              title: Text(list.title,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.bone, fontSize: 14)),
              subtitle: Text(
                  '${_pickable(list).length} '
                  '${_pickable(list).length == 1 ? 'item' : 'items'}',
                  style: TextStyle(color: t.ash, fontSize: 11)),
              trailing:
                  Icon(Icons.chevron_right, color: t.ash, size: 18),
              onTap: () => setState(() => _open = list),
            ),
        ],
      );

  Widget _treeStep(WiTokens t, MediaList list) {
    final items = groupShows(_pickable(list));
    return ListView(
      children: [
        for (final item in items)
          switch (item) {
            HomeArtist a => _group(t, a.artist,
                '${a.albums.length} albums · ${a.trackCount} tracks', [
                for (final album in a.albums)
                  _albumTile(t, album, nested: true),
              ]),
            HomeAlbum a => _albumTile(t, a),
            HomeShow s => _group(
                t, s.show, '${s.episodeCount} episodes', [
                for (final season in s.seasons)
                  _group(
                      t,
                      'Season ${season.season}',
                      '${season.episodes.length} episodes',
                      [
                        // An episode's tier uploads each stay pickable —
                        // folded under a versions group like movies.
                        for (final e in season.episodes)
                          if (season.versionsOf(e) case final v
                              when v.length > 1)
                            _group(t, e.name, '${v.length} versions',
                                [for (final f in v) _leaf(t, f)],
                                nested: true)
                          else
                            _leaf(t, e)
                      ],
                      nested: true),
              ]),
            HomeEntry e => e.allVersions.length > 1
                ? _group(
                    t,
                    MetadataService.instance.metadataFor(e.entry).title,
                    '${e.allVersions.length} versions',
                    [for (final v in e.allVersions) _leaf(t, v)])
                : _leaf(t, e.entry),
            HomeSeason _ => const SizedBox.shrink(), // groupShows never
          },
      ],
    );
  }

  Widget _albumTile(WiTokens t, HomeAlbum a, {bool nested = false}) =>
      _group(
          t,
          a.year == null ? a.album : '${a.album} (${a.year})',
          '${a.tracks.length} tracks',
          [for (final e in a.tracks) _leaf(t, e)],
          nested: nested);

  Widget _group(WiTokens t, String title, String subtitle,
          List<Widget> children, {bool nested = false}) =>
      ExpansionTile(
        dense: true,
        shape: const Border(),
        collapsedShape: const Border(),
        tilePadding: EdgeInsets.only(left: nested ? 24 : 8, right: 8),
        childrenPadding: EdgeInsets.only(left: nested ? 16 : 8),
        iconColor: t.ash,
        collapsedIconColor: t.ash,
        title: Text(title,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: t.bone, fontSize: 14)),
        subtitle: Text(subtitle,
            style: TextStyle(color: t.ash, fontSize: 11)),
        children: children,
      );

  Widget _leaf(WiTokens t, MediaEntry entry) {
    final meta = MetadataService.instance.metadataFor(entry);
    return ListTile(
      dense: true,
      leading: Icon(Icons.movie_outlined, color: t.boneDim, size: 20),
      title: Text(meta.episodeLabel ?? meta.title,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: t.bone, fontSize: 14)),
      subtitle: Text(entry.name,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: t.ash, fontSize: 11)),
      onTap: () => Navigator.of(context).pop(entry),
    );
  }
}

/// Per-item rights attestation — required for every item, stronger than
/// the Upload flow's checkbox, because this one is public and forever.
class ChannelAttestationDialog extends StatefulWidget {
  const ChannelAttestationDialog({super.key, required this.entryName});
  final String entryName;

  @override
  State<ChannelAttestationDialog> createState() =>
      _AttestationDialogState();
}

class _AttestationDialogState extends State<ChannelAttestationDialog> {
  bool _ticked = false;

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return AlertDialog(
      backgroundColor: t.ink2,
      title: Text('Rights to publish',
          style: TextStyle(color: t.bone, fontSize: 16)),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.entryName,
                style: TextStyle(color: t.boneDim, fontSize: 12.5)),
            const SizedBox(height: 12),
            CheckboxListTile(
              value: _ticked,
              onChanged: (v) => setState(() => _ticked = v ?? false),
              activeColor: WiTokens.channelAmber,
              checkColor: Colors.black,
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              title: Text(
                'I created this content myself, or I hold the rights to '
                'distribute it publicly. I understand it will be public '
                'and permanent and can never be deleted from the '
                'network.',
                style:
                    TextStyle(color: t.bone, fontSize: 13, height: 1.4),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text('Cancel', style: TextStyle(color: t.ash)),
        ),
        TextButton(
          onPressed:
              _ticked ? () => Navigator.of(context).pop(true) : null,
          child: Text('Add to channel',
              style: TextStyle(
                  color: _ticked ? WiTokens.channelAmber : t.ash)),
        ),
      ],
    );
  }
}

/// Cost preview before a manifest publish (open question #4 — answered
/// yes: reuse the live estimate + wallet balance).
class _CostPreviewDialog extends StatefulWidget {
  const _CostPreviewDialog({
    required this.api,
    required this.build,
    required this.firstPublish,
  });

  final PublishApi api;
  final ChannelManifestBuild build;
  final bool firstPublish;

  @override
  State<_CostPreviewDialog> createState() => _CostPreviewDialogState();
}

class _CostPreviewDialogState extends State<_CostPreviewDialog> {
  UploadEstimate? _estimate;
  WalletBalances? _balances;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final estimate = await widget.api.estimate(widget.build.path);
      WalletBalances? balances;
      try {
        balances = await widget.api.balances();
      } catch (_) {
        // Balance display is best-effort; the publish itself fails
        // cleanly on an underfunded wallet.
      }
      if (!mounted) return;
      setState(() {
        _estimate = estimate;
        _balances = balances;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final estimate = _estimate;
    final balances = _balances;
    final insufficient = estimate != null &&
        balances != null &&
        balances.antAtto < estimate.costAtto;
    return AlertDialog(
      backgroundColor: t.ink2,
      title: Text('Publish to the network?',
          style: TextStyle(color: t.bone, fontSize: 16)),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'The channel manifest '
              '(${formatBytes(widget.build.bytes)}, '
              '${widget.build.entriesIncluded} items) is uploaded '
              'publicly and the new version announced to subscribers.',
              style: TextStyle(color: t.boneDim, fontSize: 13, height: 1.4),
            ),
            if (widget.build.entriesMissingMap > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '${widget.build.entriesMissingMap} item(s) were left '
                  'out — their data maps are missing locally.',
                  style: TextStyle(color: t.rust, fontSize: 12),
                ),
              ),
            const SizedBox(height: 12),
            if (_error != null)
              Text('Estimate failed: $_error',
                  style: TextStyle(color: t.rust, fontSize: 12.5))
            else if (estimate == null)
              Row(children: [
                const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 10),
                Text('Fetching live cost estimate…',
                    style: TextStyle(color: t.ash, fontSize: 12.5)),
              ])
            else ...[
              Text(
                'Estimated cost: ≈${formatUnits(estimate.costAtto)} ANT '
                '(${estimate.chunkCount} chunks)'
                '${estimate.alreadyStored ? ' — already stored, free' : ''}',
                style: TextStyle(color: t.bone, fontSize: 13.5),
              ),
              if (balances != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Wallet balance: ${formatUnits(balances.antAtto)} ANT',
                    style: TextStyle(
                        color: insufficient ? t.rust : t.ash, fontSize: 12),
                  ),
                ),
              if (insufficient)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'The wallet balance looks too low for this publish — '
                    'top it up in Settings → Wallet first.',
                    style: TextStyle(color: t.rust, fontSize: 12),
                  ),
                ),
            ],
            const SizedBox(height: 12),
            Text(
              widget.firstPublish
                  ? 'This is the channel\'s FIRST publish: from here on '
                      'its content is public and permanent.'
                  : 'Public and permanent — old versions stay on the '
                      'network forever.',
              style: const TextStyle(
                  color: WiTokens.channelAmber, fontSize: 12.5, height: 1.4),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text('Cancel', style: TextStyle(color: t.ash)),
        ),
        TextButton(
          onPressed: estimate == null
              ? null
              : () => Navigator.of(context).pop(true),
          child: const Text('Publish · public & permanent',
              style: TextStyle(color: WiTokens.channelAmber)),
        ),
      ],
    );
  }
}

/// Follows the publish job (encrypting → quoting → paying → storing →
/// announcing) and pops with the [UploadResult] — or, after a failure,
/// with [retry] when the user chooses to try again.
class _PublishProgressDialog extends StatefulWidget {
  const _PublishProgressDialog({required this.api, required this.id});
  final PublishApi api;
  final int id;

  /// Sentinel pop value: restart the publish with the same manifest.
  static const retry = 'retry';

  @override
  State<_PublishProgressDialog> createState() =>
      _PublishProgressDialogState();
}

class _PublishProgressDialogState extends State<_PublishProgressDialog> {
  UploadJob? _job;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _tick() async {
    try {
      final job = await widget.api.jobStatus(widget.id);
      if (!mounted) return;
      setState(() => _job = job);
      if (job.phase == 'done') {
        _timer?.cancel();
        Navigator.of(context).pop(job.result);
      } else if (job.phase == 'error') {
        _timer?.cancel();
      }
    } catch (_) {
      // Transient; next tick retries.
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final job = _job;
    final label = switch (job?.phase) {
      null || 'starting' => 'Starting…',
      'encrypting' => 'Encrypting manifest…',
      'quoting' => 'Fetching storage quotes…',
      'paying' => 'Paying for storage…',
      'storing' => 'Storing on the network '
          '(${job!.done}/${job.total} chunks)…',
      'announcing' => 'Announcing the new version to subscribers…',
      'error' => 'Publish failed',
      _ => job!.phase,
    };
    return AlertDialog(
      backgroundColor: t.ink2,
      title: Text('Publishing', style: TextStyle(color: t.bone, fontSize: 16)),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (job?.phase != 'error')
                  const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                if (job?.phase != 'error') const SizedBox(width: 10),
                Expanded(
                  child: Text(label,
                      style: TextStyle(color: t.bone, fontSize: 13.5)),
                ),
              ],
            ),
            if (job?.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(job!.error!,
                    style: TextStyle(color: t.rust, fontSize: 12.5)),
              ),
          ],
        ),
      ),
      actions: [
        if (job?.phase == 'error') ...[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Close', style: TextStyle(color: t.ash)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: WiTokens.channelAmber,
              foregroundColor: Colors.black,
            ),
            onPressed: () =>
                Navigator.of(context).pop(_PublishProgressDialog.retry),
            child: const Text('Try again'),
          ),
        ],
      ],
    );
  }
}
