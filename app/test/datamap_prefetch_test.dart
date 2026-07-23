import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:watchit/models/media_list.dart';
import 'package:watchit/services/datamap_prefetch.dart';

const _addrA =
    'a3f1c9e07b6d5a4f2e8c1b0d9f7a6e5c4b3a2d1e0f9c8b7a6d5e4f3c2b1a0d9e';
const _addrB =
    'b4a2d0f18c7e6b5a3f9d2c1e0a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0';
const _addrBad =
    'c5b3e1a29d8f7c6b4a0e3d2f1b9c8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a2b1';

void main() {
  late HttpServer server;
  late String base;
  final requested = <String>[];

  setUp(() async {
    requested.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      final addr = req.uri.pathSegments.last;
      requested.add(addr);
      if (addr == _addrBad) {
        req.response.statusCode = HttpStatus.badGateway;
        req.response.write('resolve failed');
      } else {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'size': 1234, 'chunks': 3}));
      }
      await req.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  MediaEntry e(String name, String addr) =>
      MediaEntry(name: name, address: addr);

  test('resolves every entry sequentially with per-file progress', () async {
    final progress = <(int, int, String)>[];
    final result = await DataMapPrefetcher(base: base).run(
      [e('First.mkv', _addrA), e('Second.mkv', _addrB)],
      onProgress: (c, n, name) => progress.add((c, n, name)),
    );
    expect(result.done, 2);
    expect(result.failed, 0);
    expect(result.cancelled, isFalse);
    expect(progress, [(1, 2, 'First.mkv'), (2, 2, 'Second.mkv')]);
    expect(requested, [_addrA, _addrB]);
  });

  test('duplicate addresses resolve once', () async {
    final result = await DataMapPrefetcher(base: base).run([
      e('Copy 1.mkv', _addrA),
      e('Copy 2.mkv', _addrA.toUpperCase()),
    ]);
    expect(result.done, 1);
    expect(requested, hasLength(1));
  });

  test('a failing address is counted, the rest still resolve', () async {
    final result = await DataMapPrefetcher(base: base).run(
      [e('Bad.mkv', _addrBad), e('Good.mkv', _addrA)],
    );
    expect(result.done, 1);
    expect(result.failed, 1);
    expect(result.cancelled, isFalse);
  });

  test('cancel stops the run early', () async {
    final prefetcher = DataMapPrefetcher(base: base);
    final result = await prefetcher.run(
      [e('First.mkv', _addrA), e('Second.mkv', _addrB)],
      onProgress: (c, n, name) {
        if (c == 1) prefetcher.cancel();
      },
    );
    expect(result.cancelled, isTrue);
    expect(requested, isNot(contains(_addrB)));
  });

  test('unavailable without an embedded server', () {
    expect(DataMapPrefetcher(base: null).available, isFalse);
  });
}
