import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:watchit/models/media_list.dart';
import 'package:watchit/services/datamap_prefetch.dart';
import 'package:watchit/services/prefetch_manager.dart';

const _addrA =
    'a3f1c9e07b6d5a4f2e8c1b0d9f7a6e5c4b3a2d1e0f9c8b7a6d5e4f3c2b1a0d9e';
const _addrB =
    'b4a2d0f18c7e6b5a3f9d2c1e0a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0';

void main() {
  late HttpServer server;
  late String base;
  final requested = <String>[];

  setUp(() async {
    requested.clear();
    DataMapPrefetcher.resetWarmedForTesting();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      requested.add(req.uri.pathSegments.last);
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'size': 1234, 'chunks': 3}));
      await req.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  MediaEntry e(String name, String addr) =>
      MediaEntry(name: name, address: addr);

  test('start runs to completion with observable progress', () async {
    final manager = PrefetchManager.instance;
    final seen = <(int, int, String)>[];
    manager.addListener(() {
      seen.add((manager.current, manager.total, manager.fileName));
    });
    expect(manager.running, isFalse);
    final run = manager.start(
      [e('First.mkv', _addrA), e('Second.mkv', _addrB)],
      base: base,
    );
    expect(manager.running, isTrue);
    final result = await run;
    expect(result.done, 2);
    expect(manager.running, isFalse);
    expect(seen, contains((1, 2, 'First.mkv')));
    expect(seen, contains((2, 2, 'Second.mkv')));
  });

  test('start while running returns the active run, not a second one',
      () async {
    final manager = PrefetchManager.instance;
    final first = manager.start([e('First.mkv', _addrA)], base: base);
    final second = manager.start([e('Second.mkv', _addrB)], base: base);
    expect(identical(first, second), isTrue);
    await first;
    expect(requested, [_addrA]); // the second entry list was never queued
  });

  test('cancel stops the active run', () async {
    final manager = PrefetchManager.instance;
    final run = manager.start(
      [e('First.mkv', _addrA), e('Second.mkv', _addrB)],
      base: base,
    );
    manager.cancel();
    final result = await run;
    expect(result.cancelled, isTrue);
    expect(manager.running, isFalse);
  });

  test('a new run can start after the previous one finished', () async {
    final manager = PrefetchManager.instance;
    await manager.start([e('First.mkv', _addrA)], base: base);
    final result =
        await manager.start([e('Second.mkv', _addrB)], base: base);
    expect(result.done, 1);
    expect(requested, [_addrA, _addrB]);
  });

  test('warm resolves an entry once per session', () async {
    expect(await DataMapPrefetcher.warm(e('M.mkv', _addrA), base: base),
        isTrue);
    expect(await DataMapPrefetcher.warm(e('M.mkv', _addrA), base: base),
        isFalse);
    expect(requested, [_addrA]);
  });

  test('warm failure allows a retry on the next page open', () async {
    await server.close(force: true);
    expect(await DataMapPrefetcher.warm(e('M.mkv', _addrA), base: base),
        isFalse);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    // Rebind on a fresh port; the entry stays warm-able after the failure.
    server.listen((req) async {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'size': 1, 'chunks': 1}));
      await req.response.close();
    });
    expect(
        await DataMapPrefetcher.warm(e('M.mkv', _addrA),
            base: 'http://127.0.0.1:${server.port}'),
        isTrue);
  });

  test('summary lines', () {
    const ok = PrefetchResult(done: 3, failed: 0, cancelled: false);
    const partial = PrefetchResult(done: 2, failed: 1, cancelled: false);
    const stopped = PrefetchResult(done: 1, failed: 0, cancelled: true);
    expect(prefetchSummary(ok, 3), 'Prefetched 3 data maps');
    expect(prefetchSummary(partial, 3),
        contains('1 failed — those resolve on first play'));
    expect(prefetchSummary(stopped, 3),
        contains('Prefetch cancelled — 1 of 3 data maps saved'));
    expect(prefetchSummary(stopped, 3), contains('Resume any time'));
  });
}
