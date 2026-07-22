import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watchit/services/list_import.dart';

const _addrA =
    '66cacd06ae5b02aeb0b4b8a463885bd7ec392b1b4291c1eda75253e831c1bcbb';
const _addrB =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

void main() {
  group('parseMediaListFile', () {
    test('parses name line plus entries', () {
      final parsed = parseMediaListFile(
        'My Movies\n'
        '$_addrA Some Movie (2024) [1080p].mkv\n'
        '$_addrB Another Movie (1999).mp4\n',
      );
      expect(parsed.title, 'My Movies');
      expect(parsed.entries, hasLength(2));
      expect(parsed.entries[0].name, 'Some Movie (2024) [1080p].mkv');
      expect(parsed.entries[0].address, _addrA);
      expect(parsed.entries[1].name, 'Another Movie (1999).mp4');
      expect(parsed.skippedLines, isEmpty);
    });

    test('handles CRLF, blank lines, surrounding whitespace and 0x prefix',
        () {
      final parsed = parseMediaListFile(
        '  Weekend Watchlist \r\n'
        '\r\n'
        '  0x${_addrA.toUpperCase()}   Spaced Out (2020).mkv  \r\n'
        '\r\n',
      );
      expect(parsed.title, 'Weekend Watchlist');
      expect(parsed.entries, hasLength(1));
      expect(parsed.entries.single.address, _addrA);
      expect(parsed.entries.single.name, 'Spaced Out (2020).mkv');
    });

    test('skips malformed lines and reports their line numbers', () {
      final parsed = parseMediaListFile(
        'Mixed Bag\n'
        'not-an-address Some Movie.mkv\n'
        '$_addrA Good Movie.mkv\n'
        '$_addrB\n', // address without a file name
      );
      expect(parsed.entries, hasLength(1));
      expect(parsed.entries.single.name, 'Good Movie.mkv');
      expect(parsed.skippedLines, [2, 4]);
    });

    test('rejects an empty file', () {
      expect(() => parseMediaListFile('  \n \n'),
          throwsA(isA<ListImportException>()));
    });

    test('rejects a file whose first line is an entry (missing name line)',
        () {
      expect(
        () => parseMediaListFile('$_addrA Some Movie.mkv\n'
            '$_addrB Other Movie.mkv\n'),
        throwsA(isA<ListImportException>()),
      );
    });

    test('rejects a file with a name but no valid entries', () {
      expect(() => parseMediaListFile('Just A Name\nnot an entry\n'),
          throwsA(isA<ListImportException>()));
    });
  });

  group('fetchListFromNetwork', () {
    late HttpServer server;
    late String base;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((req) async {
        if (req.uri.path == '/xor/$_addrA') {
          req.response.write('List From Net\n$_addrB A Movie.mkv\n');
        } else if (req.uri.path == '/xor/$_addrB') {
          // Oversized response, no Content-Length up front.
          req.response.bufferOutput = false;
          final chunk = List<int>.filled(1024 * 1024, 0x61);
          for (var i = 0; i < 5; i++) {
            req.response.add(chunk);
            try {
              await req.response.flush();
            } catch (_) {
              break; // Client hung up after hitting its size cap.
            }
          }
        } else {
          req.response.statusCode = HttpStatus.notFound;
        }
        try {
          await req.response.close();
        } catch (_) {}
      });
    });

    tearDown(() => server.close(force: true));

    test('downloads and returns the list text', () async {
      final text = await fetchListFromNetwork('0x$_addrA', base: base);
      final parsed = parseMediaListFile(text);
      expect(parsed.title, 'List From Net');
      expect(parsed.entries.single.address, _addrB);
    });

    test('rejects an invalid address without touching the network', () {
      expect(() => fetchListFromNetwork('nope', base: base),
          throwsA(isA<ListImportException>()));
    });

    test('surfaces HTTP errors', () {
      expect(
        () => fetchListFromNetwork(
            'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
            base: base),
        throwsA(isA<ListImportException>()),
      );
    });

    test('refuses files larger than the list-file cap', () {
      expect(() => fetchListFromNetwork(_addrB, base: base),
          throwsA(isA<ListImportException>()));
    });
  });
}
