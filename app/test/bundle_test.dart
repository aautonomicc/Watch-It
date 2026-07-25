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

  group('buildBundle', () {
    test('always carries a byte-identical list.txt', () async {
      final result = await buildBundle(
        [_list],
        const BundleExportOptions(
            includeHistory: false, includeRootMaps: false),
        postersDirProvider: postersDirProvider,
      );
      final archive = ZipDecoder().decodeBytes(result.bytes);
      final listTxt = archive.files.firstWhere((f) => f.name == 'list.txt');
      expect(utf8.decode(listTxt.readBytes()!),
          serializeMediaList(_list));
      // Nothing cached locally → no optional members.
      expect(archive.files.map((f) => f.name), ['list.txt']);
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
        const BundleExportOptions(
            includeHistory: true, includeRootMaps: false),
        postersDirProvider: postersDirProvider,
      );
      final archive = ZipDecoder().decodeBytes(result.bytes);
      final names = archive.files.map((f) => f.name).toSet();
      expect(
          names,
          containsAll(
              {'list.txt', 'metadata.json', 'posters/movie_10331.jpg', 'history.json'}));

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
          includeRootMaps: false,
          includeLibrary: true,
        ),
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

    test('root maps come from the embedded server, missing ones counted',
        () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) {
        if (req.uri.path == '/rootmap/$_addrA') {
          req.response.add([9, 9, 9]);
        } else {
          req.response.statusCode = 404;
        }
        req.response.close();
      });
      final result = await buildBundle(
        [_list],
        const BundleExportOptions(
            includeHistory: false, includeRootMaps: true),
        base: 'http://127.0.0.1:${server.port}',
        postersDirProvider: postersDirProvider,
      );
      expect(result.rootMapsIncluded, 1);
      expect(result.rootMapsMissing, 1);
      final archive = ZipDecoder().decodeBytes(result.bytes);
      final map = archive.files
          .firstWhere((f) => f.name == 'rootmaps/$_addrA.map');
      expect(map.readBytes(), [9, 9, 9]);
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
      await _seedMetadataRow('Night of the Living Dead (1968).mp4',
          posterFile: 'movie_10331.jpg');
      File('${postersDir.path}/movie_10331.jpg')
          .writeAsBytesSync([1, 2, 3, 4]);
      final built = await buildBundle(
        [_list],
        const BundleExportOptions(
            includeHistory: false, includeRootMaps: false),
        postersDirProvider: postersDirProvider,
      );
      final bundle = parseBundle(built.bytes);
      expect(bundle.listText, serializeMediaList(_list));
      expect(bundle.metadataRows.keys,
          [_lookupKey('Night of the Living Dead (1968).mp4')]);
      expect(bundle.posters['movie_10331.jpg'], [1, 2, 3, 4]);
      expect(bundle.rootMaps, isEmpty);
      expect(bundle.history, isEmpty);
    });

    test('requires list.txt', () {
      expect(
        () => parseBundle(zipOf({'metadata.json': utf8.encode('{}')})),
        throwsA(isA<ListImportException>()),
      );
    });

    test('rejects non-zip and unreadable input', () {
      expect(() => parseBundle(Uint8List.fromList([0x50, 0x4B, 1, 2, 3])),
          throwsA(isA<ListImportException>()));
    });

    test('drops hostile poster names and foreign root map names', () {
      final bytes = zipOf({
        'list.txt': utf8.encode('L\n$_addrA a.mp4\n'),
        'posters/../evil.jpg': [1],
        'posters/sub/dir.jpg': [2],
        'posters/ok.jpg': [3],
        'rootmaps/nothexnothexnothexnothexnothexnothexnothexnothexnothexnothexnoth.map':
            [4],
        'rootmaps/$_addrA.map': [5],
        'unknown/member.bin': [6],
      });
      final bundle = parseBundle(bytes);
      expect(bundle.posters.keys, ['ok.jpg']);
      expect(bundle.rootMaps.keys, [_addrA]);
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

  group('seedBundle', () {
    test('fills gaps only; existing metadata and posters win', () async {
      // Local state: a row for NOTLD and a poster file with known bytes.
      await _seedMetadataRow('Night of the Living Dead (1968).mp4');
      File('${postersDir.path}/existing.jpg').writeAsBytesSync([7, 7]);

      final bundle = ParsedBundle(
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
        rootMaps: const {},
        libraryPrefs: const {},
        history: const {},
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

    test('root maps go through PUT verify-then-store; rejects counted',
        () async {
      final putBodies = <String, List<int>>{};
      final server = await HttpServer.bind('127.0.0.1', 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        final body = await req
            .fold<BytesBuilder>(BytesBuilder(), (b, chunk) => b..add(chunk));
        if (req.method == 'PUT' &&
            req.uri.path == '/rootmap/$_addrA') {
          putBodies[_addrA] = body.takeBytes();
          req.response.statusCode = 204;
        } else {
          req.response.statusCode = 422;
        }
        await req.response.close();
      });
      final bundle = ParsedBundle(
        listText: '',
        metadataRows: const {},
        posters: const {},
        rootMaps: {
          _addrA: Uint8List.fromList([1, 2, 3]),
          _addrB: Uint8List.fromList([4, 5, 6]),
        },
        libraryPrefs: const {},
        history: const {},
      );
      final summary = await seedBundle(bundle,
          base: 'http://127.0.0.1:${server.port}',
          postersDirProvider: postersDirProvider);
      expect(summary.mapsStored, 1);
      expect(summary.mapsRejected, 1);
      expect(putBodies[_addrA], [1, 2, 3]);
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
      final bundle = ParsedBundle(
        listText: '',
        metadataRows: const {},
        posters: const {},
        rootMaps: const {},
        libraryPrefs: const {},
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
      final bundle = ParsedBundle(
        listText: '',
        metadataRows: {
          _lookupKey('The Movie (2024).mkv'): {
            'lookupKey': _lookupKey('The Movie (2024).mkv'),
            'title': 'The Movie',
          },
        },
        posters: const {},
        rootMaps: const {},
        libraryPrefs: const {},
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

    test('importRootMaps: false never touches the embedded client',
        () async {
      var requests = 0;
      final server = await HttpServer.bind('127.0.0.1', 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        requests++;
        req.response.statusCode = 204;
        await req.response.close();
      });
      final bundle = ParsedBundle(
        listText: '',
        metadataRows: const {},
        posters: const {},
        rootMaps: {
          _addrA: Uint8List.fromList([1, 2, 3]),
        },
        libraryPrefs: const {},
        history: const {},
      );
      final summary = await seedBundle(bundle,
          base: 'http://127.0.0.1:${server.port}',
          importRootMaps: false,
          postersDirProvider: postersDirProvider);
      expect(summary.mapsStored, 0);
      expect(summary.mapsRejected, 0);
      expect(requests, 0);
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
