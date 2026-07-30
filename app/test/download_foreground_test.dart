import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/services/download_foreground.dart';
import 'package:watchit/services/download_manager.dart';
import 'package:watchit/services/library_store.dart';

DownloadTask task(String addr, DownloadStatus status,
        {int done = 0, int total = 100}) =>
    DownloadTask(
      address: addr,
      name: 'Movie-$addr.mkv',
      filePath: '/tmp/Movie-$addr.mkv',
      totalBytes: total,
      downloadedBytes: done,
      status: status,
      createdAt: 1,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('watchit/downloads');
  late List<MethodCall> calls;
  late DownloadManager manager;
  late DownloadForegroundBridge bridge;

  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() async {
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'manufacturer') return 'samsung';
      return true;
    });
    manager = DownloadManager();
    bridge = DownloadForegroundBridge(channel: channel, isAndroid: true);
    bridge.bind(manager);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> settle() async {
    // Let the throttled sync land (first event syncs immediately, but
    // the calls themselves are async).
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  test('queue going active starts the service (after asking for '
      'notifications); draining stops it', () async {
    manager.debugStageTask(
        task('a', DownloadStatus.downloading, done: 43, total: 100));
    await settle();
    expect(calls.map((c) => c.method).toList(),
        ['requestNotifications', 'start']);
    final args = calls.last.arguments as Map<Object?, Object?>;
    expect(args['percent'], 43);
    expect(args['text'], 'Movie-a.mkv');

    calls.clear();
    manager.debugStageTask(task('a', DownloadStatus.done, done: 100));
    // The immediate-window sync already fired for the first event; this
    // one lands via the trailing timer.
    await Future<void>.delayed(
        DownloadForegroundBridge.syncInterval * 2);
    expect(calls.map((c) => c.method), contains('stop'));
  });

  test('progress updates are throttled to ~1/s', () async {
    manager.debugStageTask(
        task('a', DownloadStatus.downloading, done: 1, total: 100));
    await settle();
    calls.clear();
    // A burst of progress events within one interval…
    for (var done = 2; done <= 30; done++) {
      manager.debugStageTask(
          task('a', DownloadStatus.downloading, done: done, total: 100));
    }
    await Future<void>.delayed(
        DownloadForegroundBridge.syncInterval * 2);
    // …collapses into at most a couple of channel calls.
    expect(calls.length, lessThanOrEqualTo(2));
    expect(calls.map((c) => c.method).toSet(), {'update'});
  });

  test('platform onTimeout system-pauses the queue', () async {
    manager.debugStageTask(
        task('a', DownloadStatus.downloading, done: 10, total: 100));
    manager.debugStageTask(task('b', DownloadStatus.queued));
    await settle();

    const codec = StandardMethodCodec();
    await TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .handlePlatformMessage(
      'watchit/downloads',
      codec.encodeMethodCall(const MethodCall('onTimeout')),
      (_) {},
    );
    await settle();

    for (final addr in ['a', 'b']) {
      final t = manager.taskFor(addr)!;
      expect(t.status, DownloadStatus.paused);
      expect(t.pausedBySystem, isTrue,
          reason: 'timeout pauses must auto-resume on reopen');
    }
  });

  test('manufacturer comes over the channel, lowercased', () async {
    expect(await bridge.manufacturer(), 'samsung');
  });

  test('non-Android bridge never touches the channel', () async {
    final desktop =
        DownloadForegroundBridge(channel: channel, isAndroid: false);
    final m = DownloadManager();
    desktop.bind(m);
    m.debugStageTask(task('a', DownloadStatus.downloading));
    await settle();
    expect(await desktop.manufacturer(), '');
    expect(calls.where((c) => c.method != 'manufacturer'), isEmpty);
  });
}
