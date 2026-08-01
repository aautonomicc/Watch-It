import 'package:flutter_test/flutter_test.dart';
import 'package:watchit/services/list_import.dart';

const _addrA =
    '66cacd06ae5b02aeb0b4b8a463885bd7ec392b1b4291c1eda75253e831c1bcbb';
const _addrB =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

void main() {
  group('parseMediaListFile (single list)', () {
    test('parses name line plus member entries', () {
      final parsed = parseMediaListFile(
        'My Movies\n'
        'Some Movie (2024) [1080p].mkv.datamap\n'
        'Another Movie (1999).mp4.datamap\n',
      );
      final list = parsed.lists.single;
      expect(list.title, 'My Movies');
      expect(list.datamapRefs, [
        'Some Movie (2024) [1080p].mkv.datamap',
        'Another Movie (1999).mp4.datamap',
      ]);
      expect(list.entries, isEmpty);
      expect(parsed.skippedLines, isEmpty);
      expect(parsed.entryCount, 2);
    });

    test('handles CRLF, blank lines and surrounding whitespace', () {
      final parsed = parseMediaListFile(
        '  Weekend Watchlist \r\n'
        '\r\n'
        '  Spaced Out (2020).mkv.datamap  \r\n'
        '\r\n',
      );
      final list = parsed.lists.single;
      expect(list.title, 'Weekend Watchlist');
      expect(list.datamapRefs, ['Spaced Out (2020).mkv.datamap']);
    });

    test('skips malformed lines and reports their line numbers', () {
      final parsed = parseMediaListFile(
        'Mixed Bag\n'
        'not a member line\n'
        'Good Movie.mkv.datamap\n',
      );
      final list = parsed.lists.single;
      expect(list.datamapRefs, ['Good Movie.mkv.datamap']);
      expect(parsed.skippedLines, [2]);
    });

    test('rejects an empty file', () {
      expect(() => parseMediaListFile('  \n \n'),
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
        'Some Show S01E01.mkv.datamap\n'
        'Some Show S01E02.mkv.datamap\n'
        'ListName=Movies\n'
        'Some Movie (2024).mkv.datamap\n',
      );
      expect(parsed.lists, hasLength(2));
      expect(parsed.lists[0].title, 'TV Series');
      expect(parsed.lists[0].datamapRefs, hasLength(2));
      expect(parsed.lists[1].title, 'Movies');
      expect(parsed.lists[1].datamapRefs,
          ['Some Movie (2024).mkv.datamap']);
      expect(parsed.skippedLines, isEmpty);
      expect(parsed.entryCount, 3);
    });

    test('marker keyword is case-insensitive and tolerates spacing', () {
      final parsed = parseMediaListFile(
        '  listname = "Late Night"  \n'
        'A Movie.mkv.datamap\n',
      );
      expect(parsed.lists.single.title, 'Late Night');
    });

    test('a legacy header file can append marker sections', () {
      final parsed = parseMediaListFile(
        'My Movies\n'
        'First.mkv.datamap\n'
        'ListName="TV Series"\n'
        'Pilot.mkv.datamap\n',
      );
      expect(parsed.lists, hasLength(2));
      expect(parsed.lists[0].title, 'My Movies');
      expect(parsed.lists[1].title, 'TV Series');
    });

    test('repeated list names in one file are folded together', () {
      final parsed = parseMediaListFile(
        'ListName="Movies"\n'
        'First.mkv.datamap\n'
        'ListName="TV Series"\n'
        'Pilot.mkv.datamap\n'
        'ListName="movies"\n'
        'Second.mkv.datamap\n',
      );
      expect(parsed.lists, hasLength(2));
      expect(parsed.lists[0].title, 'Movies');
      expect(parsed.lists[0].datamapRefs,
          ['First.mkv.datamap', 'Second.mkv.datamap']);
    });

    test('a marker with an empty name is skipped and reported', () {
      final parsed = parseMediaListFile(
        'ListName="Movies"\n'
        'First.mkv.datamap\n'
        'ListName=""\n'
        'Second.mkv.datamap\n',
      );
      expect(parsed.lists.single.datamapRefs, hasLength(2));
      expect(parsed.skippedLines, [3]);
    });

    test('sections without valid entries are dropped', () {
      final parsed = parseMediaListFile(
        'ListName="Empty"\n'
        'ListName="Movies"\n'
        'First.mkv.datamap\n',
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

  group('parseMediaListFile (v1 hex lines no longer import)', () {
    test('hex lines are skipped, member lines still parse', () {
      final parsed = parseMediaListFile(
        'ListName="Mixed"\n'
        '$_addrA Old Movie (1968).mp4\n'
        'New Movie (2024).mkv.datamap\n',
      );
      final list = parsed.lists.single;
      expect(list.entries, isEmpty);
      expect(list.datamapRefs, ['New Movie (2024).mkv.datamap']);
      expect(parsed.skippedLines, [2]);
      expect(parsed.entryCount, 1);
    });

    test('an all-v1 file throws the re-export error', () {
      expect(
        () => parseMediaListFile('My Movies\n'
            '$_addrA Some Movie (2024) [1080p].mkv\n'
            '$_addrB Another Movie (1999).mp4\n'),
        throwsA(isA<ListImportException>().having(
            (e) => e.message, 'message', contains('Re-export'))),
      );
    });

    test('a file starting with a hex entry throws the re-export error', () {
      expect(
        () => parseMediaListFile('$_addrA Some Movie.mkv\n'
            '$_addrB Other Movie.mkv\n'),
        throwsA(isA<ListImportException>().having(
            (e) => e.message, 'message', contains('Re-export'))),
      );
    });

    test('a bare address first line throws the re-export error', () {
      expect(
        () => parseMediaListFile('$_addrA\n$_addrB Movie.mkv\n'),
        throwsA(isA<ListImportException>().having(
            (e) => e.message, 'message', contains('Re-export'))),
      );
    });
  });

  group('parseMediaListFile (v2 .datamap member lines)', () {
    test('member lines collect as datamapRefs, addressless', () {
      final parsed = parseMediaListFile(
        'ListName="TV Series"\n'
        'Some Show S01E01 (2023) [1080p].mkv.datamap\n'
        'Some Show S01E02 (2023) [1080p].mkv.datamap\n'
        'ListName="Movies"\n'
        'Some Movie (2024) [2160p].mp4.datamap\n',
      );
      expect(parsed.lists, hasLength(2));
      expect(parsed.lists[0].datamapRefs, [
        'Some Show S01E01 (2023) [1080p].mkv.datamap',
        'Some Show S01E02 (2023) [1080p].mkv.datamap',
      ]);
      expect(parsed.lists[0].entries, isEmpty);
      expect(parsed.lists[1].datamapRefs,
          ['Some Movie (2024) [2160p].mp4.datamap']);
      expect(parsed.entryCount, 3);
    });

    test('a bare .datamap suffix with nothing before it is skipped', () {
      final parsed = parseMediaListFile(
        'ListName="Movies"\n'
        'Some Movie (2024).mkv.datamap\n'
        '.datamap\n',
      );
      expect(parsed.lists.single.datamapRefs,
          ['Some Movie (2024).mkv.datamap']);
      expect(parsed.skippedLines, [3]);
    });

    test('a section holding only member refs survives', () {
      final parsed = parseMediaListFile(
        'ListName="Only Refs"\n'
        'A.mkv.datamap\n',
      );
      expect(parsed.lists.single.title, 'Only Refs');
    });
  });
}
