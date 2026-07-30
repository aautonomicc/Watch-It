import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:watchit/services/metadata.dart';
import 'package:watchit/services/rootmap_seeder.dart';

/// flutter_test installs a mock HttpClient that 400s every request; the
/// base HttpOverrides hands back the real dart:io client so the seeder
/// can talk to the local mock server.
class _RealHttp extends HttpOverrides {}

Future<void> seedWithRealHttp(String base) =>
    HttpOverrides.runWithHttpOverrides(
        () => seedBundledRootMaps(baseOverride: base), _RealHttp());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a bundled root-map asset exists for every seeded address '
      '(especially the default movie)', () async {
    expect(kBundledRootMapAddresses, contains(kDefaultMovieAddress));
    for (final address in kBundledRootMapAddresses) {
      final data = await rootBundle.load(bundledRootMapAsset(address));
      expect(data.lengthInBytes, greaterThan(0),
          reason: 'asset missing/empty for $address — a default-movie '
              'swap must ship a matching map in assets/rootmaps/');
    }
  });

  test('seeds over PUT when the server has no stored map', () async {
    final requests = <String>[];
    var putBytes = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      requests.add('${req.method} ${req.uri.path}');
      if (req.method == 'PUT') {
        putBytes = (await req.fold<BytesBuilder>(
                BytesBuilder(), (b, chunk) => b..add(chunk)))
            .length;
        req.response.statusCode = HttpStatus.noContent;
      } else {
        req.response.statusCode = HttpStatus.notFound;
      }
      await req.response.close();
    });

    await seedWithRealHttp('http://127.0.0.1:${server.port}');
    await server.close(force: true);

    expect(requests,
        ['GET /rootmap/$kDefaultMovieAddress', 'PUT /rootmap/$kDefaultMovieAddress']);
    final asset = await rootBundle.load(bundledRootMapAsset(kDefaultMovieAddress));
    expect(putBytes, asset.lengthInBytes);
  });

  test('skips the PUT when the map is already stored', () async {
    final requests = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      requests.add('${req.method} ${req.uri.path}');
      req.response.statusCode = HttpStatus.ok;
      await req.response.close();
    });

    await seedWithRealHttp('http://127.0.0.1:${server.port}');
    await server.close(force: true);

    expect(requests, ['GET /rootmap/$kDefaultMovieAddress']);
  });

  test('a dead server is silently ignored', () async {
    // Port from a just-closed server: connection refused.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    await server.close(force: true);
    await seedWithRealHttp('http://127.0.0.1:$port');
  });
}
