import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:connectivity_plus/connectivity_plus.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/services/connectivity.dart';
import 'package:watchit/services/download_manager.dart';
import 'package:watchit/services/embedded_client.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/network_events.dart';

const _addrA =
    'a3f1c9e07b6d5a4f2e8c1b0d9f7a6e5c4b3a2d1e0f9c8b7a6d5e4f3c2b1a0d9e';
const _addrB =
    'b4a2d0f18c7e6b5a3f9d2c1e0a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0';

MediaEntry entry(String name, String addr) =>
    MediaEntry(name: name, address: addr);

/// Wait until [condition] holds (checked every 10ms), or fail.
Future<void> waitFor(bool Function() condition,
    {Duration timeout = const Duration(seconds: 10)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not reached within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  // No TestWidgetsFlutterBinding here: it stubs out HttpClient (every
  // request answers 400), and these tests download from a real
  // localhost server like the prefetch tests do.
  late AppDatabase db;
  late Directory dir;
  late HttpServer server;
  late String base;

  /// Bytes served for every /xor address.
  final payload = List<int>.generate(64 * 1024, (i) => i % 251);

  /// Range headers seen per request, in order (null = no Range).
  final rangesSeen = <String?>[];

  /// When set, the /xor handler sends this many bytes, then waits for
  /// [gateRelease] before sending the rest (lets tests pause mid-flight).
  int? gateAfter;
  Completer<void> gateRelease = Completer<void>();

  /// When set, the /xor handler sends this many bytes then destroys the
  /// socket (simulates the connection dropping mid-transfer).
  int? dropAfter;

  /// What /health reports (the manager asks it whether a failed transfer
  /// means the network is gone).
  Map<String, Object?> healthBody = {'state': 'ready', 'peers': 5};

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await LibraryStore.useForTesting(db);
    dir = await Directory.systemTemp.createTemp('wi-dl-test');
    rangesSeen.clear();
    gateAfter = null;
    gateRelease = Completer<void>();
    dropAfter = null;
    healthBody = {'state': 'ready', 'peers': 5};
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      try {
        if (req.uri.path == '/health') {
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(healthBody));
          await req.response.close();
          return;
        }
        if (req.uri.path.startsWith('/resolve/')) {
          req.response.headers.contentType = ContentType.json;
          req.response
              .write(jsonEncode({'size': payload.length, 'chunks': 2}));
          await req.response.close();
          return;
        }
        final range = req.headers.value(HttpHeaders.rangeHeader);
        rangesSeen.add(range);
        var start = 0;
        if (range != null) {
          start = int.parse(
              RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
          req.response.statusCode = HttpStatus.partialContent;
        }
        final body = payload.sublist(start);
        req.response.contentLength = body.length;
        final drop = dropAfter;
        if (drop != null && drop > start && drop < payload.length) {
          req.response.add(body.sublist(0, drop - start));
          await req.response.flush();
          // Let the bytes reach the client before the abort (an early
          // close RSTs the connection, discarding data in flight).
          await Future<void>.delayed(const Duration(milliseconds: 50));
          // Closing below contentLength aborts the connection — the
          // client sees "connection closed while receiving data".
          await req.response.close();
          return;
        }
        final gate = gateAfter;
        if (gate != null && gate > start && gate < payload.length) {
          req.response.add(body.sublist(0, gate - start));
          await req.response.flush();
          await gateRelease.future;
          req.response.add(body.sublist(gate - start));
        } else {
          req.response.add(body);
        }
        await req.response.close();
      } catch (_) {
        // Aborted transfer (pause/remove) — expected in these tests.
      }
    });
  });

  tearDown(() async {
    if (!gateRelease.isCompleted) gateRelease.complete();
    await server.close(force: true);
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  test('enqueue downloads the file to disk and records done', () async {
    final manager = DownloadManager(base: base, directory: dir);
    await manager.enqueue(entry('Movie.mkv', _addrA));
    await waitFor(() =>
        manager.taskFor(_addrA)?.status == DownloadStatus.done);
    final task = manager.taskFor(_addrA)!;
    expect(task.totalBytes, payload.length);
    expect(task.downloadedBytes, payload.length);
    expect(File(task.filePath).readAsBytesSync(), payload);
    expect(task.filePath, '${dir.path}/Movie.mkv');
    expect(manager.localPathIfDone(entry('Movie.mkv', _addrA)),
        task.filePath);
  });

  test('address is normalized and 0x-prefixed lookups match', () async {
    final manager = DownloadManager(base: base, directory: dir);
    await manager.enqueue(entry('Movie.mkv', '0x${_addrA.toUpperCase()}'));
    await waitFor(() =>
        manager.taskFor(_addrA)?.status == DownloadStatus.done);
    expect(manager.taskFor('0x$_addrA'), isNotNull);
  });

  test('pause aborts mid-transfer; resume continues with a Range request',
      () async {
    gateAfter = 16 * 1024;
    final manager = DownloadManager(base: base, directory: dir);
    await manager.enqueue(entry('Movie.mkv', _addrA));
    await waitFor(() =>
        manager.taskFor(_addrA)?.status == DownloadStatus.downloading);
    // Let the gated first chunk reach the client before pausing.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await manager.pause(_addrA);
    await waitFor(
        () => manager.taskFor(_addrA)?.status == DownloadStatus.paused);
    final partial = File(manager.taskFor(_addrA)!.filePath);
    expect(partial.lengthSync(), greaterThan(0));
    expect(partial.lengthSync(), lessThan(payload.length));

    gateAfter = null;
    await manager.resume(_addrA);
    await waitFor(() =>
        manager.taskFor(_addrA)?.status == DownloadStatus.done);
    expect(partial.readAsBytesSync(), payload);
    expect(rangesSeen.first, isNull);
    expect(rangesSeen.last, startsWith('bytes='));
  });

  test('tasks persist; a mid-flight row re-queues and finishes', () async {
    // Simulate a download the app died in the middle of: a `downloading`
    // row plus a partial file on disk.
    const half = 32 * 1024;
    final path = '${dir.path}/Movie.mkv';
    File(path).writeAsBytesSync(payload.sublist(0, half));
    await db.into(db.downloads).insert(DownloadsCompanion.insert(
          address: _addrA,
          name: 'Movie.mkv',
          filePath: path,
          totalBytes: const Value(0),
          downloadedBytes: const Value(half),
          status: 'downloading',
          createdAt: 1,
          updatedAt: 1,
        ));
    final manager = DownloadManager(base: base, directory: dir);
    await manager.ensureLoaded();
    await waitFor(() =>
        manager.taskFor(_addrA)?.status == DownloadStatus.done);
    expect(rangesSeen.single, 'bytes=$half-');
    expect(File(path).readAsBytesSync(), payload);
  });

  test('remove deletes the file and the database row', () async {
    final manager = DownloadManager(base: base, directory: dir);
    await manager.enqueue(entry('Movie.mkv', _addrA));
    await waitFor(() =>
        manager.taskFor(_addrA)?.status == DownloadStatus.done);
    final path = manager.taskFor(_addrA)!.filePath;
    await manager.remove(_addrA);
    expect(manager.taskFor(_addrA), isNull);
    expect(File(path).existsSync(), isFalse);
    final rows = await db.select(db.downloads).get();
    expect(rows, isEmpty);
    // A fresh manager over the same database sees nothing either.
    final reloaded = DownloadManager(base: base, directory: dir);
    await reloaded.ensureLoaded();
    expect(reloaded.tasks, isEmpty);
  });

  test('removeMany deletes every given download, files included', () async {
    final manager = DownloadManager(base: base, directory: dir);
    await manager.enqueue(entry('A.mkv', _addrA));
    await manager.enqueue(entry('B.mkv', _addrB));
    await waitFor(() =>
        manager.taskFor(_addrA)?.status == DownloadStatus.done &&
        manager.taskFor(_addrB)?.status == DownloadStatus.done);
    final paths = [for (final t in manager.tasks) t.filePath];
    await manager.removeMany([for (final t in manager.tasks) t.address]);
    expect(manager.tasks, isEmpty);
    for (final path in paths) {
      expect(File(path).existsSync(), isFalse);
    }
    expect(await db.select(db.downloads).get(), isEmpty);
  });

  test('pauseAllForPlayback spares manual pauses on resume', () async {
    gateAfter = 16 * 1024;
    final manager = DownloadManager(base: base, directory: dir);
    await manager.enqueue(entry('A.mkv', _addrA));
    await manager.enqueue(entry('B.mkv', _addrB));
    await waitFor(() =>
        manager.taskFor(_addrA)?.status == DownloadStatus.downloading);
    // B waits in the queue; pause it by hand first.
    await manager.pause(_addrB);
    final paused = await manager.pauseAllForPlayback();
    expect(paused, isTrue);
    await waitFor(
        () => manager.taskFor(_addrA)?.status == DownloadStatus.paused);
    expect(manager.hasActive, isFalse);

    gateAfter = null;
    if (!gateRelease.isCompleted) gateRelease.complete();
    final resumed = await manager.resumeAfterPlayback();
    expect(resumed, isTrue);
    // Only A (paused for playback) restarts; B stays manually paused.
    await waitFor(() =>
        manager.taskFor(_addrA)?.status == DownloadStatus.done);
    expect(manager.taskFor(_addrB)?.status, DownloadStatus.paused);
  });

  test('resumeAfterPlayback with nothing paused reports false', () async {
    final manager = DownloadManager(base: base, directory: dir);
    expect(await manager.resumeAfterPlayback(), isFalse);
  });

  test('connection loss mid-transfer auto-pauses; resume finishes the file',
      () async {
    dropAfter = 16 * 1024;
    healthBody = {'state': 'ready', 'peers': 0}; // network gone
    final manager = DownloadManager(base: base, directory: dir);
    await manager.enqueue(entry('Movie.mkv', _addrA));
    await waitFor(
        () => manager.taskFor(_addrA)?.status == DownloadStatus.paused);
    final task = manager.taskFor(_addrA)!;
    expect(task.error, isNull);
    expect(task.downloadedBytes, lessThan(payload.length));

    // Network back: resume picks up from the bytes on disk.
    dropAfter = null;
    healthBody = {'state': 'ready', 'peers': 5};
    await manager.resume(_addrA);
    await waitFor(() =>
        manager.taskFor(_addrA)?.status == DownloadStatus.done);
    expect(File(task.filePath).readAsBytesSync(), payload);
  });

  test('still connecting counts as connection loss (auto-pause)', () async {
    dropAfter = 16 * 1024;
    healthBody = {'state': 'connecting', 'attempts': 3};
    final manager = DownloadManager(base: base, directory: dir);
    await manager.enqueue(entry('Movie.mkv', _addrA));
    await waitFor(
        () => manager.taskFor(_addrA)?.status == DownloadStatus.paused);
    expect(manager.taskFor(_addrA)!.error, isNull);
  });

  test('connection-loss pause is a system pause and auto-resumes when '
      'the monitor flips back online', () async {
    dropAfter = 16 * 1024;
    healthBody = {'state': 'ready', 'peers': 0}; // network gone
    var health = const ClientHealth(state: 'ready', peers: 0);
    final monitor = ConnectivityMonitor(
        probe: () async => health, kick: () async {});
    await monitor.refresh(); // now offline
    final manager = DownloadManager(base: base, directory: dir);
    manager.bindConnectivity(monitor);
    await manager.enqueue(entry('Movie.mkv', _addrA));
    await waitFor(
        () => manager.taskFor(_addrA)?.status == DownloadStatus.paused);
    expect(manager.taskFor(_addrA)!.pausedBySystem, isTrue);

    // Network back: the monitor flip alone must restart the download.
    dropAfter = null;
    healthBody = {'state': 'ready', 'peers': 5};
    health = const ClientHealth(state: 'ready', peers: 5);
    await monitor.refresh();
    await waitFor(
        () => manager.taskFor(_addrA)?.status == DownloadStatus.done);
    expect(manager.taskFor(_addrA)!.pausedBySystem, isFalse);
    expect(File(manager.taskFor(_addrA)!.filePath).readAsBytesSync(),
        payload);
  });

  test('a pause by hand never auto-resumes on reconnect', () async {
    var health = const ClientHealth(state: 'ready', peers: 0);
    final monitor = ConnectivityMonitor(
        probe: () async => health, kick: () async {});
    await monitor.refresh();
    final manager = DownloadManager(base: base, directory: dir);
    manager.bindConnectivity(monitor);
    gateAfter = 8 * 1024;
    await manager.enqueue(entry('Movie.mkv', _addrA));
    await waitFor(
        () => manager.taskFor(_addrA)?.status == DownloadStatus.downloading);
    await manager.pause(_addrA);
    gateRelease.complete();
    await waitFor(
        () => manager.taskFor(_addrA)?.status == DownloadStatus.paused);
    expect(manager.taskFor(_addrA)!.pausedBySystem, isFalse);

    health = const ClientHealth(state: 'ready', peers: 5);
    await monitor.refresh(); // back online
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(manager.taskFor(_addrA)!.status, DownloadStatus.paused);
  });

  test('system-paused rows auto-resume on the next launch while online',
      () async {
    dropAfter = 16 * 1024;
    healthBody = {'state': 'ready', 'peers': 0};
    final first = DownloadManager(base: base, directory: dir);
    await first.enqueue(entry('Movie.mkv', _addrA));
    await waitFor(
        () => first.taskFor(_addrA)?.status == DownloadStatus.paused);
    expect(first.taskFor(_addrA)!.pausedBySystem, isTrue);

    // "Restart": a fresh manager over the same database, now online.
    dropAfter = null;
    healthBody = {'state': 'ready', 'peers': 5};
    final monitor = ConnectivityMonitor(
        probe: () async => const ClientHealth(state: 'ready', peers: 5),
        kick: () async {});
    final second = DownloadManager(base: base, directory: dir);
    second.bindConnectivity(monitor);
    await second.ensureLoaded();
    await waitFor(
        () => second.taskFor(_addrA)?.status == DownloadStatus.done);
    expect(File(second.taskFor(_addrA)!.filePath).readAsBytesSync(),
        payload);
  });

  test('Wi-Fi-only policy holds the queue on cellular and releases it '
      'when Wi-Fi returns', () async {
    // Default policy is Wi-Fi only; start on cellular.
    final transport = StreamController<List<ConnectivityResult>>.broadcast();
    final network = NetworkEvents(
        stream: transport.stream,
        check: () async => [ConnectivityResult.mobile]);
    network.start();
    await Future<void>.delayed(Duration.zero);
    final manager = DownloadManager(base: base, directory: dir);
    manager.bindNetwork(network);

    await manager.enqueue(entry('Movie.mkv', _addrA));
    await waitFor(
        () => manager.taskFor(_addrA)?.status == DownloadStatus.paused);
    expect(manager.taskFor(_addrA)!.pausedBySystem, isTrue);
    expect(manager.waitingForWifi, isTrue);
    expect(rangesSeen, isEmpty); // never even started a transfer

    // Wi-Fi back: queue releases by itself.
    transport.add([ConnectivityResult.wifi]);
    await waitFor(
        () => manager.taskFor(_addrA)?.status == DownloadStatus.done);
    expect(manager.waitingForWifi, isFalse);
    expect(File(manager.taskFor(_addrA)!.filePath).readAsBytesSync(),
        payload);
    await transport.close();
  });

  test('Wi-Fi + mobile data policy downloads on cellular', () async {
    SharedPreferences.setMockInitialValues({
      'download_network_v1': 'any',
    });
    final network = NetworkEvents(
        stream: const Stream.empty(),
        check: () async => [ConnectivityResult.mobile]);
    network.start();
    await Future<void>.delayed(Duration.zero);
    final manager = DownloadManager(base: base, directory: dir);
    manager.bindNetwork(network);
    await manager.enqueue(entry('Movie.mkv', _addrA));
    await waitFor(
        () => manager.taskFor(_addrA)?.status == DownloadStatus.done);
  });

  test('going cellular mid-transfer pauses a running download', () async {
    final transport = StreamController<List<ConnectivityResult>>.broadcast();
    final network = NetworkEvents(
        stream: transport.stream,
        check: () async => [ConnectivityResult.wifi]);
    network.start();
    await Future<void>.delayed(Duration.zero);
    final manager = DownloadManager(base: base, directory: dir);
    manager.bindNetwork(network);
    gateAfter = 8 * 1024; // hold the transfer mid-flight
    await manager.enqueue(entry('Movie.mkv', _addrA));
    await waitFor(
        () => manager.taskFor(_addrA)?.status == DownloadStatus.downloading);

    transport.add([ConnectivityResult.mobile]);
    await waitFor(
        () => manager.taskFor(_addrA)?.status == DownloadStatus.paused);
    expect(manager.taskFor(_addrA)!.pausedBySystem, isTrue);
    expect(manager.waitingForWifi, isTrue);
    gateRelease.complete();
    await transport.close();
  });

  test('a transfer failure while online is still an error', () async {
    dropAfter = 16 * 1024;
    final manager = DownloadManager(base: base, directory: dir);
    await manager.enqueue(entry('Movie.mkv', _addrA));
    await waitFor(
        () => manager.taskFor(_addrA)?.status == DownloadStatus.error);
    expect(manager.taskFor(_addrA)!.error, isNotNull);
  });

  test('no embedded client marks the task failed; resume retries', () async {
    final manager = DownloadManager(directory: dir); // base null
    await manager.enqueue(entry('Movie.mkv', _addrA));
    await waitFor(() =>
        manager.taskFor(_addrA)?.status == DownloadStatus.error);
    expect(manager.taskFor(_addrA)!.error, contains('unavailable'));
  });

  test('duplicate file names get address-prefixed paths', () async {
    final manager = DownloadManager(base: base, directory: dir);
    await manager.enqueue(entry('Same.mkv', _addrA));
    await manager.enqueue(entry('Same.mkv', _addrB));
    await waitFor(() =>
        manager.taskFor(_addrB)?.status == DownloadStatus.done);
    await waitFor(() =>
        manager.taskFor(_addrA)?.status == DownloadStatus.done);
    expect(manager.taskFor(_addrA)!.filePath,
        isNot(manager.taskFor(_addrB)!.filePath));
    expect(File(manager.taskFor(_addrB)!.filePath).lengthSync(),
        payload.length);
  });

  test('batchProgress counts a batch through to drain', () async {
    gateAfter = 16 * 1024;
    final manager = DownloadManager(base: base, directory: dir);
    expect(manager.batchProgress, isNull);

    await manager.enqueue(entry('A.mkv', _addrA));
    await manager.enqueue(entry('B.mkv', _addrB));
    await waitFor(() =>
        manager.taskFor(_addrA)?.status == DownloadStatus.downloading);
    // Let the transfer actually reach the server's gate before swapping
    // completers below — `downloading` is set before the request leaves.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    var batch = manager.batchProgress!;
    expect(batch.done, 0);
    expect(batch.total, 2);
    expect(batch.progress, lessThan(1.0));

    // First file finishes (the second gates on a fresh completer): the
    // finished one keeps counting while the second runs.
    final releaseA = gateRelease;
    gateRelease = Completer<void>();
    releaseA.complete();
    await waitFor(
        () => manager.taskFor(_addrA)?.status == DownloadStatus.done);
    await waitFor(() => manager.batchProgress?.done == 1);
    batch = manager.batchProgress!;
    expect(batch.total, 2);
    expect(batch.progress, greaterThanOrEqualTo(0.5));

    // Queue drains: the batch closes and the meter goes away.
    gateRelease.complete();
    await waitFor(
        () => manager.taskFor(_addrB)?.status == DownloadStatus.done);
    expect(manager.batchProgress, isNull);
  });

  test('batchProgress hides for a fully paused queue, restarts fresh',
      () async {
    gateAfter = 16 * 1024;
    final manager = DownloadManager(base: base, directory: dir);
    await manager.enqueue(entry('A.mkv', _addrA));
    await waitFor(() =>
        manager.taskFor(_addrA)?.status == DownloadStatus.downloading);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await manager.pause(_addrA);
    await waitFor(
        () => manager.taskFor(_addrA)?.status == DownloadStatus.paused);
    expect(manager.batchProgress, isNull);

    // Re-gate past the resume offset so the meter is observable while
    // the resumed transfer is under way.
    gateAfter = 32 * 1024;
    await manager.resume(_addrA);
    await waitFor(() => manager.batchProgress != null);
    expect(manager.batchProgress!.total, 1);
    gateRelease.complete();
    await waitFor(
        () => manager.taskFor(_addrA)?.status == DownloadStatus.done);
    expect(manager.batchProgress, isNull);
  });

  test('removing the only active download closes the batch', () async {
    gateAfter = 16 * 1024;
    final manager = DownloadManager(base: base, directory: dir);
    await manager.enqueue(entry('A.mkv', _addrA));
    await waitFor(() =>
        manager.taskFor(_addrA)?.status == DownloadStatus.downloading);
    expect(manager.batchProgress, isNotNull);
    await manager.remove(_addrA);
    expect(manager.batchProgress, isNull);
  });

  test('size labels', () {
    DownloadTask t(int done, int total) => DownloadTask(
          address: _addrA,
          name: 'x',
          filePath: 'x',
          totalBytes: total,
          downloadedBytes: done,
          status: DownloadStatus.downloading,
          createdAt: 0,
        );
    expect(downloadSizeLabel(t(512, 0)), '512 B');
    expect(downloadSizeLabel(t(1536, 1024 * 1024 * 1024)),
        '2 KB of 1.00 GB');
    expect(t(512, 1024).progress, 0.5);
    expect(t(512, 0).progress, isNull);
  });
}
