import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/library_store.dart';
import '../services/my_watch_api.dart';
import '../theme/tokens.dart';

/// My W@tch: link this device with your other devices (test
/// implementation — linking + per-device status only; watch-list sync
/// rides the same channel later).
///
/// Unlinked, the page offers "create a link" (mints the invite, shows it
/// as QR + copyable code) or "join with a code" (paste the invite from
/// another device). Linked, it shows every device on the link with
/// online/last-heard/library info, the last-sync stamp, the invite for
/// adding more devices, and unlink.
class MyWatchScreen extends StatefulWidget {
  const MyWatchScreen({super.key, this.apiBase, this.apiToken});

  /// Test overrides for the embedded server base URL / auth token.
  final String? apiBase;
  final String? apiToken;

  @override
  State<MyWatchScreen> createState() => _MyWatchScreenState();
}

class _MyWatchScreenState extends State<MyWatchScreen> {
  late final MyWatchApi _api =
      MyWatchApi(base: widget.apiBase, token: widget.apiToken);

  MyWatchStatus? _status;
  String? _error;
  bool _busy = false;
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    _load(announce: true);
    // Records change on other devices' heartbeats; keep the view live
    // while the page is open.
    _refresh = Timer.periodic(
        const Duration(seconds: 5), (_) => _load(quiet: true));
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  Future<void> _load({bool announce = false, bool quiet = false}) async {
    if (!quiet) setState(() => _error = null);
    try {
      if (announce) await _announceLibrary();
      final status = await _api.status();
      // Unchanged snapshot on a background refresh → no rebuild (also
      // lets widget tests settle despite the periodic timer).
      if (mounted && status.raw != _status?.raw) {
        setState(() => _status = status);
      }
    } catch (e) {
      if (mounted && !quiet) setState(() => _error = '$e');
    }
  }

  /// Push this device's library summary into its record so the other
  /// devices' screens show real counts.
  Future<void> _announceLibrary() async {
    try {
      final lists = await LibraryStore.load();
      final entries = lists.fold<int>(0, (n, l) => n + l.entries.length);
      await _api.announce(lists: lists.length, entries: entries);
    } on MyWatchApiException {
      // Not linked yet (or unsupported) — nothing to announce.
    }
  }

  String _defaultDeviceName() {
    try {
      final host = Platform.localHostname.trim();
      if (host.isNotEmpty && host != 'localhost') return host;
    } catch (_) {}
    return 'My ${Platform.operatingSystem} device';
  }

  Future<void> _runBusy(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
      // Quiet: a full reload would wipe the error just shown.
      await _load(quiet: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createLink() async {
    final name = await _askDeviceName('Name this device');
    if (name == null) return;
    await _runBusy(() async {
      final invite = await _api.createLink(name);
      await _announceLibrary();
      if (mounted) await _showInvite(invite, fresh: true);
    });
  }

  Future<void> _joinLink() async {
    final result = await _askJoinDetails();
    if (result == null) return;
    await _runBusy(() async {
      await _api.joinLink(result.$1, result.$2);
      await _announceLibrary();
    });
  }

  Future<void> _showExistingInvite() async {
    await _runBusy(() async {
      final invite = await _api.invite();
      if (mounted) await _showInvite(invite, fresh: false);
    });
  }

  Future<void> _unlink() async {
    final t = WiTokens.of(context);
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unlink this device?'),
        content: const Text(
            'This device leaves the link and forgets its secret. Your '
            'other devices stay linked to each other. You can join '
            'again later with a fresh invite from one of them.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: t.rust),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Unlink'),
          ),
        ],
      ),
    );
    if (sure != true) return;
    await _runBusy(() => _api.unlink());
  }

  Future<String?> _askDeviceName(String title) async {
    final controller = TextEditingController(text: _defaultDeviceName());
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 48,
          decoration: const InputDecoration(
            labelText: 'Device name',
            helperText: 'How this device appears on your other devices',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return null;
    return name;
  }

  Future<(String, String)?> _askJoinDetails() async {
    final nameController = TextEditingController(text: _defaultDeviceName());
    final inviteController = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Join with invite code'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              maxLength: 48,
              decoration: const InputDecoration(labelText: 'Device name'),
            ),
            TextField(
              controller: inviteController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Invite code',
                helperText: 'Shown under the QR code on the linked device '
                    '(starts with wtch1-)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Join'),
          ),
        ],
      ),
    );
    if (ok != true) return null;
    final name = nameController.text.trim();
    final invite = inviteController.text.trim();
    if (name.isEmpty || invite.isEmpty) return null;
    return (name, invite);
  }

  Future<void> _showInvite(String invite, {required bool fresh}) async {
    final t = WiTokens.of(context);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(fresh ? 'Link created' : 'Add another device'),
        content: SizedBox(
          width: 300,
          child: SingleChildScrollView(
              child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'On your other device, open My W@tch and choose "Join '
                'with invite code" — scan or copy this. Anyone with '
                'this code can join your link, so share it only with '
                'your own devices.',
                style: TextStyle(fontSize: 13, color: t.boneDim),
              ),
              const SizedBox(height: 16),
              Container(
                color: Colors.white,
                padding: const EdgeInsets.all(8),
                child: QrImageView(
                  data: invite,
                  version: QrVersions.auto,
                  size: 200,
                ),
              ),
              const SizedBox(height: 12),
              SelectableText(
                invite,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ],
          )),
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy code'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: invite));
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Invite code copied')));
            },
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  static String relativeTime(int? ms) {
    if (ms == null) return 'never';
    final delta = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (delta.inSeconds < 60) return 'just now';
    if (delta.inMinutes < 60) {
      return '${delta.inMinutes} min ago';
    }
    if (delta.inHours < 48) return '${delta.inHours} h ago';
    return '${delta.inDays} days ago';
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final status = _status;
    return Scaffold(
      appBar: AppBar(title: const Text('My W@tch')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(_error!,
                  style: TextStyle(color: t.rust, fontSize: 13)),
            ),
          if (status == null && _error == null)
            const Center(
                child: Padding(
              padding: EdgeInsets.all(32),
              child: CircularProgressIndicator(),
            ))
          else if (status != null && !status.supported)
            Text(
              'My W@tch is not available on this platform yet — link '
              'from a desktop W@tch for now.',
              style: TextStyle(color: t.boneDim),
            )
          else if (status != null && !status.linked)
            ..._unlinkedBody(t)
          else if (status != null)
            ..._linkedBody(t, status),
        ],
      ),
    );
  }

  List<Widget> _unlinkedBody(WiTokens t) {
    return [
      Text(
        'Link your own devices — desktop and, later, phone — into a '
        'private "My W@tch". Linked devices find each other over the '
        'network (or the local Wi-Fi), see each other\'s status, and '
        'will keep watch lists and viewing positions in sync in a '
        'future release.',
        style: TextStyle(fontSize: 14, color: t.boneDim, height: 1.4),
      ),
      const SizedBox(height: 8),
      Text(
        'Test feature: for now, linking shares device presence and '
        'library counts only.',
        style: TextStyle(fontSize: 12, color: t.ash),
      ),
      const SizedBox(height: 20),
      FilledButton.icon(
        icon: const Icon(Icons.add_link),
        label: const Text('Create a link on this device'),
        onPressed: _busy ? null : _createLink,
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        icon: const Icon(Icons.qr_code_scanner),
        label: const Text('Join with invite code'),
        onPressed: _busy ? null : _joinLink,
      ),
    ];
  }

  List<Widget> _linkedBody(WiTokens t, MyWatchStatus status) {
    final starting = status.state != 'ready';
    return [
      // State banner while the agent is still coming up (or retrying).
      if (starting)
        Card(
          color: t.ink2,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    status.message == null
                        ? 'Connecting to your devices…'
                        : 'Connecting to your devices… (${status.message})',
                    style: TextStyle(fontSize: 13, color: t.boneDim),
                  ),
                ),
              ],
            ),
          ),
        ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.sync, color: t.accent),
        title: const Text('Last sync'),
        subtitle: Text(
          status.lastSyncMs == null
              ? 'Nothing received from your other devices yet'
              : relativeTime(status.lastSyncMs),
          style: TextStyle(color: t.boneDim),
        ),
      ),
      if (status.linkedSinceMs != null && status.linkedSinceMs != 0)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.link, color: t.boneDim),
          title: const Text('Linked since'),
          subtitle: Text(
            DateTime.fromMillisecondsSinceEpoch(status.linkedSinceMs!)
                .toLocal()
                .toString()
                .split('.')
                .first,
            style: TextStyle(color: t.boneDim),
          ),
        ),
      const SizedBox(height: 8),
      Text(
        'DEVICES',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
          color: t.ash,
        ),
      ),
      const SizedBox(height: 4),
      if (status.devices.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            starting
                ? 'Device records appear once the connection is up.'
                : 'Only this device so far — add another with the '
                    'invite below.',
            style: TextStyle(fontSize: 13, color: t.boneDim),
          ),
        )
      else
        for (final device in status.devices) _deviceTile(t, device),
      const SizedBox(height: 16),
      OutlinedButton.icon(
        icon: const Icon(Icons.qr_code),
        label: const Text('Show invite (add a device)'),
        onPressed: _busy ? null : _showExistingInvite,
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(foregroundColor: t.rust),
        icon: const Icon(Icons.link_off),
        label: const Text('Unlink this device'),
        onPressed: _busy ? null : _unlink,
      ),
      const SizedBox(height: 16),
      if (status.agentId != null)
        Text(
          'This device\'s address: ${status.agentId!.substring(0, 16)}…',
          style: TextStyle(
              fontSize: 11, color: t.ash, fontFamily: 'monospace'),
        ),
    ];
  }

  Widget _deviceTile(WiTokens t, MyWatchDevice device) {
    final subtitle = device.isSelf
        ? '${device.platform} · this device · '
            '${device.lists} lists · ${device.entries} items'
        : '${device.platform} · last heard ${relativeTime(device.updatedAtMs)}'
            ' · ${device.lists} lists · ${device.entries} items';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        device.platform == 'android' || device.platform == 'ios'
            ? Icons.smartphone
            : Icons.computer,
        color: device.online ? t.accent : t.boneDim,
      ),
      title: Row(
        children: [
          Flexible(child: Text(device.name)),
          const SizedBox(width: 8),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: device.online ? t.signalOk : t.ash,
            ),
          ),
        ],
      ),
      subtitle: Text(subtitle, style: TextStyle(color: t.boneDim)),
    );
  }
}
