import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/services/list_import.dart';

const _addrA =
    '66cacd06ae5b02aeb0b4b8a463885bd7ec392b1b4291c1eda75253e831c1bcbb';
const _addrB =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _addrC =
    'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';

void main() {
  group('parseMediaListFile (single list)', () {
    test('parses name line plus entries', () {
      final parsed = parseMediaListFile(
        'My Movies\n'
        '$_addrA Some Movie (2024) [1080p].mkv\n'
        '$_addrB Another Movie (1999).mp4\n',
      );
      final list = parsed.lists.single;
      expect(list.title, 'My Movies');
      expect(list.entries, hasLength(2));
      expect(list.entries[0].name, 'Some Movie (2024) [1080p].mkv');
      expect(list.entries[0].address, _addrA);
      expect(list.entries[1].name, 'Another Movie (1999).mp4');
      expect(parsed.skippedLines, isEmpty);
      expect(parsed.entryCount, 2);
    });

    test('handles CRLF, blank lines, surrounding whitespace and 0x prefix',
        () {
      final parsed = parseMediaListFile(
        '  Weekend Watchlist \r\n'
        '\r\n'
        '  0x${_addrA.toUpperCase()}   Spaced Out (2020).mkv  \r\n'
        '\r\n',
      );
      final list = parsed.lists.single;
      expect(list.title, 'Weekend Watchlist');
      expect(list.entries, hasLength(1));
      expect(list.entries.single.address, _addrA);
      expect(list.entries.single.name, 'Spaced Out (2020).mkv');
    });

    test('skips malformed lines and reports their line numbers', () {
      final parsed = parseMediaListFile(
        'Mixed Bag\n'
        'not-an-address Some Movie.mkv\n'
        '$_addrA Good Movie.mkv\n'
        '$_addrB\n', // address without a file name
      );
      final list = parsed.lists.single;
      expect(list.entries, hasLength(1));
      expect(list.entries.single.name, 'Good Movie.mkv');
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

    test('rejects a file whose first line is a bare address', () {
      expect(() => parseMediaListFile('$_addrA\n$_addrB Movie.mkv\n'),
          throwsA(isA<ListImportException>()));
    });

    test('rejects a file with a name but no valid entries', () {
      expect(() => parseMediaListFile('Just A Name\nnot an entry\n'),
          throwsA(isA<ListImportException>()));
    });
  });

  group('parseMediaListFile (multi-list ListName= markers)', () {
    test('splits lists on ListName= markers, quotes optional', () {
      final parsed = parseMediaListFile(
        'ListName="TV Series"\n'
        '$_addrA Some Show S01E01.mkv\n'
        '$_addrB Some Show S01E02.mkv\n'
        'ListName=Movies\n'
        '$_addrC Some Movie (2024).mkv\n',
      );
      expect(parsed.lists, hasLength(2));
      expect(parsed.lists[0].title, 'TV Series');
      expect(parsed.lists[0].entries, hasLength(2));
      expect(parsed.lists[1].title, 'Movies');
      expect(parsed.lists[1].entries.single.address, _addrC);
      expect(parsed.skippedLines, isEmpty);
      expect(parsed.entryCount, 3);
    });

    test('marker keyword is case-insensitive and tolerates spacing', () {
      final parsed = parseMediaListFile(
        '  listname = "Late Night"  \n'
        '$_addrA A Movie.mkv\n',
      );
      expect(parsed.lists.single.title, 'Late Night');
    });

    test('a legacy header file can append marker sections', () {
      final parsed = parseMediaListFile(
        'My Movies\n'
        '$_addrA First.mkv\n'
        'ListName="TV Series"\n'
        '$_addrB Pilot.mkv\n',
      );
      expect(parsed.lists, hasLength(2));
      expect(parsed.lists[0].title, 'My Movies');
      expect(parsed.lists[1].title, 'TV Series');
    });

    test('repeated list names in one file are folded together', () {
      final parsed = parseMediaListFile(
        'ListName="Movies"\n'
        '$_addrA First.mkv\n'
        'ListName="TV Series"\n'
        '$_addrB Pilot.mkv\n'
        'ListName="movies"\n'
        '$_addrC Second.mkv\n',
      );
      expect(parsed.lists, hasLength(2));
      expect(parsed.lists[0].title, 'Movies');
      expect(parsed.lists[0].entries, hasLength(2));
      expect(parsed.lists[0].entries[1].address, _addrC);
    });

    test('a marker with an empty name is skipped and reported', () {
      final parsed = parseMediaListFile(
        'ListName="Movies"\n'
        '$_addrA First.mkv\n'
        'ListName=""\n'
        '$_addrB Second.mkv\n',
      );
      expect(parsed.lists.single.entries, hasLength(2));
      expect(parsed.skippedLines, [3]);
    });

    test('sections without valid entries are dropped', () {
      final parsed = parseMediaListFile(
        'ListName="Empty"\n'
        'ListName="Movies"\n'
        '$_addrA First.mkv\n',
      );
      expect(parsed.lists.single.title, 'Movies');
    });

    test('rejects a marker file with no valid entries at all', () {
      expect(
        () => parseMediaListFile('ListName="Empty"\nnot an entry\n'),
        throwsA(isA<ListImportException>()),
      );
    });
  });

  test('list-file cap is 10MB', () {
    expect(kMaxListFileBytes, 10 * 1024 * 1024);
  });

  group('serializeMediaList (export)', () {
    MediaList list(String title, List<(String, String)> entries) => MediaList(
          id: 'x',
          title: title,
          entries: [
            for (final (addr, name) in entries)
              MediaEntry(address: addr, name: name),
          ],
        );

    test('writes the marker form import reads', () {
      final text = serializeMediaList(list('Movies', [
        (_addrA, 'Movie.2020.mkv'),
        (_addrB, 'Other Movie (2021).mp4'),
      ]));
      expect(text, 'ListName="Movies"\n'
          '$_addrA Movie.2020.mkv\n'
          '$_addrB Other Movie (2021).mp4\n');
    });

    test('round-trips through parseMediaListFile', () {
      final text = serializeMediaList(list('My Shows', [
        (_addrA, 'Show.S01E01.mkv'),
        (_addrB, 'Show.S01E02.mkv'),
      ]));
      final parsed = parseMediaListFile(text);
      expect(parsed.skippedLines, isEmpty);
      expect(parsed.lists, hasLength(1));
      expect(parsed.lists.single.title, 'My Shows');
      expect(parsed.lists.single.entries.map((e) => e.name),
          ['Show.S01E01.mkv', 'Show.S01E02.mkv']);
      expect(parsed.lists.single.entries.map((e) => e.address),
          [_addrA, _addrB]);
    });

    test('concatenated exports re-import as a multi-list file', () {
      final text = serializeMediaList(list('A', [(_addrA, 'a.mkv')])) +
          serializeMediaList(list('B', [(_addrB, 'b.mkv'), (_addrC, 'c.mkv')]));
      final parsed = parseMediaListFile(text);
      expect(parsed.lists.map((l) => l.title), ['A', 'B']);
      expect(parsed.lists[1].entries, hasLength(2));
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
          // Oversized (>10MB) response, no Content-Length up front.
          req.response.bufferOutput = false;
          final chunk = List<int>.filled(1024 * 1024, 0x61);
          for (var i = 0; i < 12; i++) {
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
      expect(parsed.lists.single.title, 'List From Net');
      expect(parsed.lists.single.entries.single.address, _addrB);
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
