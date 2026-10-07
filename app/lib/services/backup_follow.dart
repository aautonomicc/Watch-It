import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'app_settings.dart';
import 'backup.dart';
import 'embedded_client.dart';
import 'my_watch_api.dart';

/// Phase 2 of the seed-phrase backup: shared read keys over My W@tch.
///
/// The wallet-holding device (the "master") publishes its DERIVED backup
/// read keys — the pointer address to poll plus the content key, never
/// the wallet key or the 12 words — as a tiny `backup` section in its
/// My W@tch sync document inside the link store. NOTE: the store is
/// plaintext on the gossip layer today — sealing every store value
/// under a link-secret-derived key is planned
/// (docs/PLAN-mywatch-store-encryption.md); until that ships, these
/// read keys share the store's exposure to payload-capturing relays.
/// Every linked device adopts the newest shared keys and
/// polls the pointer directly from the network: reading is free (no
/// wallet needed), so a device that was offline while the others synced
/// catches up from the backup instead of waiting to be online together.
/// A fetched backup folds in through the exact restore merge — LWW
/// everywhere, deletions via the master's tombstones, never regressing
/// newer local state.
///
/// This service plays both roles:
///  * master — supplies the `backup` section for the sync doc
///    ([sectionForPublish]) and, when the user opts in, runs a debounced
///    daily automatic backup ([maybeAutoBackup]) so followers see fresh
///    state (freshness was phase 2's recorded design item: followers
///    only ever see the master's LAST backup);
///  * follower — adopts keys out of remote docs ([noteRemoteDocs]) and
///    checks the pointer on a slow cadence ([checkNow]): one free
///    pointer read per poll, a full fetch only when the head moved.
///
/// Deliberately NOT here (recorded limits): keys do not rotate on
/// unlink — rotation would re-encrypt every object (a full re-upload)
/// while the removed device keeps the old keys anyway; replacing the
/// wallet starts a new backup line and is the honest lever. The reverse
/// direction (follower state back to the master) still rides the live
/// gossip sync, unchanged.
class BackupFollowService {
  BackupFollowService({
    BackupApi? api,
    this._backup,
    Future<ClientHealth> Function()? health,
  })  : _api = api ?? BackupApi(),
        _health = health ?? EmbeddedClient.health;

  static BackupFollowService instance = BackupFollowService();

  final BackupApi _api;
  final BackupService? _backup;
  final Future<ClientHealth> Function() _health;

  BackupService get _backupService => _backup ?? BackupService.instance;

  /// For tests: pins the persisted state file somewhere writable.
  @visibleForTesting
  static String? statePathOverride;

  /// Live view for the Backup screen's follower card.
  static final ValueNotifier<BackupFollowStatus> status =
      ValueNotifier(const BackupFollowStatus());

  /// How often the follower polls the pointer (plus once shortly after
  /// launch, plus immediately when a linked device advertises a newer
  /// backup). Each poll of a quiet line costs one free pointer read —
  /// cheap enough to stay well inside the idle-data budget.
  static const pollInterval = Duration(hours: 6);

  /// First check after launch, once the client has had time to connect.
  static const firstCheckDelay = Duration(minutes: 3);

  /// An automatic backup never runs sooner than this after the last one
  /// (manual or automatic) — "once a day", with slack so a slightly
  /// early timer tick does not skip a whole period.
  static const autoMinIntervalMs = 20 * 3600 * 1000;

  Timer? _timer;
  bool _checking = false;

  /// Start the slow background cadence (called once from main).
  void start() {
    _timer ??= Timer.periodic(pollInterval, (_) => _tick());
    Timer(firstCheckDelay, _tick);
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _tick() {
    unawaited(() async {
      try {
        await maybeAutoBackup();
      } catch (e) {
        debugPrint('backup follow: auto backup failed: $e');
      }
      try {
        await checkNow();
      } catch (e) {
        debugPrint('backup follow: check failed: $e');
      }
    }());
  }

  // ---- master role -------------------------------------------------------

  /// The `backup` sync-doc section this device publishes: its shared
  /// read keys plus the last backup's stamp and counter. Null (nothing
  /// published) until this device has a wallet AND has backed up at
  /// least once — keys to an empty backup line help nobody.
  Future<Map<String, dynamic>?> sectionForPublish() async {
    try {
      final s = await _api.status();
      final ptr = s.pointer;
      final key = s.key;
      final last = s.last;
      if (!s.configured || ptr == null || key == null || last == null) {
        return null;
      }
      return {
        'v': 1,
        'ptr': ptr,
        'key': key,
        'ms': last.ms,
        'n': last.backups,
      };
    } catch (_) {
      // The embedded client not answering must never break a sync cycle.
      return null;
    }
  }

  /// Run a debounced automatic backup when the user opted in, the last
  /// backup is at least [autoMinIntervalMs] old, and the state actually
  /// changed since the last published payload (an unchanged state would
  /// still pay for a fresh manifest + head + pointer update).
  Future<bool> maybeAutoBackup({int? nowMs}) async {
    if (!await AppSettings.backupAuto()) return false;
    final s = await _api.status();
    if (!s.configured || (s.job?.finished == false)) return false;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final last = s.last;
    if (last != null && now - last.ms < autoMinIntervalMs) return false;
    if (!await _networkOk()) return false;
    final payload = await _backupService.buildPayload();
    final fp = BackupService.payloadFingerprint(payload);
    final state = _loadState();
    if (fp == state.lastBackupFp) return false;
    await _backupService.runBackup(payload: payload);
    // runBackup's hook records the fingerprint (noteBackupPublished).
    debugPrint('backup follow: automatic backup published');
    return true;
  }

  /// Wired as [BackupService.onBackupPublished] from main(): every
  /// successful backup — manual or automatic — stamps its payload
  /// fingerprint so the auto scheduler can skip unchanged state.
  void noteBackupPublished(String fingerprint) {
    final state = _loadState()..lastBackupFp = fingerprint;
    _saveState(state);
  }

  // ---- follower role -----------------------------------------------------

  /// Adopt shared read keys out of a sync cycle's remote docs (wired as
  /// `MyWatchSync.onRemoteDocs`): the newest valid section wins; our own
  /// backup line is never followed. A record that advertises a backup
  /// newer than the one last applied triggers an immediate check instead
  /// of waiting out [pollInterval].
  Future<void> noteRemoteDocs(List<RemoteSyncDoc> remote) async {
    Map<String, dynamic>? best;
    for (final d in remote) {
      final b = d.doc['backup'];
      if (b is! Map<String, dynamic>) continue;
      final ptr = (b['ptr'] as String? ?? '').toLowerCase();
      final key = (b['key'] as String? ?? '').toLowerCase();
      final ms = b['ms'] as int? ?? 0;
      if (!_isHex64(ptr) || !_isHex64(key) || ms <= 0) continue;
      if (best == null || ms > (best['ms'] as int)) {
        best = {'ptr': ptr, 'key': key, 'ms': ms, 'n': b['n'] as int? ?? 0};
      }
    }
    if (best == null) return;
    await _adopt(best);
  }

  Future<void> _adopt(Map<String, dynamic> record) async {
    try {
      // Never follow this device's own backup line.
      final own = await _ownPointer();
      if (own != null && own == record['ptr']) return;
      final state = _loadState();
      final changedKeys =
          state.ptr != record['ptr'] || state.key != record['key'];
      final advanced = (record['ms'] as int) > state.sharedMs;
      if (!changedKeys && !advanced) return;
      state
        ..ptr = record['ptr'] as String
        ..key = record['key'] as String
        ..sharedMs = record['ms'] as int;
      if (changedKeys) state.appliedHead = null;
      _saveState(state);
      _publishStatus(state);
      // The master just advertised something newer than we applied —
      // catch up now rather than at the next slow poll.
      await checkNow();
    } catch (e) {
      debugPrint('backup follow: adopting shared keys failed: $e');
    }
  }

  /// One follower check: peek the pointer (free) and fetch + fold the
  /// backup only when its head moved since the last applied one.
  /// Returns a short user-readable outcome.
  Future<String> checkNow() async {
    final state = _loadState();
    final ptr = state.ptr;
    final key = state.key;
    if (ptr == null || key == null) {
      return 'Not following a backup — no linked device has shared one.';
    }
    if (_checking) return 'Already checking.';
    _checking = true;
    try {
      final own = await _ownPointer();
      if (own != null && own == ptr) {
        return 'This device makes that backup itself.';
      }
      if (!await _networkOk()) {
        return 'Waiting for the network connection.';
      }
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final peek = await _api.peek(ptr);
      state.lastCheckMs = nowMs;
      if (!peek.found) {
        _saveState(state);
        _publishStatus(state);
        return 'No backup published under the shared keys yet.';
      }
      if (peek.head != null && peek.head == state.appliedHead) {
        _saveState(state);
        _publishStatus(state);
        return 'Already caught up with the latest backup.';
      }
      final summary = await _backupService.followFetch(ptr: ptr, key: key);
      state
        ..appliedHead = summary.head ?? peek.head
        ..lastAppliedMs = DateTime.now().millisecondsSinceEpoch;
      _saveState(state);
      _publishStatus(state, lastSummary: _summarize(summary));
      return _summarize(summary);
    } catch (e) {
      _publishStatus(_loadState(), error: '$e');
      rethrow;
    } finally {
      _checking = false;
    }
  }

  static String _summarize(RestoreSummary s) {
    final parts = <String>[
      if (s.entriesAdded > 0) '${s.entriesAdded} added',
      if (s.watchApplied > 0) '${s.watchApplied} watch position(s)',
      if (s.profilesChanged > 0) '${s.profilesChanged} profile(s)',
      if (s.detailsApplied + s.tmdbApplied > 0)
        '${s.detailsApplied + s.tmdbApplied} detail(s)',
      if (s.artInstalled > 0) '${s.artInstalled} artwork file(s)',
      if (s.mapsImported > 0) '${s.mapsImported} data map(s)',
    ];
    return parts.isEmpty
        ? 'Caught up — nothing new in the backup.'
        : 'Caught up from the backup: ${parts.join(', ')}.';
  }

  void _publishStatus(_FollowState state,
      {String? lastSummary, String? error}) {
    status.value = BackupFollowStatus(
      following: state.ptr != null,
      pointer: state.ptr,
      lastCheckMs: state.lastCheckMs,
      lastAppliedMs: state.lastAppliedMs,
      lastSummary: lastSummary ?? status.value.lastSummary,
      error: error,
    );
  }

  Future<String?> _ownPointer() async {
    try {
      final s = await _api.status();
      return s.configured ? s.pointer?.toLowerCase() : null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _networkOk() async {
    try {
      final h = await _health();
      return h.state == 'ready' && h.peers > 0;
    } catch (_) {
      return false;
    }
  }

  static bool _isHex64(String s) => RegExp(r'^[0-9a-f]{64}$').hasMatch(s);

  // ---- persisted state ----------------------------------------------------
  // Sync file IO on a tiny JSON file, so the service works the same in
  // fake-async test zones (the my_watch_sync state-file precedent).

  String? _statePath;

  String _resolveStatePath() {
    final override = statePathOverride;
    if (override != null) return override;
    // getApplicationSupportDirectory is async; cache the resolved path
    // the first time main() has started us (start() callers run outside
    // fake-async zones). Until resolved, state reads as empty.
    return _statePath ?? '';
  }

  /// Resolve the state path up front (called from [start]; tests use
  /// [statePathOverride] instead).
  Future<void> _resolvePath() async {
    _statePath ??=
        '${(await getApplicationSupportDirectory()).path}/backup_follow.json';
  }

  _FollowState _loadState() {
    try {
      final path = _resolveStatePath();
      if (path.isEmpty) return _FollowState();
      final file = File(path);
      if (!file.existsSync()) return _FollowState();
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      return _FollowState()
        ..ptr = json['ptr'] as String?
        ..key = json['key'] as String?
        ..sharedMs = json['shared_ms'] as int? ?? 0
        ..appliedHead = json['applied_head'] as String?
        ..lastAppliedMs = json['last_applied_ms'] as int?
        ..lastCheckMs = json['last_check_ms'] as int?
        ..lastBackupFp = json['last_backup_fp'] as String?;
    } catch (_) {
      return _FollowState();
    }
  }

  void _saveState(_FollowState state) {
    try {
      final path = _resolveStatePath();
      if (path.isEmpty) return;
      File(path).writeAsStringSync(jsonEncode({
        'ptr': state.ptr,
        'key': state.key,
        'shared_ms': state.sharedMs,
        'applied_head': state.appliedHead,
        'last_applied_ms': state.lastAppliedMs,
        'last_check_ms': state.lastCheckMs,
        'last_backup_fp': state.lastBackupFp,
      }));
    } catch (e) {
      debugPrint('backup follow: state save failed: $e');
    }
  }

  /// Load persisted state into [status] and resolve the state path —
  /// called once from main() before [start].
  Future<void> initialize() async {
    await _resolvePath();
    _publishStatus(_loadState());
  }
}

class _FollowState {
  /// The followed backup line's shared read keys (lowercase hex), or
  /// null while no linked device has shared any.
  String? ptr;
  String? key;

  /// The `ms` stamp of the newest shared record adopted so far.
  int sharedMs = 0;

  /// The head chunk of the last backup folded into this device.
  String? appliedHead;
  int? lastAppliedMs;
  int? lastCheckMs;

  /// [BackupService.payloadFingerprint] of the last backup THIS device
  /// published (master role) — the auto scheduler's no-change skip.
  String? lastBackupFp;
}

/// Snapshot of the follower for the Backup screen.
class BackupFollowStatus {
  const BackupFollowStatus({
    this.following = false,
    this.pointer,
    this.lastCheckMs,
    this.lastAppliedMs,
    this.lastSummary,
    this.error,
  });

  /// A linked device has shared its backup read keys with this one.
  final bool following;
  final String? pointer;
  final int? lastCheckMs;
  final int? lastAppliedMs;
  final String? lastSummary;
  final String? error;
}
