import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_credits.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/screens/media_credits_screen.dart';
import 'package:watchit/services/bundle.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/media_credits_store.dart';
import 'package:watchit/services/profiles.dart';

final _a = 'a' * 64, _b = 'b' * 64, _missing = 'c' * 64;
const _credit = MediaCredits(
  title: 'PLUR rehearsal — TEST',
  creator: 'Test ensemble / Ābele',
  sourceUrl: 'https://example.org/performance',
  licenseName: 'Licence supplied by creator',
  licenseUrl: 'https://example.org/terms',
  attribution: 'Synthetic fixture. No real performer or rights claim.',
  changes: 'Latvian captions added — draft',
);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory temp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temp = Directory.systemTemp.createTempSync('watch-credits-');
    await LibraryStore.useForTesting(
      AppDatabase.forTesting(NativeDatabase.memory()),
    );
    ProfileStore.instance = ProfileStore();
  });
  tearDown(() {
    temp.deleteSync(recursive: true);
  });

  test('typed credits preserve Unicode; unknown licence stays blank', () {
    expect(MediaCredits.fromJson(_credit.toJson()).toJson(), _credit.toJson());
    final blank = MediaCredits.fromJson({
      'creator': '  Ābele  ',
      'verified': true,
    });
    expect(blank.creator, 'Ābele');
    expect(blank.licenseName, isEmpty);
    expect(blank.toJson(), isNot(contains('verified')));
  });

  test('non-web links, credentials, oversized and non-text fields fail', () {
    for (final url in [
      'javascript:alert(1)',
      'file:///tmp/foo',
      'https://user:password@example.org/video',
      'https://example.org/a b',
    ]) {
      expect(
        () => MediaCredits.fromJson({'sourceUrl': url}),
        throwsFormatException,
      );
    }
    expect(() => MediaCredits.fromJson({'creator': 42}), throwsFormatException);
    expect(
      () => MediaCredits.fromJson({'title': 'x' * 513}),
      throwsFormatException,
    );
    expect(
      () => MediaCredits.fromJson({'attribution': 'bad\u0000value'}),
      throwsFormatException,
    );
  });

  test('file identity prevents same-name recordings sharing credits', () async {
    await MediaCreditsStore.save('0x${_a.toUpperCase()}', _credit);
    await MediaCreditsStore.save(
      _b,
      const MediaCredits(creator: 'Second ensemble'),
    );
    expect((await MediaCreditsStore.read(_a))!.creator, _credit.creator);
    expect((await MediaCreditsStore.read(_b))!.creator, 'Second ensemble');
  });

  test(
    'import keeps a local correction and a deliberately cleared record',
    () async {
      await MediaCreditsStore.save(
        _a,
        const MediaCredits(creator: 'My correction'),
      );
      await MediaCreditsStore.seed(_a, _credit);
      expect((await MediaCreditsStore.read(_a))!.creator, 'My correction');
      await MediaCreditsStore.save(_a, const MediaCredits());
      await MediaCreditsStore.seed(_a, _credit);
      expect((await MediaCreditsStore.read(_a))!.isEmpty, isTrue);
    },
  );

  test('credits survive closing and reopening the database', () async {
    final file = File('${temp.path}/credits.sqlite');
    await LibraryStore.useForTesting(
      AppDatabase.forTesting(NativeDatabase(file)),
    );
    await MediaCreditsStore.save(_a, _credit);
    await LibraryMigrationRoundTrip.closeAndReopen(file);
    expect((await MediaCreditsStore.read(_a))!.toJson(), _credit.toJson());
  });

  test(
    'version 13 migration adds credits without altering existing tables',
    () async {
      final file = File('${temp.path}/old.sqlite');
      final old = sql.sqlite3.open(file.path);
      old.execute('CREATE TABLE preserved (value TEXT)');
      old.execute("INSERT INTO preserved VALUES ('keep me')");
      old.execute('PRAGMA user_version = 13');
      old.close();
      await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase(file)),
      );
      await MediaCreditsStore.save(_a, _credit);
      final db = await LibraryStore.database();
      expect(
        (await db.customSelect('SELECT value FROM preserved').getSingle())
            .read<String>('value'),
        'keep me',
      );
      expect((await MediaCreditsStore.read(_a))!.creator, _credit.creator);
    },
  );

  test(
    'bundle round trip includes only exported maps and no private extras',
    () async {
      await MediaCreditsStore.save(_a, _credit);
      await MediaCreditsStore.save(
        _b,
        const MediaCredits(creator: 'Unrelated private file'),
      );
      await MediaCreditsStore.save(
        _missing,
        const MediaCredits(creator: 'Missing map'),
      );
      final previousHttp = HttpOverrides.current;
      HttpOverrides.global =
          null; // This test exercises a real loopback map server.
      addTearDown(() {
        HttpOverrides.global = previousHttp;
      });
      final server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((request) async {
        if (request.uri.path == '/datamap/$_a') {
          request.response.add([0xaa]);
        } else {
          request.response.statusCode = 404;
        }
        await request.response.close();
      });
      try {
        final built = await buildBundle(
          [
            MediaList(
              id: 'l',
              title: 'Festival',
              entries: [
                MediaEntry(name: 'Same title.mp4', address: _a),
                MediaEntry(name: 'No map.mp4', address: _missing),
              ],
            ),
          ],
          const BundleExportOptions(includeHistory: false),
          base: 'http://127.0.0.1:${server.port}',
          postersDirProvider: () async => temp,
        );
        final parsed = parseBundle(built.bytes);
        expect(parsed.creditsByMember.length, 1);
        final member = parsed.creditsByMember.keys.single;
        expect(parsed.datamapMembers, contains(member));
        expect(parsed.creditsByMember[member]!.toJson(), _credit.toJson());
        final archive = ZipDecoder().decodeBytes(built.bytes);
        expect(archive.findFile('history.json'), isNull);
        final text = utf8.decode(
          archive.findFile('credits.json')!.readBytes()!,
        );
        expect(text, isNot(contains(_b)));
        expect(text, isNot(contains('Unrelated private file')));
        expect(text, isNot(contains('Missing map')));
        await LibraryStore.useForTesting(
          AppDatabase.forTesting(NativeDatabase.memory()),
        );
        await seedBundle(
          parsed,
          addressByMember: {member: _a},
          postersDirProvider: () async => temp,
        );
        expect((await MediaCreditsStore.read(_a))!.toJson(), _credit.toJson());
      } finally {
        await server.close(force: true);
      }
    },
  );

  test('malformed credits do not discard valid neighbouring rows', () {
    final archive = Archive()
      ..addFile(ArchiveFile.bytes('datamaps/ok.mp4.datamap', [1]))
      ..addFile(
        ArchiveFile.string(
          'credits.json',
          jsonEncode({
            'version': 1,
            'entries': [
              {'member': 'bad.mp4.datamap', 'creator': 7},
              {'member': '../escape.datamap', ..._credit.toJson()},
              {'member': 'ok.mp4.datamap', ..._credit.toJson()},
            ],
          }),
        ),
      );
    final parsed = parseBundle(
      Uint8List.fromList(ZipEncoder().encode(archive)),
    );
    expect(parsed.creditsByMember.keys, ['ok.mp4.datamap']);
  });

  test('unknown-version and oversized optional credits are ignored', () {
    for (final member in [
      BundleZipMember(
        name: 'credits.json',
        declaredSize: 100,
        read: () =>
            Uint8List.fromList(utf8.encode('{"version":99,"entries":[]}')),
      ),
      BundleZipMember(
        name: 'credits.json',
        declaredSize: kMaxCreditsJsonBytes + 1,
        read: () =>
            throw StateError('oversized member must not be decompressed'),
      ),
    ]) {
      final parsed = parseBundleMembers([
        BundleZipMember(
          name: 'list.txt',
          declaredSize: 8,
          read: () => Uint8List.fromList(utf8.encode('Festival')),
        ),
        member,
      ]);
      expect(parsed.creditsByMember, isEmpty);
    }
  });

  test('credits cannot seed a file whose datamap did not import', () async {
    final bundle = ParsedBundle(
      listText: null,
      datamapMembers: {},
      metadataRows: {},
      posters: {},
      libraryPrefs: {},
      creditsByMember: {'missing.datamap': _credit},
    );
    await seedBundle(bundle, postersDirProvider: () async => temp);
    expect(await MediaCreditsStore.read(_a), isNull);
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaCreditsScreen(
          entry: MediaEntry(name: 'Festival rehearsal.mp4', address: _a),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('kid profile can read attribution but cannot edit it', (
    tester,
  ) async {
    await MediaCreditsStore.save(_a, _credit);
    await ProfileStore.instance.ensureLoaded();
    final kid = await ProfileStore.instance.create(
      name: 'Kid',
      kind: ProfileKind.kid,
    );
    await ProfileStore.instance.selectProfile(kid.id);
    await pumpScreen(tester);
    expect(find.text(_credit.creator), findsOneWidget);
    expect(find.text('Edit credits'), findsNothing);
    expect(find.text('Add credits'), findsNothing);
  });

  testWidgets('editor saves credits and an unknown licence remains named', (
    tester,
  ) async {
    await pumpScreen(tester);
    await tester.tap(find.text('Add credits'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('credit-creator')),
      'Ābele ensemble',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save credits'));
    await tester.pumpAndSettle();
    expect(find.text('Ābele ensemble'), findsOneWidget);
    expect(find.text('Reuse licence not recorded.'), findsOneWidget);
    expect((await MediaCreditsStore.read(_a))!.creator, 'Ābele ensemble');
  });

  testWidgets('remote opens the focused add action; Cancel does not write', (
    tester,
  ) async {
    await pumpScreen(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('Edit credits'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('credit-title')),
      'Unsaved',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Credits & source'), findsOneWidget);
    expect(await MediaCreditsStore.read(_a), isNull);
  });
}

class LibraryMigrationRoundTrip {
  static Future<void> closeAndReopen(File file) async {
    await LibraryStore.useForTesting(
      AppDatabase.forTesting(NativeDatabase.memory()),
    );
    await LibraryStore.useForTesting(
      AppDatabase.forTesting(NativeDatabase(file)),
    );
  }
}
