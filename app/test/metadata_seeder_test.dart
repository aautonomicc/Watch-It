import 'dart:io';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata.dart';
import 'package:watchit/services/metadata_seeder.dart';
import 'package:watchit/services/seed_catalog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory postersDir;

  Future<Directory> postersDirProvider() async => postersDir;

  Future<void> seed() =>
      seedBundledMetadata(postersDirProvider: postersDirProvider);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    postersDir = await Directory.systemTemp.createTemp('wi-seed-posters');
  });

  tearDown(() async {
    if (postersDir.existsSync()) postersDir.deleteSync(recursive: true);
  });

  test('bundled metadata + artwork cover every seed-catalog entry',
      () async {
    final rows = parseSeedMetadataRows(
        await rootBundle.loadString(kSeedMetadataAsset));
    for (final list in kSeedLists) {
      for (final entry in list.entries) {
        final key = parseMediaName(entry.name).lookupKey;
        final row = rows[key];
        expect(row, isNotNull,
            reason: 'no bundled metadata row for "${entry.name}" — a '
                'seed-catalog change must re-run '
                'tool/harvest_seed_metadata.dart');
        expect(row!['title'], isNotEmpty);
        expect(row['overview'], isNotNull);
        expect(row['posterFile'], isNotNull);
        for (final field in ['posterFile', 'stillFile', 'showPosterFile']) {
          final name = row[field];
          if (name is! String) continue;
          final data = await rootBundle.load(seedPosterAsset(name));
          expect(data.lengthInBytes, greaterThan(0),
              reason: 'image asset missing/empty for $name ($key)');
        }
      }
    }
  });

  test('seeds cache rows and poster files for the whole catalog once',
      () async {
    await seed();

    final db = await LibraryStore.database();
    final cached = await db.select(db.metadataCache).get();
    final keys = {
      for (final list in kSeedLists)
        for (final entry in list.entries)
          parseMediaName(entry.name).lookupKey,
    };
    expect({for (final r in cached) r.lookupKey}, keys);
    expect(cached.every((r) => r.found), isTrue);
    final notld = cached.singleWhere(
        (r) => r.lookupKey == parseMediaName(kDefaultMovieName).lookupKey);
    expect(notld.title, 'Night of the Living Dead');
    expect(notld.posterFile, isNotNull);
    expect(File('${postersDir.path}/${notld.posterFile}').existsSync(),
        isTrue);
    // Every seeded artwork reference resolves to a written file.
    for (final r in cached) {
      for (final name in [r.posterFile, r.stillFile, r.showPosterFile]) {
        if (name == null) continue;
        expect(File('${postersDir.path}/$name').existsSync(), isTrue,
            reason: 'missing poster file $name for ${r.lookupKey}');
      }
    }

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kSeedMetadataFlag), isTrue);

    // Second launch: the flag short-circuits — a row deleted by the user
    // (factory reset aside) is not re-seeded.
    await (db.delete(db.metadataCache)
          ..where((t) => t.lookupKey.equals(notld.lookupKey)))
        .go();
    await seed();
    expect(
        await (db.select(db.metadataCache)
              ..where((t) => t.lookupKey.equals(notld.lookupKey)))
            .getSingleOrNull(),
        isNull);
  });

  test('existing cache rows and poster files always win', () async {
    final db = await LibraryStore.database();
    final key = parseMediaName(kDefaultMovieName).lookupKey;
    await db.into(db.metadataCache).insert(MetadataCacheCompanion.insert(
          lookupKey: key,
          found: true,
          title: const Value('User Title'),
          posterFile: const Value('movie_10331.jpg'),
          fetchedAt: 1,
        ));
    final posterFile = File('${postersDir.path}/movie_10331.jpg');
    await posterFile.writeAsBytes([1, 2, 3]);

    await seed();

    final row = await (db.select(db.metadataCache)
          ..where((t) => t.lookupKey.equals(key)))
        .getSingle();
    expect(row.title, 'User Title');
    expect(posterFile.readAsBytesSync(), [1, 2, 3]);
    // Other entries still seeded around the existing one.
    expect((await db.select(db.metadataCache).get()).length,
        greaterThan(1));
  });

  test('a failed asset load is swallowed and retried next launch',
      () async {
    await seedBundledMetadata(
        postersDirProvider: postersDirProvider,
        loadString: (_) async => throw Exception('no asset'));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kSeedMetadataFlag), isNull);
    final db = await LibraryStore.database();
    expect(await db.select(db.metadataCache).get(), isEmpty);
  });
}
