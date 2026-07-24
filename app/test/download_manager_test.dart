import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/services/download_manager.dart';
import 'package:watchit/services/library_store.dart';

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
