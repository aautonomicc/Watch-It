import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart'
    show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/services/bundle.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/list_import.dart';
import 'package:watchit/services/metadata.dart';
import 'package:watchit/services/watch_state.dart';

const _addrA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _addrB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

final _list = MediaList(
  id: 'l1',
  title: 'Horror Night',
  entries: const [
    MediaEntry(name: 'Night of the Living Dead (1968).mp4', address: _addrA),
    MediaEntry(name: 'The Movie (2024).mkv', address: _addrB),
  ],
);

String _lookupKey(String name) => parseMediaName(name).lookupKey;

Future<void> _seedMetadataRow(String fileName, {String? posterFile}) async {
  final db = await LibraryStore.database();
  await db.into(db.metadataCache).insertOnConflictUpdate(
        MetadataCacheCompanion.insert(
          lookupKey: _lookupKey(fileName),
          found: true,
          title: Value(fileName.split(' (').first),
          year: const Value(1968),
          overview: const Value('The dead rise.'),
          category: const Value('Horror'),
          posterFile: Value(posterFile),
          mediaType: const Value('movie'),
          tmdbId: const Value(10331),
          fetchedAt: 1000,
          rating: const Value(7.5),
        ),
      );
}

/// Fake embedded server for import/export tests.
///
/// - `POST /datamap`: body `[0xBA, 0xD1]` → 400; otherwise the derived
///   address is the first body byte spread over 64 hex chars, so tests
///   can predict it from the member bytes.
/// - `GET /datamap/<addr>`: serves [datamaps], else 404.
/// - `PUT /rootmap/<addr>`: body `[6, 6, 6]` → 422 (tampered), else 204;
///   bodies recorded in [rootmapPuts].
/// - `GET /resolve/<addr>`: 200 for [resolvable], else 502; calls
///   recorded in [resolves].
class _FakeEmbedded {
  _FakeEmbedded(this.server);

  final HttpServer server;
  final Map<String, List<int>> datamaps = {};
  final Set<String> resolvable = {};
  final Map<String, List<int>> rootmapPuts = {};
  final List<String> resolves = [];

  String get base => 'http://127.0.0.1:${server.port}';

  static String addrForByte(int byte) =>
      byte.toRadixString(16).padLeft(2, '0') * 32;

  static Future<_FakeEmbedded> start() async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    final fake = _FakeEmbedded(server);
    server.listen((req) async {
      final body = await req
          .fold<BytesBuilder>(BytesBuilder(), (b, chunk) => b..add(chunk));
      final bytes = body.takeBytes();
      final path = req.uri.path;
      if (req.method == 'POST' && path == '/datamap') {
        if (bytes.length >= 2 && bytes[0] == 0xBA && bytes[1] == 0xD1) {
          req.response.statusCode = 400;
        } else {
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({
            'address': addrForByte(bytes.isEmpty ? 0 : bytes.first),
            'size': 100,
            'chunks': 1,
          }));
        }
      } else if (req.method == 'GET' && path.startsWith('/datamap/')) {
        final addr = path.substring('/datamap/'.length);
        final map = fake.datamaps[addr];
        if (map == null) {
          req.response.statusCode = 404;
        } else {
          req.response.add(map);
        }
      } else if (req.method == 'PUT' && path.startsWith('/rootmap/')) {
        final addr = path.substring('/rootmap/'.length);
        if (bytes.length == 3 && bytes.every((b) => b == 6)) {
          req.response.statusCode = 422;
        } else {
          fake.rootmapPuts[addr] = bytes;
          req.response.statusCode = 204;
        }
      } else if (req.method == 'GET' && path.startsWith('/resolve/')) {
        final addr = path.substring('/resolve/'.length);
        fake.resolves.add(addr);
        if (fake.resolvable.contains(addr)) {
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({'size': 1, 'chunks': 1}));
        } else {
          req.response.statusCode = 502;
        }
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });
    return fake;
  }
}

ParsedBundle _bundle({
  String? listText,
  Map<String, Uint8List> datamapMembers = const {},
  Map<String, Map<String, dynamic>> metadataRows = const {},
  Map<String, Uint8List> posters = const {},
  Map<String, Uint8List> rootMaps = const {},
  Map<String, ({bool enabled, int position})> libraryPrefs = const {},
  Map<String, WatchState> history = const {},
}) =>
    ParsedBundle(
      listText: listText,
      datamapMembers: datamapMembers,
      metadataRows: metadataRows,
      posters: posters,
      rootMaps: rootMaps,
      libraryPrefs: libraryPrefs,
      history: history,
    );

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory postersDir;

  Future<Directory> postersDirProvider() async => postersDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    WatchStateStore.instance = WatchStateStore();
    postersDir = await Directory.systemTemp.createTemp('wi-bundle-posters');
  });

  tearDown(() async {
    if (postersDir.existsSync()) {
      postersDir.deleteSync(recursive: true);
    }
  });

  group('sniff', () {
    test('zip magic detected, text not', () {
      expect(looksLikeZip([0x50, 0x4B, 3, 4, 0]), isTrue);
      expect(looksLikeZip(utf8.encode('My List\n$_addrA a.mp4')), isFalse);
      expect(looksLikeZip([]), isFalse);
    });
  });

  group('datamapMemberName', () {
    test('appends .datamap and resolves collisions with an addr suffix',
        () {
      final taken = <String>{};
      expect(datamapMemberName('Movie (2024).mkv', _addrA, taken),
          'Movie (2024).mkv.datamap');
      expect(datamapMemberName('Movie (2024).mkv', _addrB, taken),
          'Movie (2024).mkv.${_addrB.substring(0, 8)}.datamap');
      expect(datamapMemberName('a/b\\c.mkv', _addrA, taken),
          'a_b_c.mkv.datamap');
    });
  });

  group('buildBundle', () {
    test('writes datamaps/ members and a member-line list.txt', () async {
      final fake = await _FakeEmbedded.start();
      addTearDown(() => fake.server.close(force: true));
      fake.datamaps[_addrA] = [9, 9, 9];
      // addrB has no stored map: skipped and counted.
      final result = await buildBundle(
        [_list],
        const BundleExportOptions(includeHistory: false),
        base: fake.base,
        postersDirProvider: postersDirProvider,
      );
      expect(result.entriesIncluded, 1);
      expect(result.entriesMissingMap, 1);
      final archive = ZipDecoder().decodeBytes(result.bytes);
      final member = archive.files.firstWhere((f) =>
          f.name ==
          'datamaps/Night of the Living Dead (1968).mp4.datamap');
      expect(member.readBytes(), [9, 9, 9]);
      final listTxt = utf8.decode(archive.files
          .firstWhere((f) => f.name == 'list.txt')
          .readBytes()!);
      expect(listTxt, 'ListName="Horror Night"\n'
          'Night of the Living Dead (1968).mp4.datamap\n');
    });

    test('same address in two lists shares one member, both lines',
        () async {
      final fake = await _FakeEmbedded.start();
      addTearDown(() => fake.server.close(force: true));
      fake.datamaps[_addrA] = [1, 2];
      final lists = [
        MediaList(id: 'a', title: 'One', entries: const [
          MediaEntry(name: 'Movie (2024).mkv', address: _addrA),
        ]),
        MediaList(id: 'b', title: 'Two', entries: const [
          MediaEntry(name: 'Movie (2024).mkv', address: _addrA),
        ]),
      ];
      final result = await buildBundle(
        lists,
        const BundleExportOptions(includeHistory: false),
        base: fake.base,
        postersDirProvider: postersDirProvider,
      );
      expect(result.entriesIncluded, 1);
      final archive = ZipDecoder().decodeBytes(result.bytes);
      expect(
          archive.files
              .where((f) => f.name.startsWith('datamaps/'))
              .length,
          1);
      final listTxt = utf8.decode(archive.files
          .firstWhere((f) => f.name == 'list.txt')
          .readBytes()!);
      expect(listTxt, 'ListName="One"\nMovie (2024).mkv.datamap\n'
          'ListName="Two"\nMovie (2024).mkv.datamap\n');
    });

    test('bundles cached metadata, posters, history and attribution',
        () async {
      await _seedMetadataRow('Night of the Living Dead (1968).mp4',
          posterFile: 'movie_10331.jpg');
      File('${postersDir.path}/movie_10331.jpg')
          .writeAsBytesSync([1, 2, 3, 4]);
      await WatchStateStore.instance.mergeAll([
        const WatchState(
          address: _addrA,
          positionMs: 60000,
          durationMs: 120000,
          completed: false,
          updatedAt: 5000,
        ),
      ]);

      final result = await buildBundle(
        [_list],
        const BundleExportOptions(includeHistory: true),
        base: null, // no embedded server: members skipped, extras still in
        postersDirProvider: postersDirProvider,
      );
      expect(result.entriesMissingMap, 2);
      final archive = ZipDecoder().decodeBytes(result.bytes);
      final names = archive.files.map((f) => f.name).toSet();
      expect(
          names,
          containsAll({
            'list.txt',
            'metadata.json',
            'posters/movie_10331.jpg',
            'history.json'
          }));

      final meta = jsonDecode(utf8.decode(archive.files
          .firstWhere((f) => f.name == 'metadata.json')
          .readBytes()!)) as Map<String, dynamic>;
      expect(meta['attribution'], kTmdbAttributionNotice);
      expect((meta['entries'] as List).single['title'],
          'Night of the Living Dead');

      final history = jsonDecode(utf8.decode(archive.files
          .firstWhere((f) => f.name == 'history.json')
          .readBytes()!)) as Map<String, dynamic>;
      expect((history['entries'] as List).single['address'], _addrA);
    });

    test('history stays out unless opted in; library.json on request',
        () async {
      await WatchStateStore.instance.mergeAll([
        const WatchState(
          address: _addrA,
          positionMs: 60000,
          durationMs: 120000,
          completed: false,
          updatedAt: 5000,
        ),
      ]);
      final result = await buildBundle(
        [_list],
        const BundleExportOptions(
          includeHistory: false,
          includeLibrary: true,
        ),
        base: null,
        postersDirProvider: postersDirProvider,
      );
      final archive = ZipDecoder().decodeBytes(result.bytes);
      final names = archive.files.map((f) => f.name).toSet();
      expect(names.contains('history.json'), isFalse);
      final library = jsonDecode(utf8.decode(archive.files
          .firstWhere((f) => f.name == 'library.json')
          .readBytes()!)) as Map<String, dynamic>;
      expect((library['lists'] as List).single['title'], 'Horror Night');
    });
  });

  group('parseBundle', () {
    Uint8List zipOf(Map<String, List<int>> members) {
      final archive = Archive();
      for (final e in members.entries) {
        archive.addFile(ArchiveFile.bytes(e.key, e.value));
      }
      return Uint8List.fromList(ZipEncoder().encode(archive));
    }

    test('round-trips what buildBundle wrote', () async {
      final fake = await _FakeEmbedded.start();
      addTearDown(() => fake.server.close(force: true));
      fake.datamaps[_addrA] = [9, 9];
      fake.datamaps[_addrB] = [8, 8];
      await _seedMetadataRow('Night of the Living Dead (1968).mp4',
          posterFile: 'movie_10331.jpg');
      File('${postersDir.path}/movie_10331.jpg')
          .writeAsBytesSync([1, 2, 3, 4]);
      final built = await buildBundle(
        [_list],
        const BundleExportOptions(includeHistory: false),
        base: fake.base,
        postersDirProvider: postersDirProvider,
      );
      final bundle = parseBundle(built.bytes);
      expect(bundle.datamapMembers.keys.toSet(), {
        'Night of the Living Dead (1968).mp4.datamap',
        'The Movie (2024).mkv.datamap',
      });
      expect(bundle.listText, contains('ListName="Horror Night"'));
      expect(bundle.metadataRows.keys,
          [_lookupKey('Night of the Living Dead (1968).mp4')]);
      expect(bundle.posters['movie_10331.jpg'], [1, 2, 3, 4]);
      expect(bundle.rootMaps, isEmpty);
      expect(bundle.history, isEmpty);
    });

    test('accepts a hand-made zip of loose .datamap files (no list.txt)',
        () {
      final bundle = parseBundle(zipOf({
        'Movie (2024).mkv.datamap': [1],
        'Show S01E01.mkv.datamap': [2],
      }));
      expect(bundle.listText, isNull);
      expect(bundle.datamapMembers.keys.toSet(),
          {'Movie (2024).mkv.datamap', 'Show S01E01.mkv.datamap'});
    });

    test('datamaps/ member wins over a root duplicate', () {
      final bundle = parseBundle(zipOf({
        'Movie.mkv.datamap': [1],
        'datamaps/Movie.mkv.datamap': [2],
      }));
      expect(bundle.datamapMembers['Movie.mkv.datamap'], [2]);
    });

    test('requires something importable', () {
      expect(
        () => parseBundle(zipOf({'metadata.json': utf8.encode('{}')})),
        throwsA(isA<ListImportException>()),
      );
    });

    test('rejects non-zip and unreadable input', () {
      expect(() => parseBundle(Uint8List.fromList([0x50, 0x4B, 1, 2, 3])),
          throwsA(isA<ListImportException>()));
    });

    test('drops hostile member names', () {
      final bytes = zipOf({
        'list.txt': utf8.encode('L\n$_addrA a.mp4\n'),
        'posters/../evil.jpg': [1],
        'posters/sub/dir.jpg': [2],
        'posters/ok.jpg': [3],
        'rootmaps/nothexnothexnothexnothexnothexnothexnothexnothexnothexnothexnoth.map':
            [4],
        'rootmaps/$_addrA.map': [5],
        'datamaps/../escape.mkv.datamap': [6],
        'datamaps/sub/dir.mkv.datamap': [7],
        'datamaps/ok.mkv.datamap': [8],
        '.datamap': [9], // nothing before the extension
        'unknown/member.bin': [10],
      });
      final bundle = parseBundle(bytes);
      expect(bundle.posters.keys, ['ok.jpg']);
      expect(bundle.rootMaps.keys, [_addrA]);
      expect(bundle.datamapMembers.keys, ['ok.mkv.datamap']);
    });

    test('oversized optional member is dropped, oversized list.txt fatal',
        () {
      final bigPoster = Uint8List(kMaxPosterBytes + 1);
      final ok = parseBundle(zipOf({
        'list.txt': utf8.encode('L\n$_addrA a.mp4\n'),
        'posters/huge.jpg': bigPoster,
      }));
      expect(ok.posters, isEmpty);

      final bigList = Uint8List(kMaxListFileBytes + 1);
      expect(
        () => parseBundle(zipOf({'list.txt': bigList})),
        throwsA(isA<ListImportException>()),
      );
    });
  });

  group('importBundleEntries', () {
    test('v2: refs assign members to lists, unclaimed go to the default',
        () async {
      final fake = await _FakeEmbedded.start();
      addTearDown(() => fake.server.close(force: true));
      final bundle = _bundle(
        listText: 'ListName="Movies"\nMovie (2024).mkv.datamap\n',
        datamapMembers: {
          'Movie (2024).mkv.datamap': Uint8List.fromList([1]),
          'Loose Show S01E01.mkv.datamap': Uint8List.fromList([2]),
        },
      );
      final result = await importBundleEntries(bundle,
          base: fake.base, defaultListTitle: 'My Bundle');
      expect(result.datamapsImported, 2);
      expect(result.lists.map((l) => l.title), ['Movies', 'My Bundle']);
      final movies = result.lists.first;
      expect(movies.entries.single.name, 'Movie (2024).mkv');
      expect(movies.entries.single.address, _FakeEmbedded.addrForByte(1));
      final loose = result.lists.last;
      expect(loose.entries.single.name, 'Loose Show S01E01.mkv');
      expect(loose.entries.single.address, _FakeEmbedded.addrForByte(2));
    });

    test('one member may be referenced from several lists', () async {
      final fake = await _FakeEmbedded.start();
      addTearDown(() => fake.server.close(force: true));
      final bundle = _bundle(
        listText: 'ListName="One"\nMovie.mkv.datamap\n'
            'ListName="Two"\nMovie.mkv.datamap\n',
        datamapMembers: {
          'Movie.mkv.datamap': Uint8List.fromList([3]),
        },
      );
      final result = await importBundleEntries(bundle, base: fake.base);
      expect(result.lists.length, 2);
      expect(result.lists[0].entries.single.address,
          _FakeEmbedded.addrForByte(3));
      expect(result.lists[1].entries.single.address,
          _FakeEmbedded.addrForByte(3));
    });

    test('missing members and unreadable maps are counted, never fatal',
        () async {
      final fake = await _FakeEmbedded.start();
      addTearDown(() => fake.server.close(force: true));
      final bundle = _bundle(
        listText: 'ListName="Movies"\nMovie.mkv.datamap\n'
            'Gone.mkv.datamap\n',
        datamapMembers: {
          'Movie.mkv.datamap': Uint8List.fromList([4]),
          'Bad.mkv.datamap': Uint8List.fromList([0xBA, 0xD1]), // 400
        },
      );
      final result = await importBundleEntries(bundle, base: fake.base);
      expect(result.refsMissing, 1); // Gone.mkv.datamap
      expect(result.datamapsInvalid, 1); // Bad.mkv.datamap
      expect(result.entryCount, 1);
    });

    test('no list.txt: every member lands in the default list', () async {
      final fake = await _FakeEmbedded.start();
      addTearDown(() => fake.server.close(force: true));
      final bundle = _bundle(datamapMembers: {
        'A.mkv.datamap': Uint8List.fromList([5]),
        'B.mkv.datamap': Uint8List.fromList([6]),
      });
      final result = await importBundleEntries(bundle,
          base: fake.base, defaultListTitle: 'Imported');
      expect(result.lists.single.title, 'Imported');
      expect(result.lists.single.entries.length, 2);
    });

    test(
        'v1 conversion: rootmaps/ member seeds offline, else network '
        'resolve, else the entry is dropped', () async {
      final fake = await _FakeEmbedded.start();
      addTearDown(() => fake.server.close(force: true));
      const addrC =
          'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
      fake.resolvable.add(_addrB);
      final bundle = _bundle(
        listText: 'ListName="Legacy"\n'
            '$_addrA Offline (1968).mp4\n'
            '$_addrB Network (2024).mkv\n'
            '$addrC Doomed (1999).mkv\n',
        rootMaps: {
          _addrA: Uint8List.fromList([7, 7]),
        },
      );
      final progress = <(int, int)>[];
      final result = await importBundleEntries(bundle,
          base: fake.base,
          onConvertProgress: (c, n, _) => progress.add((c, n)));
      expect(result.convertedOffline, 1);
      expect(result.convertedNetwork, 1);
      expect(result.convertFailed, 1);
      expect(fake.rootmapPuts[_addrA], [7, 7]);
      expect(fake.resolves, containsAll([_addrB, addrC]));
      expect(result.lists.single.entries.map((e) => e.address),
          [_addrA, _addrB]); // doomed entry dropped, never map-less
      expect(progress, [(1, 3), (2, 3), (3, 3)]);
    });

    test('rejected rootmaps/ member falls back to the network', () async {
      final fake = await _FakeEmbedded.start();
      addTearDown(() => fake.server.close(force: true));
      fake.resolvable.add(_addrA);
      final bundle = _bundle(
        listText: 'ListName="Legacy"\n$_addrA Tampered (1968).mp4\n',
        rootMaps: {
          _addrA: Uint8List.fromList([6, 6, 6]), // fake server: 422
        },
      );
      final result = await importBundleEntries(bundle, base: fake.base);
      expect(result.convertedOffline, 0);
      expect(result.convertedNetwork, 1);
      expect(result.lists.single.entries.single.address, _addrA);
    });

    test('malformed list.txt degrades to member-only import', () async {
      final fake = await _FakeEmbedded.start();
      addTearDown(() => fake.server.close(force: true));
      final bundle = _bundle(
        listText: 'just some prose\nwith no entries at all\n',
        datamapMembers: {
          'A.mkv.datamap': Uint8List.fromList([8]),
        },
      );
      final result = await importBundleEntries(bundle,
          base: fake.base, defaultListTitle: 'Fallback');
      expect(result.lists.single.title, 'Fallback');
      expect(result.lists.single.entries.length, 1);
    });

    test('nothing importable throws', () async {
      final fake = await _FakeEmbedded.start();
      addTearDown(() => fake.server.close(force: true));
      final bundle = _bundle(
        listText: 'ListName="Empty"\nGone.mkv.datamap\n',
      );
      expect(
        () => importBundleEntries(bundle, base: fake.base),
        throwsA(isA<ListImportException>()),
      );
    });
  });

  group('seedBundle', () {
    test('fills gaps only; existing metadata and posters win', () async {
      // Local state: a row for NOTLD and a poster file with known bytes.
      await _seedMetadataRow('Night of the Living Dead (1968).mp4');
      File('${postersDir.path}/existing.jpg').writeAsBytesSync([7, 7]);

      final bundle = _bundle(
        listText: '',
        metadataRows: {
          _lookupKey('Night of the Living Dead (1968).mp4'): {
            'lookupKey': _lookupKey('Night of the Living Dead (1968).mp4'),
            'title': 'SHOULD NOT WIN',
          },
          _lookupKey('The Movie (2024).mkv'): {
            'lookupKey': _lookupKey('The Movie (2024).mkv'),
            'title': 'The Movie',
            'year': 2024,
            'mediaType': 'movie',
            'tmdbId': 42,
            'rating': 6.1,
          },
        },
        posters: {
          'existing.jpg': Uint8List.fromList([9, 9, 9]),
          'fresh.jpg': Uint8List.fromList([1, 2]),
        },
      );
      final summary = await seedBundle(bundle,
          postersDirProvider: postersDirProvider);
      expect(summary.metadataSeeded, 1);
      expect(summary.postersSeeded, 1);

      final db = await LibraryStore.database();
      final rows = await db.select(db.metadataCache).get();
      final notld = rows.firstWhere((r) =>
          r.lookupKey == _lookupKey('Night of the Living Dead (1968).mp4'));
      expect(notld.title, 'Night of the Living Dead'); // local row kept
      final fresh = rows.firstWhere(
          (r) => r.lookupKey == _lookupKey('The Movie (2024).mkv'));
      expect(fresh.title, 'The Movie');
      expect(fresh.rating, 6.1);

      expect(File('${postersDir.path}/existing.jpg').readAsBytesSync(),
          [7, 7]); // local file kept
      expect(File('${postersDir.path}/fresh.jpg').readAsBytesSync(),
          [1, 2]);
    });

    test('history merges newer-updatedAt-wins', () async {
      await WatchStateStore.instance.mergeAll([
        const WatchState(
          address: _addrA,
          positionMs: 90000,
          durationMs: 120000,
          completed: false,
          updatedAt: 9000, // newer than the bundle's
        ),
      ]);
      final bundle = _bundle(
        listText: '',
        history: {
          _addrA: const WatchState(
            address: _addrA,
            positionMs: 30000,
            durationMs: 120000,
            completed: false,
            updatedAt: 100, // older: must not regress local progress
          ),
          _addrB: const WatchState(
            address: _addrB,
            positionMs: 110000,
            durationMs: 120000,
            completed: true,
            updatedAt: 8000, // new address: imported
          ),
        },
      );
      final summary = await seedBundle(bundle,
          postersDirProvider: postersDirProvider);
      expect(summary.historyMerged, 1);
      final a = await WatchStateStore.instance
          .stateFor(const MediaEntry(name: 'a', address: _addrA));
      expect(a!.positionMs, 90000);
      final b = await WatchStateStore.instance
          .stateFor(const MediaEntry(name: 'b', address: _addrB));
      expect(b!.completed, isTrue);
    });

    test('importHistory: false skips the merge entirely', () async {
      final bundle = _bundle(
        listText: '',
        metadataRows: {
          _lookupKey('The Movie (2024).mkv'): {
            'lookupKey': _lookupKey('The Movie (2024).mkv'),
            'title': 'The Movie',
          },
        },
        history: {
          _addrA: const WatchState(
            address: _addrA,
            positionMs: 30000,
            durationMs: 120000,
            completed: false,
            updatedAt: 100,
          ),
        },
      );
      final summary = await seedBundle(bundle,
          importHistory: false, postersDirProvider: postersDirProvider);
      expect(summary.historyMerged, 0);
      final a = await WatchStateStore.instance
          .stateFor(const MediaEntry(name: 'a', address: _addrA));
      expect(a, isNull);
      expect(summary.metadataSeeded, 1); // other members still seed
    });
  });

  group('applyLibraryPrefs', () {
    final existing = MediaList(
        id: 'old', title: 'Old List', enabled: true, entries: const []);

    test('orders and toggles only the created lists', () {
      final lists = [
        existing,
        MediaList(id: 'n1', title: 'Beta', entries: const []),
        MediaList(id: 'n2', title: 'Alpha', entries: const []),
      ];
      final out = applyLibraryPrefs(lists, {'n1', 'n2'}, {
        'alpha': (enabled: false, position: 0),
        'beta': (enabled: true, position: 1),
        // A pref for an existing list must be ignored entirely.
        'old list': (enabled: false, position: 2),
      });
      expect(out.map((l) => l.id), ['old', 'n2', 'n1']);
      expect(out[0].enabled, isTrue); // existing list untouched
      expect(out[1].enabled, isFalse); // Alpha hidden per bundle
      expect(out[2].enabled, isTrue);
    });

    test('no prefs or no created lists is a no-op', () {
      final lists = [existing];
      expect(applyLibraryPrefs(lists, const {}, const {}), same(lists));
      expect(
          applyLibraryPrefs(
              lists, {'x'}, const {}),
          same(lists));
    });
  });
}
