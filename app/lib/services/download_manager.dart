import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../db/app_database.dart';
import '../models/media_list.dart';
import 'app_settings.dart';
import 'embedded_client.dart';
import 'library_store.dart';
import 'storage_usage.dart';

/// Lifecycle of one managed download.
enum DownloadStatus { queued, downloading, paused, done, error }

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

  /// 0..1 through the file; null while the total size is unknown.
  double? get progress => totalBytes > 0
      ? (downloadedBytes / totalBytes).clamp(0.0, 1.0)
      : null;

  /// Waiting to run or running — what "pause all" acts on.
  bool get active =>
      status == DownloadStatus.queued || status == DownloadStatus.downloading;

  DownloadTask copyWith({
    int? totalBytes,
    int? downloadedBytes,
    DownloadStatus? status,
    String? error,
    bool clearError = false,
  }) =>
      DownloadTask(
        address: address,
        name: name,
        filePath: filePath,
        totalBytes: totalBytes ?? this.totalBytes,
        downloadedBytes: downloadedBytes ?? this.downloadedBytes,
        status: status ?? this.status,
        createdAt: createdAt,
        error: clearError ? null : (error ?? this.error),
      );
}

/// App-wide download queue: streams files from the embedded client's
/// `/xor/` endpoint to disk, one at a time, persisting progress in the
/// downloads table so partial files resume across app restarts (the
/// endpoint serves deterministic decrypted bytes, so `Range: bytes=N-`
/// picks up exactly where the file on disk stops).
///
/// Files land in the app-private `<support>/downloads/` directory by
/// default; on desktop a custom folder can be set in Settings →
/// Downloads (applies to new downloads only).
class DownloadManager extends ChangeNotifier {
  DownloadManager({String? base, Directory? directory})
      : _baseOverride = base,
        _directoryOverride = directory;

  /// Replaceable for tests (fresh instance per test).
  static DownloadManager instance = DownloadManager();

  final String? _baseOverride;
  final Directory? _directoryOverride;

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

  static String normalize(String address) =>
      address.toLowerCase().replaceFirst('0x', '');

  List<DownloadTask> get tasks => List.unmodifiable(_tasks.values);
  DownloadTask? taskFor(String address) => _tasks[normalize(address)];
  bool get hasActive => _tasks.values.any((t) => t.active);
  int get activeCount => _tasks.values.where((t) => t.active).length;
  int get doneCount =>
      _tasks.values.where((t) => t.status == DownloadStatus.done).length;

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
      );
    }
    notifyListeners();
    _pump();
  }

  /// Queue [entry] for download. Re-queues a paused or failed task;
  /// no-op when already queued, downloading, or done.
  Future<void> enqueue(MediaEntry entry) async {
    await ensureLoaded();
    final addr = normalize(entry.address);
    final existing = _tasks[addr];
    if (existing != null) {
      if (existing.status == DownloadStatus.done) return;
      return resume(addr);
    }
    final dir = await _downloadsDir();
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
  Future<void> pause(String address) async {
    final addr = normalize(address);
    final task = _tasks[addr];
    if (task == null || !task.active) return;
    _update(task.copyWith(status: DownloadStatus.paused));
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
    _pausedForPlayback.remove(addr);
    _update(task.copyWith(status: DownloadStatus.queued, clearError: true));
    _pump();
  }

  /// Remove a download from the queue and delete its file from disk.
  Future<void> remove(String address) async {
    final addr = normalize(address);
    final task = _tasks.remove(addr);
    if (task == null) return;
    _pausedForPlayback.remove(addr);
    if (_activeAddress == addr) _activeClient?.close(force: true);
    try {
      await File(task.filePath).delete();
    } catch (_) {}
    final db = await LibraryStore.database();
    await (db.delete(db.downloads)..where((t) => t.address.equals(addr))).go();
    notifyListeners();
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
        _update(task.copyWith(status: DownloadStatus.paused));
        any = true;
      }
    }
    if (any) _activeClient?.close(force: true);
    return any;
  }

  /// Resume every paused download.
  Future<void> resumeAll() async {
    await ensureLoaded();
    _pausedForPlayback.clear();
    var any = false;
    for (final task in _tasks.values.toList()) {
      if (task.status == DownloadStatus.paused ||
          task.status == DownloadStatus.error) {
        _update(task.copyWith(status: DownloadStatus.queued, clearError: true));
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

  /// Directory new downloads land in: the test override, then the
  /// user-chosen folder (desktop), then app-private `downloads/`.
  Future<Directory> _downloadsDir() async {
    final override = _directoryOverride;
    if (override != null) return override.create(recursive: true);
    final custom = await AppSettings.downloadDirPath();
    if (custom != null && custom.isNotEmpty) {
      return Directory(custom).create(recursive: true);
    }
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/downloads').create(recursive: true);
  }

  /// Target path for a new download: the sanitized file name, prefixed
  /// with the address when another task already claims that name.
  String _pathFor(Directory dir, String name, String addr) {
    var safe = name.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_').trim();
    if (safe.isEmpty) safe = addr;
    final plain = '${dir.path}${Platform.pathSeparator}$safe';
    final taken = _tasks.values.any((t) => t.filePath == plain);
    if (!taken) return plain;
    return '${dir.path}${Platform.pathSeparator}'
        '${addr.substring(0, 8)}-$safe';
  }

  /// Fill in the total size from `/resolve` when the response headers
  /// have not provided it yet.
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
        // download is broken — pause instead of erroring; the bytes on
        // disk resume as usual once the user is back online.
        _update(current.copyWith(
            status: DownloadStatus.paused,
            downloadedBytes: bytes,
            clearError: true));
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
      return state == 'connecting' || (state == 'ready' && peers == 0);
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
