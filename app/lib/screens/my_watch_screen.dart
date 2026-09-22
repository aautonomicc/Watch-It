import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import '../widgets/wi_qr.dart';
import '../widgets/device_name_dialog.dart';
import '../widgets/join_link_dialog.dart';
import '../widgets/pair_dialogs.dart';
import '../widgets/tv_dpad_focus.dart';
import '../services/tv_settings.dart';

import '../services/library_store.dart';
import '../services/my_watch_api.dart';
import '../services/my_watch_sync.dart';
import '../services/x0x_cellular.dart';
import '../theme/tokens.dart';
import 'qr_scan_screen.dart';

/// My W@tch: link this device with your other devices. Linked devices
/// sync watch lists and viewing positions automatically in the
/// background ([MyWatchSync]) and show each other's presence here.
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

  /// Linked devices seen online at the previous poll — the flip
  /// detector below compares against it.
  Set<String>? _prevOnline;

  Future<void> _load({bool announce = false, bool quiet = false}) async {
    if (!quiet) setState(() => _error = null);
    try {
      if (announce) await _announceLibrary();
      final status = await _api.status();
      _noteOnlineFlips(status);
      // Unchanged snapshot on a background refresh → no rebuild (also
      // lets widget tests settle despite the periodic timer).
      if (mounted && status.raw != _status?.raw) {
        setState(() => _status = status);
      }
    } catch (e) {
      if (mounted && !quiet) setState(() => _error = '$e');
    }
  }

  /// While this page polls (every 5s), a linked device flipping to
  /// online triggers an immediate sync cycle — the user staring at both
  /// screens should see them converge now, not after the background
  /// period runs out.
  void _noteOnlineFlips(MyWatchStatus status) {
    final online = <String>{
      for (final d in status.devices)
        if (!d.isSelf && d.online) d.agentId,
    };
    final prev = _prevOnline;
    _prevOnline = online;
    if (!status.linked || prev == null) return;
    if (online.difference(prev).isNotEmpty) {
      MyWatchSync.instance.deviceCameOnline();
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

  /// Camera platforms only — TVs and desktops have no camera, so a
  /// scan button would be dead weight there.
  bool get _canScan =>
      (Platform.isAndroid || Platform.isIOS) && !TvSettings.instance.enabled;

  /// Reverse-QR pairing, unlinked side: show a pairing code for a
  /// linked phone to scan — the path for devices with a screen but no
  /// camera (TVs, desktops). Joins the EXISTING link on success.
  Future<void> _pairStart() async {
    final name = await _askDeviceName('Name this device');
    if (name == null) return;
    await _runBusy(() async {
      final code = await _api.pairStart(name);
      if (!mounted) return;
      final linked = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PairCodeDialog(api: _api, code: code),
      );
      if (linked == true && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content:
                Text('Linked! Syncing with your other devices starts now.')));
      }
    });
  }

  /// Reverse-QR pairing, linked side: scan the code a new device is
  /// showing and send it the link.
  Future<void> _pairSend() async {
    final code = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => QrScanScreen(
          title: 'Scan pairing code',
          hint: 'Point the camera at the pairing code shown on the '
              'new device (My W@tch → "Show a pairing code")',
          accept: (v) => v.trim().toLowerCase().startsWith('wtchp1-'),
        ),
      ),
    );
    if (code == null) return;
    await _runBusy(() async {
      await _api.pairSend(code.trim().toLowerCase());
      if (!mounted) return;
      final delivered = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PairSendDialog(api: _api),
      );
      if (delivered == true && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Link sent — the new device is joining now.')));
      }
    });
  }

  Future<void> _syncNow() async {
    await _runBusy(() async {
      final summary = await MyWatchSync.instance.syncNow();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(summary)));
      }
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
    final name = await showDialog<String>(
      context: context,
      builder: (_) =>
          DeviceNameDialog(title: title, initialName: _defaultDeviceName()),
    );
    if (name == null || name.isEmpty) return null;
    return name;
  }

  Future<(String, String)?> _askJoinDetails() async {
    // Phones scan the desktop's QR instead of typing 70 chars.
    final canScan = _canScan;
    return showDialog<(String, String)>(
      context: context,
      builder: (_) => JoinLinkDialog(
        initialName: _defaultDeviceName(),
        onScanQr: !canScan
            ? null
            : () => Navigator.of(context).push<String>(
                  MaterialPageRoute(
                    builder: (_) => QrScanScreen(
                      title: 'Scan invite',
                      hint: 'Point the camera at the QR code shown on '
                          'your linked device',
                      accept: (v) =>
                          v.trim().toLowerCase().startsWith('wtch1-'),
                    ),
                  ),
                ),
      ),
    );
  }

  Future<void> _showInvite(String invite, {required bool fresh}) async {
    final t = WiTokens.of(context);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(fresh ? 'Link created' : 'Add another device'),
        content: SizedBox(
          width: wiQrDialogWidth(context),
          // No scroll view: a D-pad can't scroll one, so on a small TV
          // viewport the QR bottom cropped away — it shrinks to fit
          // instead (WiQrCard).
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'On your other device, open My W@tch and choose "Enter '
                'an invite code" — scan or copy this. Anyone with '
                'this code can join your link, so share it only with '
                'your own devices.',
                style: TextStyle(fontSize: 13, color: t.boneDim),
              ),
              const SizedBox(height: 16),
              Flexible(child: WiQrCard(data: invite, size: 200)),
              const SizedBox(height: 12),
              SelectableText(
                invite,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ],
          ),
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
    // TvInitialFocus: on TV the screen opens with a visible focus ring
    // instead of a dark screen the D-pad has to hunt across.
    return TvInitialFocus(
        child: Scaffold(
      appBar: AppBar(title: const Text('My W@tch')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        // TV: lay the whole (short) list out — D-pad scrolling advances
        // by focus, and a lazy list stops laying out rows past its
        // cache (the Settings ABOUT fix, same class here).
        scrollCacheExtent: TvSettings.instance.enabled
            ? const ScrollCacheExtent.pixels(kTvListCacheExtent)
            : null,
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
    ));
  }

  /// The three unlinked actions grouped by the user's SITUATION, not the
  /// mechanism: starting fresh vs adding this device to an existing My
  /// W@tch. The two join transports (invite code, pairing code) sit under
  /// one header so they read as one choice, and the platform decides
  /// which of them leads: a phone types/scans an invite, a TV or desktop
  /// (screen, no camera) shows a pairing code for a linked phone to scan
  /// — that path is the primary button there, and starting a NEW My
  /// W@tch (the classic mis-tap that forks a second group) drops to
  /// outlined.
  List<Widget> _unlinkedBody(WiTokens t) {
    final canScan = _canScan;
    Widget header(String text) => Text(
          text,
          style: TextStyle(
              fontSize: 13, fontWeight: FontWeight.w700, color: t.bone),
        );
    final startLabel = const Text('Start a new My W@tch');
    const startIcon = Icon(Icons.add_link);
    final start = canScan
        ? FilledButton.icon(
            icon: startIcon,
            label: startLabel,
            onPressed: _busy ? null : _createLink,
          )
        : OutlinedButton.icon(
            icon: startIcon,
            label: startLabel,
            onPressed: _busy ? null : _createLink,
          );
    final joinLabel = const Text('Enter an invite code (from a linked device)');
    final join = OutlinedButton.icon(
      // A scan lives inside this flow only where a camera exists;
      // elsewhere the invite is typed or pasted.
      icon: Icon(canScan ? Icons.qr_code_scanner : Icons.keyboard),
      label: joinLabel,
      onPressed: _busy ? null : _joinLink,
    );
    final pairLabel =
        const Text('Show a pairing code (scan it with a linked phone)');
    const pairIcon = Icon(Icons.qr_code_2);
    final pair = canScan
        ? OutlinedButton.icon(
            icon: pairIcon,
            label: pairLabel,
            onPressed: _busy ? null : _pairStart,
          )
        : FilledButton.icon(
            icon: pairIcon,
            label: pairLabel,
            onPressed: _busy ? null : _pairStart,
          );
    return [
      Text(
        'Link your own devices into a private "My W@tch". Linked '
        'devices find each other over the network (or the local '
        'Wi-Fi) and keep your watch lists and viewing positions in '
        'sync automatically.',
        style: TextStyle(fontSize: 14, color: t.boneDim, height: 1.4),
      ),
      const SizedBox(height: 8),
      Text(
        'Adding or removing a title, or watching part of something, '
        'shows up on your other devices within a minute or so.',
        style: TextStyle(fontSize: 12, color: t.ash),
      ),
      const SizedBox(height: 20),
      header('Setting up your first device?'),
      const SizedBox(height: 8),
      start,
      const SizedBox(height: 6),
      Text(
        'Already using My W@tch on another device? Add this device '
        'below instead — starting new here would make a separate My '
        'W@tch.',
        style: TextStyle(fontSize: 12, color: t.ash),
      ),
      const SizedBox(height: 20),
      header('Already have a My W@tch?'),
      const SizedBox(height: 8),
      if (canScan) ...[
        join,
        const SizedBox(height: 12),
        pair,
      ] else ...[
        pair,
        const SizedBox(height: 12),
        join,
      ],
      const SizedBox(height: 6),
      Text(
        'Either way this device joins your existing My W@tch — the '
        'pairing code needs no typing: a phone that is already linked '
        'scans this screen.',
        style: TextStyle(fontSize: 12, color: t.ash),
      ),
    ];
  }

  List<Widget> _linkedBody(WiTokens t, MyWatchStatus status) {
    final starting = status.state != 'ready';
    return [
      // Switched off in Settings: nothing is coming up — say so instead
      // of showing the connecting spinner forever.
      if (!status.enabled)
        Card(
          color: t.ink2,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(Icons.power_settings_new, size: 18, color: t.ash),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    X0xCellularGate.instance.isPaused(X0xAgent.myWatch)
                        ? 'My W@tch is paused while on mobile data — '
                            'sync resumes on Wi-Fi (change this under '
                            'Settings → Network → Data).'
                        : 'My W@tch is switched off — nothing syncs '
                            'until you turn it back on in Settings → '
                            'Network → Data.',
                    style: TextStyle(fontSize: 13, color: t.boneDim),
                  ),
                ),
              ],
            ),
          ),
        )
      // State banner while the agent is still coming up (or retrying).
      else if (starting)
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
        // Tappable so the row is FOCUSABLE (the Settings version-row
        // pattern): with nothing focusable above the bottom buttons, a
        // TV D-pad could never scroll this page back up. The tap
        // itself refreshes the view.
        onTap: () => _load(),
      ),
      // Live activity: what the background cycle is doing right now,
      // then the last cycle's outcome and anything that went wrong.
      ValueListenableBuilder<MyWatchSyncStatus>(
        valueListenable: MyWatchSync.status,
        builder: (context, s, _) => _syncActivityCard(t, s),
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
          // Focusable stepping stone for the TV D-pad; the tap copies
          // the date for a bug report.
          onTap: () => _copyLine(
            DateTime.fromMillisecondsSinceEpoch(status.linkedSinceMs!)
                .toLocal()
                .toString(),
            'Linked-since date copied',
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
        // Doc ages come from the sync service's notifier, so the tiles
        // refresh when a cycle sees fresher data.
        ValueListenableBuilder<MyWatchSyncStatus>(
          valueListenable: MyWatchSync.status,
          builder: (context, s, _) => Column(
            children: [
              for (final device in status.devices)
                _deviceTile(t, device, s.docMsByAgent[device.agentId]),
            ],
          ),
        ),
      const SizedBox(height: 16),
      OutlinedButton.icon(
        icon: const Icon(Icons.sync),
        label: const Text('Sync now'),
        onPressed: _busy || starting ? null : _syncNow,
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        icon: const Icon(Icons.qr_code),
        label: const Text('Add a device — show invite code'),
        onPressed: _busy ? null : _showExistingInvite,
      ),
      // Reverse-QR pairing: the new device shows a code, this device's
      // camera scans it — for adding TVs/desktops, which cannot scan
      // the invite themselves.
      if (_canScan) ...[
        const SizedBox(height: 12),
        OutlinedButton.icon(
          icon: const Icon(Icons.qr_code_scanner),
          label: const Text('Add a device — scan its pairing code'),
          onPressed: _busy || starting ? null : _pairSend,
        ),
      ],
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

  /// Copy [text] to the clipboard and confirm with [note] — the useful
  /// tap for the info rows (and what makes them focusable on TV).
  Future<void> _copyLine(String text, String note) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: text));
    messenger.showSnackBar(SnackBar(content: Text(note)));
  }

  /// The full sync report as plain text — for pasting into a bug
  /// report.
  static String syncReportText(MyWatchSyncStatus s) => [
        s.syncing
            ? (s.activity ?? 'Syncing…')
            : (s.lastSummary ?? 'Waiting for the first sync cycle…'),
        if (!s.syncing && s.lastCycleAtMs != null)
          'Checked ${relativeTime(s.lastCycleAtMs)}',
        if (s.pendingMaps > 0) '${s.pendingMaps} data map(s) pending',
        if (s.pendingArt > 0) '${s.pendingArt} artwork file(s) pending',
        ...s.problems,
      ].join('\n');

  /// The sync progress card: a spinner + stage while a cycle runs, the
  /// last outcome with its time while idle, and every problem the last
  /// cycle hit (edits that did not fit the document, artwork that could
  /// not be fetched, publish failures) — sync trouble used to be
  /// invisible outside the debug log. Tappable (focusable on TV, where
  /// this page otherwise could not scroll back up); the tap copies the
  /// report for a bug report.
  Widget _syncActivityCard(WiTokens t, MyWatchSyncStatus s) {
    final headline = s.syncing
        ? (s.activity ?? 'Syncing…')
        : (s.lastSummary ?? 'Waiting for the first sync cycle…');
    return Card(
      color: t.ink2,
      margin: const EdgeInsets.symmetric(vertical: 8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _copyLine(syncReportText(s), 'Sync report copied'),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (s.syncing)
                    const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                  else
                    Icon(
                      s.problems.isEmpty &&
                              s.pendingMaps == 0 &&
                              s.pendingArt == 0
                          ? Icons.check_circle_outline
                          : Icons.warning_amber_outlined,
                      size: 16,
                      color: s.problems.isNotEmpty
                          ? t.rust
                          : s.pendingMaps > 0 || s.pendingArt > 0
                              ? WiTokens.channelAmber
                              : t.signalOk,
                    ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(headline,
                        style: TextStyle(fontSize: 13, color: t.bone)),
                  ),
                ],
              ),
              if (!s.syncing && s.lastCycleAtMs != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4, left: 24),
                  child: Text(
                    'Checked ${relativeTime(s.lastCycleAtMs)}',
                    style: TextStyle(fontSize: 11.5, color: t.ash),
                  ),
                ),
              // Maps the library needs but this device could not fetch
              // yet (usually a connection hiccup) — without this line
              // the card says "Everything is in sync." while a title
              // cannot play.
              if (s.pendingMaps > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 6, left: 24),
                  child: Text(
                    '${s.pendingMaps} data map(s) pending — those titles '
                    "can't play on this device yet. Retrying automatically; "
                    'Sync now retries immediately.',
                    style: const TextStyle(
                        fontSize: 11.5, color: WiTokens.channelAmber),
                  ),
                ),
              // Same honesty for artwork still on its way — the
              // tester's "nothing to sync while artwork was pending".
              if (s.pendingArt > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 6, left: 24),
                  child: Text(
                    '${s.pendingArt} artwork file(s) still arriving — '
                    'retrying automatically; Sync now retries immediately.',
                    style: const TextStyle(
                        fontSize: 11.5, color: WiTokens.channelAmber),
                  ),
                ),
              for (final p in s.problems)
                Padding(
                  padding: const EdgeInsets.only(top: 6, left: 24),
                  child:
                      Text(p, style: TextStyle(fontSize: 11.5, color: t.rust)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _deviceTile(WiTokens t, MyWatchDevice device, int? docMs) {
    final subtitle = device.isSelf
        ? '${device.platform} · this device · '
            '${device.lists} lists · ${device.entries} items'
        : '${device.platform} · last heard ${relativeTime(device.updatedAtMs)}'
            ' · ${device.lists} lists · ${device.entries} items';
    // The green dot only proves the device's heartbeat; the doc line
    // says how fresh its SHARED DATA is — the two can disagree (online
    // but its library never reached us), which the dot alone hid.
    final docLine =
        device.isSelf || docMs == null ? null : relativeTime(docMs);
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
      subtitle: Text(
        docLine == null ? subtitle : '$subtitle\nSync data updated $docLine',
        style: TextStyle(color: t.boneDim),
      ),
      // Tappable so the row is FOCUSABLE on TV (scroll-back stepping
      // stone); the tap copies the device line for a bug report.
      onTap: () => _copyLine(
        '${device.name} · $subtitle'
        '${docLine == null ? '' : ' · sync data updated $docLine'}',
        'Device info copied',
      ),
    );
  }
}
