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
