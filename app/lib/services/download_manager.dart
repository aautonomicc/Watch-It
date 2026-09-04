import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/app_database.dart';
import '../models/media_list.dart';
import 'app_settings.dart';
import 'connectivity.dart';
import 'network_pause.dart';
import 'embedded_client.dart';
import 'library_store.dart';
import 'network_events.dart';

/// Lifecycle of one managed download.
enum DownloadStatus { queued, downloading, paused, done, error }

/// Folder for a download whose entry is in no enabled list (shouldn't
/// happen — every download starts from a library surface).
const kOtherDownloadsFolder = 'Other';

/// Wrapper directory created inside the system Downloads folder so app
/// downloads don't pile up loose among the user's other files. A
/// user-chosen custom folder is the root itself (no extra wrapper).
const kDownloadsWrapperFolder = 'W@tch';

/// A list title (or file name) made filesystem-safe: reserved characters
/// become `_`, and trailing dots/spaces go (Windows rejects both).
String sanitizeDownloadName(String name) {
  var safe = name.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_').trim();
  while (safe.isNotEmpty &&
      (safe.endsWith('.') || safe.endsWith(' '))) {
    safe = safe.substring(0, safe.length - 1);
  }
  return safe;
}

/// Folder name a download of [entry] belongs in: the first enabled list
/// in library position order holding the entry's address (an entry in
/// several lists lands with the first, matching how the home wall
/// attributes entries). Channel lists count like any list.
String downloadListFolderFor(MediaEntry entry, List<MediaList> lists) {
  final addr = DownloadManager.normalize(entry.address);
  for (final list in lists) {
    if (!list.enabled) continue;
    for (final e in list.entries) {
      if (DownloadManager.normalize(e.address) == addr) {
        final safe = sanitizeDownloadName(list.title);
        return safe.isEmpty ? kOtherDownloadsFolder : safe;
      }
    }
  }
  return kOtherDownloadsFolder;
}

/// One download in the queue, keyed by the file's normalized XOR address.
class DownloadTask {
  const DownloadTask({
    required this.address,
    required this.name,
    required this.filePath,
    required this.totalBytes,
    required this.downloadedBytes,
    required this.status,
    required this.createdAt,
    this.error,
    this.pausedBySystem = false,
  });

  final String address;
  final String name;
  final String filePath;

  /// 0 until known (filled from /resolve or the response headers).
  final int totalBytes;
  final int downloadedBytes;
  final DownloadStatus status;

  /// Enqueue time (epoch ms) — fixes the task's place in the queue.
  final int createdAt;

  /// Failure detail while [status] is [DownloadStatus.error].
  final String? error;

  /// This pause was the app's doing (connection lost, waiting for
  /// Wi-Fi), so it auto-resumes when the blocking condition clears —
  /// persisted, so that also works across an app restart. A pause or
  /// resume by the user clears it.
  final bool pausedBySystem;

  /// 0..1 through the file; null while the total size is unknown.
  double? get progress => totalBytes > 0
      ? (downloadedBytes / totalBytes).clamp(0.0, 1.0)
      : null;

  /// Waiting to run or running — what "pause all" acts on.
  bool get active =>
      status == DownloadStatus.queued || status == DownloadStatus.downloading;

  DownloadTask copyWith({
    String? filePath,
    int? totalBytes,
    int? downloadedBytes,
    DownloadStatus? status,
    String? error,
    bool clearError = false,
    bool? pausedBySystem,
  }) =>
      DownloadTask(
        address: address,
        name: name,
        filePath: filePath ?? this.filePath,
        totalBytes: totalBytes ?? this.totalBytes,
        downloadedBytes: downloadedBytes ?? this.downloadedBytes,
        status: status ?? this.status,
        createdAt: createdAt,
        error: clearError ? null : (error ?? this.error),
        pausedBySystem: pausedBySystem ?? this.pausedBySystem,
      );
}

/// App-wide download queue: streams files from the embedded client's
/// `/xor/` endpoint to disk, one at a time, persisting progress in the
/// downloads table so partial files resume across app restarts (the
/// endpoint serves deterministic decrypted bytes, so `Range: bytes=N-`
/// picks up exactly where the file on disk stops).
///
/// Files land in a folder per source list under the downloads root —
/// `W@tch/` inside the system Downloads folder on desktop (a custom
/// folder from Settings → Downloads is the root itself), the app-private
/// `<support>/downloads/` directory on Android/iOS. The list is resolved
/// at enqueue time; renaming a list later only affects new downloads
/// (moving files would break byte-offset resume and local playback).
class DownloadManager extends ChangeNotifier {
  DownloadManager({
    String? base,
    Directory? directory,
    Future<List<MediaList>> Function()? lists,
  })  : _baseOverride = base,
        _directoryOverride = directory,
        _listsOverride = lists;

  /// Replaceable for tests (fresh instance per test).
  static DownloadManager instance = DownloadManager();

  final String? _baseOverride;
  final Directory? _directoryOverride;
  final Future<List<MediaList>> Function()? _listsOverride;

  /// The library's lists, for resolving which folder a download lands
  /// in. Never throws — folder resolution falls back to [kOtherDownloadsFolder].
  Future<List<MediaList>> _libraryLists() async {
    try {
      return await (_listsOverride ?? LibraryStore.load)();
    } catch (_) {
      return const [];
    }
  }

  String? get _base => _baseOverride ?? EmbeddedClient.baseUrl();

  /// Tasks keyed by normalized address, in enqueue order.
  final Map<String, DownloadTask> _tasks = {};
  Future<void>? _loading;
  bool _pumping = false;
  String? _activeAddress;
  HttpClient? _activeClient;

  /// Addresses paused by [pauseAllForPlayback], resumed together by
  /// [resumeAfterPlayback] — a manual pause is not in here and stays
  /// paused when playback ends.
  final Set<String> _pausedForPlayback = {};

  ConnectivityMonitor? _monitor;

  /// Watch [monitor] and auto-resume system-paused downloads (connection
  /// loss) the moment it reports the network is back. Called once from
  /// main(); tests may bind a monitor with an injected probe.
  void bindConnectivity(ConnectivityMonitor monitor) {
    _monitor?.removeListener(_onConnectivityFlip);
    _monitor = monitor;
    monitor.addListener(_onConnectivityFlip);
  }

  void _onConnectivityFlip() {
    final monitor = _monitor;
    if (monitor != null && !monitor.offline) {
      unawaited(_resumeSystemPausedIfAllowed());
    }
  }

  NetworkEvents? _network;
  bool _waitingForWifi = false;

  /// True while the whole queue is system-paused because we are on
  /// mobile data and Settings → Network says downloads are Wi-Fi-only.
  /// The queue UI labels those pauses "Waiting for Wi-Fi".
  bool get waitingForWifi => _waitingForWifi;

  /// Watch the OS transport and enforce the downloads network policy:
  /// going cellular under Wi-Fi-only pauses the queue, Wi-Fi coming
  /// back resumes it. Called once from main().
  void bindNetwork(NetworkEvents network) {
    _network?.removeListener(_onTransportFlip);
    _network = network;
    network.addListener(_onTransportFlip);
  }

  void _onTransportFlip() => unawaited(_applyNetworkPolicy());

  /// Re-evaluate the downloads network policy now (Settings changed it).
  void onNetworkPolicyChanged() => unawaited(_applyNetworkPolicy());

  /// Pause every active download as a system pause (auto-resumes when
  /// conditions clear). The Android foreground service's 6h dataSync
  /// timeout lands here.
  Future<void> systemPauseAll() async {
    var any = false;
    for (final task in _tasks.values.toList()) {
      if (task.active) {
        _update(task.copyWith(
            status: DownloadStatus.paused, pausedBySystem: true));
        any = true;
      }
    }
    if (any) _activeClient?.close(force: true);
  }

  /// App came back to the foreground: notice files the user deleted by
  /// hand while we weren't looking (desktop windows stay open for days,
  /// so the startup sweep alone would lag), then restart anything the
  /// app itself paused (6h background timeout, connection loss that
  /// never flipped the monitor while frozen), policy permitting.
  Future<void> onAppResumed() async {
    if (await _sweepMissingDone()) notifyListeners();
    await _resumeSystemPausedIfAllowed();
  }

  /// Whether the downloads policy permits transfers on the current
  /// transport. No [NetworkEvents] bound (desktop before main wiring,
  /// tests) means no gating, like before.
  Future<bool> _downloadsAllowedNow() async {
    final network = _network;
    if (network == null || !network.onCellular) return true;
    return await AppSettings.downloadNetworkPolicy() ==
        DownloadNetworkPolicy.any;
  }

  Future<void> _applyNetworkPolicy() async {
    if (await _downloadsAllowedNow()) {
      if (_waitingForWifi) {
        _waitingForWifi = false;
        notifyListeners();
      }
      await _resumeSystemPausedIfAllowed();
    } else {
      var any = false;
      for (final task in _tasks.values.toList()) {
        if (task.active) {
          _update(task.copyWith(
              status: DownloadStatus.paused, pausedBySystem: true));
          any = true;
        }
      }
      if (any) _activeClient?.close(force: true);
      if (!_waitingForWifi) {
        _waitingForWifi = true;
        notifyListeners();
      }
    }
  }

  /// Re-queue every download the app itself paused — unless the network
  /// policy still forbids transfers (offline recovery while on cellular
  /// with Wi-Fi-only set must not restart anything). The user's own
  /// pauses (pausedBySystem false) stay put.
  Future<void> _resumeSystemPausedIfAllowed() async {
    if (!await _downloadsAllowedNow()) return;
    var any = false;
    for (final task in _tasks.values.toList()) {
      if (task.status == DownloadStatus.paused && task.pausedBySystem) {
        _update(task.copyWith(
            status: DownloadStatus.queued,
            clearError: true,
            pausedBySystem: false));
        any = true;
      }
    }
    if (any) _pump();
  }

  /// The current batch: every task queued or downloading since the queue
  /// was last idle. Members that finish stay counted (that is what makes
  /// an `x of y` meter possible); an idle queue closes the batch.
  final Set<String> _batch = {};

  static String normalize(String address) =>
      address.toLowerCase().replaceFirst('0x', '');

  List<DownloadTask> get tasks => List.unmodifiable(_tasks.values);
  DownloadTask? taskFor(String address) => _tasks[normalize(address)];
  bool get hasActive => _tasks.values.any((t) => t.active);
  int get activeCount => _tasks.values.where((t) => t.active).length;
  int get doneCount =>
      _tasks.values.where((t) => t.status == DownloadStatus.done).length;

  /// Aggregate for the home top-bar meter: finished/total counts over
  /// the current batch plus its mean per-file progress (done = 1, size
  /// unknown = 0). Null while nothing is queued or downloading — the
  /// meter shows only for a working queue, not a paused or drained one.
  ({int done, int total, double progress})? get batchProgress {
    var done = 0, total = 0;
    var sum = 0.0;
    var anyActive = false;
    for (final addr in _batch) {
      final task = _tasks[addr];
      if (task == null) continue;
      total++;
      if (task.active) anyActive = true;
      if (task.status == DownloadStatus.done) {
        done++;
        sum += 1.0;
      } else {
        sum += task.progress ?? 0.0;
      }
    }
    if (!anyActive || total == 0) return null;
    return (done: done, total: total, progress: (sum / total).clamp(0.0, 1.0));
  }

  /// Grow [_batch] with whatever is active now; clear it once the queue
  /// goes idle (nothing queued or downloading) so the next enqueue
  /// starts a fresh `x of y` count.
  void _trackBatch() {
    var anyActive = false;
    for (final task in _tasks.values) {
      if (task.active) {
        anyActive = true;
        _batch.add(task.address);
      }
    }
    if (!anyActive) _batch.clear();
  }

  /// Test-only: place [task] straight into the in-memory queue (no
  /// persistence, no pump) so widget tests can stage active states that
  /// would otherwise race a real transfer.
  @visibleForTesting
  void debugStageTask(DownloadTask task) {
    _tasks[task.address] = task;
    _trackBatch();
    notifyListeners();
  }

  /// Local file path for a finished download of [entry], or null when it
  /// is not downloaded (or the file has since vanished from disk).
  String? localPathIfDone(MediaEntry entry) {
    final task = _tasks[normalize(entry.address)];
    if (task == null || task.status != DownloadStatus.done) return null;
    return File(task.filePath).existsSync() ? task.filePath : null;
  }

  /// Load persisted tasks on first use. Downloads that were mid-flight
  /// when the app last closed re-queue and continue from the bytes on
  /// disk; paused ones stay paused.
  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    final db = await LibraryStore.database();
    final rows = await (db.select(db.downloads)
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .get();
    for (final row in rows) {
      var status = DownloadStatus.values.asNameMap()[row.status] ??
          DownloadStatus.error;
      if (status == DownloadStatus.downloading) status = DownloadStatus.queued;
      _tasks[row.address] = DownloadTask(
        address: row.address,
        name: row.name,
        filePath: row.filePath,
        totalBytes: row.totalBytes,
        downloadedBytes: row.downloadedBytes,
        status: status,
        createdAt: row.createdAt,
        error: row.error,
        pausedBySystem: row.pausedBySystem,
      );
    }
    // Finished downloads whose file was deleted by hand are dropped so
    // the title can be re-downloaded (enqueue no-ops on done rows) and
    // stops showing as downloaded; then a one-time tidy moves finished
    // flat files into the new per-list folder layout.
    await _sweepMissingDone();
    await _tidyFlatDownloads();
    _trackBatch();
    notifyListeners();
    _pump();
    // Tasks the app paused (connection loss, waiting for Wi-Fi) in a
    // previous run resume by themselves once we know we are online.
    final monitor = _monitor;
    if (monitor != null &&
        _tasks.values.any(
            (t) => t.status == DownloadStatus.paused && t.pausedBySystem)) {
      if (!await monitor.refresh()) await _resumeSystemPausedIfAllowed();
    }
  }

  /// Drop finished tasks whose file no longer exists on disk (deleted by
  /// hand — a deleted folder is just N missing files). Queued, paused
  /// and error tasks are left alone: they already self-heal on resume,
  /// and dropping a paused row would lose the user's queue intent.
  /// True when anything was dropped (in memory and in the database).
  ///
  /// Unmounted-drive guard: when a custom download folder is set and its
  /// root directory itself is missing (USB drive/network mount not
  /// present), the sweep is skipped entirely — the files are probably
  /// not gone, just unreachable.
  Future<bool> _sweepMissingDone() async {
    if (!_tasks.values.any((t) => t.status == DownloadStatus.done)) {
      return false;
    }
    if (_directoryOverride == null) {
      final custom = await AppSettings.downloadDirPath();
      if (custom != null &&
          custom.isNotEmpty &&
          !Directory(custom).existsSync()) {
        return false;
      }
    }
    final gone = <String>[];
    for (final task in _tasks.values) {
      if (task.status == DownloadStatus.done &&
          !File(task.filePath).existsSync()) {
        gone.add(task.address);
      }
    }
    if (gone.isEmpty) return false;
    final db = await LibraryStore.database();
    for (final addr in gone) {
      _tasks.remove(addr);
      _batch.remove(addr);
      await (db.delete(db.downloads)..where((t) => t.address.equals(addr)))
          .go();
    }
    return true;
  }

  /// One-time pref flag: the tidy migration below already ran.
  static const _tidiedKey = 'downloads_tidy_v1';

  /// One-time tidy (desktop only): finished downloads sitting FLAT in
  /// the downloads root — or, for the default `W@tch` wrapper, flat in
  /// the system Downloads folder where the old layout put them — move
  /// into the new `<root>/<List name>/` layout, with the row's file path
  /// updated. Skip-on-any-error: a locked/missing file just stays where
  /// it is (its row keeps the old absolute path and keeps working).
  /// Mid-flight/paused tasks are left alone — resume reads the file at
  /// its recorded path.
  Future<void> _tidyFlatDownloads() async {
    if (Platform.isAndroid || Platform.isIOS) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_tidiedKey) ?? false) return;
    await prefs.setBool(_tidiedKey, true);
    final done = [
      for (final t in _tasks.values)
        if (t.status == DownloadStatus.done) t,
    ];
    if (done.isEmpty) return;
    List<MediaList>? lists;
    final sep = Platform.pathSeparator;
    for (final task in done) {
      try {
        final file = File(task.filePath);
        if (!file.existsSync()) continue;
        final root = await _downloadsRoot(create: false);
        // Flat = directly in the root, or (default layout only) directly
        // in the system Downloads folder the pre-folder versions used.
        final flatIn = file.parent.path;
        if (flatIn != root.dir.path &&
            !(root.wrapper && flatIn == root.dir.parent.path)) {
          continue;
        }
        lists ??= await _libraryLists();
        final folder = downloadListFolderFor(
            MediaEntry(name: task.name, address: task.address), lists);
        final targetDir = '${root.dir.path}$sep$folder';
        if (file.parent.path == targetDir) continue;
        final base = task.filePath
            .substring(task.filePath.lastIndexOf(sep) + 1);
        var target = '$targetDir$sep$base';
        if (File(target).existsSync() ||
            _tasks.values.any((t) => t.filePath == target)) {
          target = '$targetDir$sep${task.address.substring(0, 8)}-$base';
          if (File(target).existsSync()) continue;
        }
        Directory(targetDir).createSync(recursive: true);
        try {
          file.renameSync(target);
        } catch (_) {
          // Cross-device move: copy, then delete the original.
          file.copySync(target);
          file.deleteSync();
        }
        _update(task.copyWith(filePath: target));
      } catch (_) {
        // This file stays where it is; its row keeps working.
      }
    }
  }

  /// Queue [entry] for download. Re-queues a paused or failed task;
  /// no-op when already queued, downloading, or done.
  Future<void> enqueue(MediaEntry entry) async {
    await ensureLoaded();
    // A user-started download is activity: lifts an idle auto-pause and
    // keeps the idle timer from firing mid-queue.
    await NetworkPause.instance.noteActivity();
    final addr = normalize(entry.address);
    final existing = _tasks[addr];
    if (existing != null) {
      if (existing.status == DownloadStatus.done) return;
      return resume(addr);
    }
    final root = await _downloadsRoot();
    final folder = downloadListFolderFor(entry, await _libraryLists());
    final dir =
        Directory('${root.dir.path}${Platform.pathSeparator}$folder');
    final path = _pathFor(dir, entry.name, addr);
    // A leftover file at the target path (from outside the queue) would
    // corrupt the byte-offset resume — start clean.
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    final task = DownloadTask(
      address: addr,
      name: entry.name,
      filePath: path,
      totalBytes: 0,
      downloadedBytes: 0,
      status: DownloadStatus.queued,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    _update(task);
    // Learn the total size ahead of the first byte so the queue shows
    // real progress immediately (also warms the data map).
    unawaited(_fillTotal(addr));
    _pump();
  }

  /// Pause one download (aborts the transfer if it is the running one).
  /// A pause by hand is never auto-resumed.
  Future<void> pause(String address) async {
    final addr = normalize(address);
    final task = _tasks[addr];
    if (task == null || !task.active) return;
    _update(
        task.copyWith(status: DownloadStatus.paused, pausedBySystem: false));
    if (_activeAddress == addr) _activeClient?.close(force: true);
  }

  /// Resume a paused or failed download from the bytes already on disk.
  Future<void> resume(String address) async {
    final addr = normalize(address);
    final task = _tasks[addr];
    if (task == null ||
        (task.status != DownloadStatus.paused &&
            task.status != DownloadStatus.error)) {
      return;
    }
    await NetworkPause.instance.noteActivity();
    _pausedForPlayback.remove(addr);
    _update(task.copyWith(
        status: DownloadStatus.queued,
        clearError: true,
        pausedBySystem: false));
    _pump();
  }

  /// Remove a download from the queue and delete its file from disk.
  Future<void> remove(String address) async {
    final addr = normalize(address);
    final task = _tasks.remove(addr);
    if (task == null) return;
    _pausedForPlayback.remove(addr);
    _batch.remove(addr);
    _trackBatch();
    if (_activeAddress == addr) _activeClient?.close(force: true);
    try {
      await File(task.filePath).delete();
    } catch (_) {}
    await _cleanupEmptyFolders(task.filePath);
    final db = await LibraryStore.database();
    await (db.delete(db.downloads)..where((t) => t.address.equals(addr))).go();
    notifyListeners();
  }

  /// After deleting a file: remove its list folder when that left it
  /// empty, and the auto-created `W@tch` wrapper when IT is left empty.
  /// Only ever rmdir-if-empty (never recursive), and only for folders
  /// under the current downloads root — a legacy flat file's parent (the
  /// user's own Downloads folder) is never touched.
  Future<void> _cleanupEmptyFolders(String filePath) async {
    try {
      final root = await _downloadsRoot(create: false);
      final rootPath = root.dir.path;
      final sep = Platform.pathSeparator;
      final parent = File(filePath).parent;
      if (parent.path == rootPath ||
          !parent.path.startsWith('$rootPath$sep')) {
        return;
      }
      try {
        parent.deleteSync(); // fails on non-empty — that's the guard
      } catch (_) {
        return;
      }
      if (root.wrapper) {
        try {
          root.dir.deleteSync();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Remove several downloads at once — the queue rows and their files
  /// on disk both go (Settings → Downloads multi-select and Delete all).
  Future<void> removeMany(Iterable<String> addresses) async {
    for (final address in addresses.toList()) {
      await remove(address);
    }
  }

  /// Pause every queued/running download. True when anything was paused.
  Future<bool> pauseAll() async {
    await ensureLoaded();
    var any = false;
    for (final task in _tasks.values.toList()) {
      if (task.active) {
        _update(task.copyWith(
            status: DownloadStatus.paused, pausedBySystem: false));
        any = true;
      }
    }
    if (any) _activeClient?.close(force: true);
    return any;
  }

  /// Resume every paused download.
  Future<void> resumeAll() async {
    await ensureLoaded();
    await NetworkPause.instance.noteActivity();
    _pausedForPlayback.clear();
    var any = false;
    for (final task in _tasks.values.toList()) {
      if (task.status == DownloadStatus.paused ||
          task.status == DownloadStatus.error) {
        _update(task.copyWith(
            status: DownloadStatus.queued,
            clearError: true,
            pausedBySystem: false));
        any = true;
      }
    }
    if (any) _pump();
  }

  /// Pause every active download for the duration of a playback session
  /// (Settings → Downloads decides whether playback asks first). The
  /// paused set is remembered so [resumeAfterPlayback] restarts exactly
  /// these — not downloads the user paused by hand.
  Future<bool> pauseAllForPlayback() async {
    await ensureLoaded();
    var any = false;
    for (final task in _tasks.values.toList()) {
      if (task.active) {
        _pausedForPlayback.add(task.address);
        _update(task.copyWith(status: DownloadStatus.paused));
        any = true;
      }
    }
    if (any) _activeClient?.close(force: true);
    return any;
  }

  /// Resume the downloads paused by [pauseAllForPlayback]. True when
  /// anything actually resumed (drives the "Downloads resumed" notice).
  Future<bool> resumeAfterPlayback() async {
    var any = false;
    for (final addr in _pausedForPlayback.toList()) {
      final task = _tasks[addr];
      if (task != null && task.status == DownloadStatus.paused) {
        _update(task.copyWith(status: DownloadStatus.queued));
        any = true;
      }
    }
    _pausedForPlayback.clear();
    if (any) _pump();
    return any;
  }

  /// The downloads ROOT (list folders live inside it): the test
  /// override, then the user-chosen folder (desktop — that folder IS the
  /// root, no extra wrapper), then `W@tch/` inside the system Downloads
  /// folder (desktop default — where users look for downloaded files,
  /// kept tidy in one place), then app-private `downloads/` (Android/iOS,
  /// or no Downloads dir). [wrapper] marks the auto-created `W@tch`
  /// wrapper — the only root that is itself cleaned up when it empties.
  Future<({Directory dir, bool wrapper})> _downloadsRoot(
      {bool create = true}) async {
    // Sync IO on purpose: this runs inside widget tests' fake-async
    // zone, where real async dart:io futures never complete.
    Directory made(Directory d) {
      if (create) d.createSync(recursive: true);
      return d;
    }
    final override = _directoryOverride;
    if (override != null) return (dir: made(override), wrapper: false);
    final custom = await AppSettings.downloadDirPath();
    if (custom != null && custom.isNotEmpty) {
      return (dir: made(Directory(custom)), wrapper: false);
    }
    if (!Platform.isAndroid && !Platform.isIOS) {
      try {
        final downloads = await getDownloadsDirectory();
        if (downloads != null) {
          final root = Directory('${downloads.path}'
              '${Platform.pathSeparator}$kDownloadsWrapperFolder');
          return (dir: made(root), wrapper: true);
        }
      } catch (_) {
        // Fall through to app-private storage.
      }
    }
    final support = await getApplicationSupportDirectory();
    return (
      dir: made(Directory('${support.path}/downloads')),
      wrapper: false,
    );
  }

  /// Target path for a new download inside [dir] (the entry's list
  /// folder): the sanitized file name, prefixed with the address when
  /// another task already claims that path — per-folder, so two lists
  /// can hold the same file name without the prefix.
  String _pathFor(Directory dir, String name, String addr) {
    var safe = sanitizeDownloadName(name);
    if (safe.isEmpty) safe = addr;
    final plain = '${dir.path}${Platform.pathSeparator}$safe';
    final taken = _tasks.values.any((t) => t.filePath == plain);
    if (!taken) return plain;
    return '${dir.path}${Platform.pathSeparator}'
        '${addr.substring(0, 8)}-$safe';
  }

  /// Fill in the total size from `/resolve` (local map lookup) when the
  /// response headers have not provided it yet.
  Future<void> _fillTotal(String addr) async {
    final base = _base;
    if (base == null) return;
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse('$base/resolve/$addr'));
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) return;
      final size = (jsonDecode(body) as Map<String, dynamic>)['size'] as int?;
      final task = _tasks[addr];
      if (size != null && size > 0 && task != null && task.totalBytes == 0) {
        _update(task.copyWith(totalBytes: size));
      }
    } catch (_) {
      // Size stays unknown until the download response reports it.
    } finally {
      client.close(force: true);
    }
  }

  /// Run queued downloads one at a time until the queue drains.
  void _pump() {
    if (_pumping) return;
    _pumping = true;
    unawaited(() async {
      try {
        while (true) {
          DownloadTask? next;
          for (final t in _tasks.values) {
            if (t.status == DownloadStatus.queued) {
              next = t;
              break;
            }
          }
          if (next == null) break;
          // Network policy gate: on cellular with Wi-Fi-only set, the
          // queue system-pauses ("Waiting for Wi-Fi") instead of running.
          if (!await _downloadsAllowedNow()) {
            await _applyNetworkPolicy();
            break;
          }
          await _download(next.address);
        }
      } finally {
        _pumping = false;
      }
    }());
  }

  Future<void> _download(String addr) async {
    var task = _tasks[addr];
    if (task == null) return;
    final base = _base;
    if (base == null) {
      _update(task.copyWith(
          status: DownloadStatus.error,
          error: 'Built-in client unavailable'));
      return;
    }
    final file = File(task.filePath);
    // The file on disk is the source of truth for the resume offset —
    // the DB counter can run ahead of what was flushed before a crash.
    var start = 0;
    try {
      if (await file.exists()) start = await file.length();
    } catch (_) {}
    // Own client per transfer so pausing aborts only this download.
    final client = HttpClient();
    _activeClient = client;
    _activeAddress = addr;
    _update(task.copyWith(
        status: DownloadStatus.downloading, downloadedBytes: start));
    IOSink? sink;
    try {
      final req = await client.getUrl(Uri.parse('$base/xor/$addr'));
      if (start > 0) {
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-');
      }
      final res = await req.close();
      if (res.statusCode != HttpStatus.ok &&
          res.statusCode != HttpStatus.partialContent) {
        throw HttpException('HTTP ${res.statusCode}');
      }
      if (start > 0 && res.statusCode == HttpStatus.ok) {
        // Server ignored the range — the body is the whole file.
        start = 0;
      }
      var total = _tasks[addr]?.totalBytes ?? 0;
      if (res.contentLength > 0) total = start + res.contentLength;
      await file.parent.create(recursive: true);
      sink = file.openWrite(
          mode: start > 0 ? FileMode.append : FileMode.write);
      var written = start;
      var lastPersisted = start;
      // A dead connection usually errors the stream within seconds (the
      // embedded client's chunk fetches time out); the stall timeout is
      // the backstop for a stream that hangs instead.
      final data = res.timeout(_stallTimeout, onTimeout: (sink) {
        sink.addError(const HttpException('No data received (stalled)'));
        sink.close();
      });
      await for (final chunk in data) {
        sink.add(chunk);
        written += chunk.length;
        // Progress lands in the DB only for bytes already flushed to
        // disk, so a crash never records more than the file holds.
        if (written - lastPersisted >= _persistEveryBytes) {
          await sink.flush();
          lastPersisted = written;
          final current = _tasks[addr];
          if (current == null) break; // removed mid-flight
          _update(current.copyWith(
              downloadedBytes: written, totalBytes: total));
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      final current = _tasks[addr];
      if (current == null) {
        try {
          await file.delete();
        } catch (_) {}
        return;
      }
      if (total > 0 && written < total) {
        // The stream ended early without an error (connection dropped).
        throw const HttpException('Connection closed before end of file');
      }
      _update(current.copyWith(
        status: DownloadStatus.done,
        downloadedBytes: written,
        totalBytes: total > 0 ? total : written,
        clearError: true,
      ));
    } catch (e) {
      try {
        await sink?.flush();
        await sink?.close();
      } catch (_) {}
      var bytes = start;
      try {
        bytes = await file.length();
      } catch (_) {}
      final current = _tasks[addr];
      if (current == null) {
        // Removed while downloading: nothing to keep.
        try {
          await file.delete();
        } catch (_) {}
      } else if (current.status == DownloadStatus.paused ||
          current.status == DownloadStatus.queued) {
        // Pause aborted the transfer (queued = already re-queued before
        // the abort surfaced) — record what made it to disk; the pump
        // loop picks a queued task up again.
        _update(current.copyWith(downloadedBytes: bytes));
      } else if (await _connectionLost()) {
        // The transfer died because the network is gone, not because the
        // download is broken — pause instead of erroring; marked as a
        // system pause so it auto-resumes when the connection is back.
        _update(current.copyWith(
            status: DownloadStatus.paused,
            downloadedBytes: bytes,
            clearError: true,
            pausedBySystem: true));
      } else {
        _update(current.copyWith(
            status: DownloadStatus.error,
            downloadedBytes: bytes,
            error: '$e'));
      }
    } finally {
      if (_activeAddress == addr) {
        _activeAddress = null;
        _activeClient = null;
      }
      client.close(force: true);
    }
  }

  static const _persistEveryBytes = 4 * 1024 * 1024;

  /// A transfer that delivers no bytes for this long counts as a lost
  /// connection (cold first byte takes ~25s on the real network, so this
  /// leaves generous headroom).
  static const _stallTimeout = Duration(minutes: 2);

  /// True when the embedded client reports no usable network connection
  /// — still connecting, or connected with zero peers — the signature
  /// of lost connectivity rather than a broken download.
  Future<bool> _connectionLost() async {
    final base = _base;
    if (base == null) return false;
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse('$base/health'));
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != HttpStatus.ok) return false;
      final map = jsonDecode(body) as Map<String, dynamic>;
      final state = map['state'] as String?;
      final peers = map['peers'] as int? ?? 0;
      // 'paused' = the user's network pause: park the download like a
      // lost connection (NetworkPause resumes system pauses on unpause).
      return state == 'connecting' ||
          state == 'paused' ||
          (state == 'ready' && peers == 0);
    } catch (_) {
      // The health endpoint itself failing is not a network verdict.
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// Apply [task] to the in-memory queue, notify, and persist.
  void _update(DownloadTask task) {
    _tasks[task.address] = task;
    _trackBatch();
    notifyListeners();
    unawaited(_persist(task));
  }

  Future<void> _persist(DownloadTask task) async {
    try {
      final db = await LibraryStore.database();
      await db.into(db.downloads).insertOnConflictUpdate(
            DownloadsCompanion.insert(
              address: task.address,
              name: task.name,
              filePath: task.filePath,
              totalBytes: Value(task.totalBytes),
              downloadedBytes: Value(task.downloadedBytes),
              status: task.status.name,
              error: Value(task.error),
              pausedBySystem: Value(task.pausedBySystem),
              createdAt: task.createdAt,
              updatedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          );
    } catch (_) {
      // A failed progress write costs at most a re-downloaded span.
    }
  }
}

/// `412 MB of 5.3 GB` / `1.2 GB` (total unknown) — for queue rows.
String downloadSizeLabel(DownloadTask task) {
  final done = formatBytes(task.downloadedBytes);
  if (task.totalBytes <= 0) return done;
  return '$done of ${formatBytes(task.totalBytes)}';
}
