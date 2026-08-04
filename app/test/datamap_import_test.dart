import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:watchit/services/datamap_import.dart';
import 'package:watchit/services/list_import.dart' show ListImportException;

void main() {
  group('mediaNameFromDatamapFileName', () {
    test('strips the suffix, keeps everything else verbatim', () {
      expect(
          mediaNameFromDatamapFileName(
              'Night of the Living Dead (1968) [1080p].mp4.datamap'),
          'Night of the Living Dead (1968) [1080p].mp4');
      expect(mediaNameFromDatamapFileName('Makefile.datamap'), 'Makefile');
      // Path prefixes from pickers are dropped.
      expect(mediaNameFromDatamapFileName('/tmp/dir/Movie.mkv.DATAMAP'),
          'Movie.mkv');
    });

    test('rejects non-datamap names and empty stems', () {
      expect(mediaNameFromDatamapFileName('Movie.mkv'), isNull);
      expect(mediaNameFromDatamapFileName('.datamap'), isNull);
      expect(mediaNameFromDatamapFileName(''), isNull);
    });
  });

  group('isBundleDatamapName', () {
    test('matches only the .watch-list.datamap double suffix', () {
      expect(isBundleDatamapName('My Films.watch-list.datamap'), isTrue);
      expect(isBundleDatamapName('/tmp/LIB.WATCH-LIST.DATAMAP'), isTrue);
      // A plain media datamap, a bundle without a map suffix, and a
      // renamed map all fall through to the other import routes.
      expect(isBundleDatamapName('Movie (2020).mkv.datamap'), isFalse);
      expect(isBundleDatamapName('My Films.watch-list'), isFalse);
      expect(isBundleDatamapName('.datamap'), isFalse);
    });
  });

  group('importDatamapBytes / entryFromDatamapFile', () {
    late HttpServer server;
    late String base;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((req) async {
        final body = await req
            .fold<BytesBuilder>(BytesBuilder(), (b, c) => b..add(c));
        final bytes = body.takeBytes();
        if (req.method == 'POST' && req.uri.path == '/datamap') {
          if (bytes.length == 1 && bytes.first == 0xFF) {
            req.response.statusCode = 400;
          } else if (bytes.length == 1 && bytes.first == 0xEE) {
            // The offline shrunk-map case: the embedded client explains
            // that expanding this map needs the network.
            req.response.statusCode = 503;
            req.response.write(
                'this data map needs a one-time network lookup to finish '
                'importing, and the Autonomi client is not connected yet '
                '— try again once connected');
          } else {
            req.response.write(jsonEncode({
              'address': 'ab' * 32,
              'size': 1234,
              'chunks': 3,
            }));
          }
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    test('posts the raw bytes and returns the derived address', () async {
      final imported = await importDatamapBytes(
          Uint8List.fromList([1, 2, 3]),
          base: base);
      expect(imported.address, 'ab' * 32);
      expect(imported.size, 1234);
      expect(imported.chunks, 3);
    });

    test('builds the entry from the file name', () async {
      final entry = await entryFromDatamapFile(
          'The Movie (2024).mkv.datamap', Uint8List.fromList([1]),
          base: base);
      expect(entry.name, 'The Movie (2024).mkv');
      expect(entry.address, 'ab' * 32);
    });

    test('surfaces the server error text when the client sends one',
        () async {
      // A shrunk (child) map while offline: the embedded client returns
      // 503 with an actionable message — shown to the user instead of
      // the generic "could not be read" guess.
      try {
        await importDatamapBytes(Uint8List.fromList([0xEE]), base: base);
        fail('expected ListImportException');
      } on ListImportException catch (e) {
        expect(e.message, contains('one-time network lookup'));
        expect(e.message, contains('not connected'));
      }
    });

    test('surfaces server rejection and bad names as import errors', () {
      expect(
          () => importDatamapBytes(Uint8List.fromList([0xFF]), base: base),
          throwsA(isA<ListImportException>()));
      expect(
          () => entryFromDatamapFile(
              'not-a-datamap.mkv', Uint8List.fromList([1]),
              base: base),
          throwsA(isA<ListImportException>()));
      expect(() => importDatamapBytes(Uint8List(0), base: base),
          throwsA(isA<ListImportException>()));
    });
  });
}
