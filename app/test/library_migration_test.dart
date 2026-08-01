import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/services/library_migration.dart';
import 'package:watchit/services/library_store.dart';

import 'fake_embedded_http.dart';

const _addrStored =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _addrResolvable =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _addrDoomed =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late FakeEmbeddedHttp fake;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    fake = FakeEmbeddedHttp();
    HttpOverrides.global = fake;
  });

  tearDown(() {
    HttpOverrides.global = null;
  });

  Future<void> seedLibrary(List<String> addresses) async {
    await LibraryStore.save([
      MediaList(id: 'l1', title: 'Movies', entries: [
        for (final (i, addr) in addresses.indexed)
          MediaEntry(name: 'Movie $i.mkv', address: addr),
      ]),
    ]);
  }

  test('an empty library marks the migration done without a client',
      () async {
    expect(await LibraryMigrator.pending(), isTrue);
    final unresolved = await LibraryMigrator(base: null).run();
    expect(unresolved, isNull);
    expect(await LibraryMigrator.pending(), isFalse);
  });

  test('covered entries stay local; missing ones resolve; pass completes',
      () async {
    await seedLibrary([_addrStored, _addrResolvable]);
    fake.storedRootmaps.add(_addrStored);
    fake.resolvable.add(_addrResolvable);
    final migrator = LibraryMigrator(base: FakeEmbeddedHttp.base);
    final unresolved = await migrator.run();
    expect(unresolved, 0);
    expect(migrator.total, 2);
    // The already-stored entry must not burn a network resolve.
    expect(fake.requests, isNot(contains('GET /resolve/$_addrStored')));
    expect(fake.requests, contains('GET /resolve/$_addrResolvable'));
    expect(await LibraryMigrator.pending(), isFalse);
  });

  test('unresolved entries keep the pass pending for the next launch',
      () async {
    await seedLibrary([_addrResolvable, _addrDoomed]);
    fake.resolvable.add(_addrResolvable);
    final unresolved =
        await LibraryMigrator(base: FakeEmbeddedHttp.base).run();
    expect(unresolved, 1);
    expect(await LibraryMigrator.pending(), isTrue);

    // Next launch: the missing map has appeared (played, re-imported,
    // or the network recovered) — the retry completes the migration.
    fake.resolvable.add(_addrDoomed);
    final retry = await LibraryMigrator(base: FakeEmbeddedHttp.base).run();
    expect(retry, 0);
    expect(await LibraryMigrator.pending(), isFalse);
  });

  test('a completed migration never runs again', () async {
    SharedPreferences.setMockInitialValues(
        {LibraryMigrator.prefsKey: true});
    await seedLibrary([_addrDoomed]);
    final unresolved =
        await LibraryMigrator(base: FakeEmbeddedHttp.base).run();
    expect(unresolved, isNull);
    expect(fake.requests, isEmpty);
  });

  test('cancel stops mid-pass and leaves it pending', () async {
    await seedLibrary([_addrResolvable, _addrDoomed]);
    fake.resolvable.addAll([_addrResolvable, _addrDoomed]);
    final migrator = LibraryMigrator(base: FakeEmbeddedHttp.base);
    migrator.addListener(() {
      if (migrator.current == 1) migrator.cancel();
    });
    await migrator.run();
    expect(await LibraryMigrator.pending(), isTrue);
  });
}
