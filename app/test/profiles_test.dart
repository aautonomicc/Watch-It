import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart' hide Row;

import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/services/favourites.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/profiles.dart';
import 'package:watchit/services/watch_state.dart';

String _addr(int i) => i.toRadixString(16).padLeft(64, '0');

MediaEntry _e(String name, int i) => MediaEntry(name: name, address: _addr(i));

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'defaults_seeded_v4': true});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    ProfileStore.onSwitch = null;
    ProfileStore.instance = ProfileStore();
    WatchStateStore.instance = WatchStateStore();
    FavouritesStore.instance = FavouritesStore();
  });

  group('ProfileStore basics', () {
    test('a pre-profile install silently becomes the lone Admin profile',
        () async {
      final store = ProfileStore.instance;
      await store.ensureLoaded();
      expect(store.profiles, hasLength(1));
      expect(store.profiles.single.id, kAdminProfileId);
      expect(store.profiles.single.kind, ProfileKind.admin);
      // Single profile → signed straight in, feature invisible.
      expect(store.activeId, kAdminProfileId);
      expect(store.multiProfile, isFalse);
      expect(store.isAdmin, isTrue);
      expect(store.isKid, isFalse);
    });

    test('create / update / delete profiles', () async {
      final store = ProfileStore.instance;
      await store.ensureLoaded();
      final kid = await store.create(
          name: 'Ellie', kind: ProfileKind.kid, avatar: 'preset:2');
      expect(store.multiProfile, isTrue);
      expect(kid.isKid, isTrue);
      expect(kid.avatar, 'preset:2');

      await store.updateProfile(kid.copyWith(name: 'Ellie B'));
      expect(store.profiles.firstWhere((p) => p.id == kid.id).name,
          'Ellie B');

      await store.deleteProfile(kid.id);
      expect(store.profiles, hasLength(1));
      // The admin can never be deleted.
      await store.deleteProfile(kAdminProfileId);
      expect(store.profiles, hasLength(1));
    });

    test('auto-login profile signs in at launch; else the picker asks',
        () async {
      final store = ProfileStore.instance;
      await store.ensureLoaded();
      final kid = await store.create(name: 'Kid', kind: ProfileKind.kid);

      // Two profiles, no auto-login: a fresh launch has nobody active.
      var fresh = ProfileStore();
      await fresh.ensureLoaded();
      expect(fresh.hasActive, isFalse);
      expect(fresh.active, isNull);

      await store.setAutoLogin(kid.id);
      fresh = ProfileStore();
      await fresh.ensureLoaded();
      expect(fresh.active?.id, kid.id);

      // Clearing it goes back to asking.
      await store.setAutoLogin(null);
      fresh = ProfileStore();
      await fresh.ensureLoaded();
      expect(fresh.hasActive, isFalse);
    });

    test('kid list access filters visibleLists; adults see everything',
        () async {
      final store = ProfileStore.instance;
      await store.ensureLoaded();
      final lists = [
        MediaList(id: 'movies', title: 'Movies', entries: [_e('A.mkv', 1)]),
        MediaList(id: 'kids', title: 'Kids', entries: [_e('B.mkv', 2)]),
      ];
      final kid = await store.create(
          name: 'Kid', kind: ProfileKind.kid, allowedLists: {'kids'});
      final adult =
          await store.create(name: 'Grown-up', kind: ProfileKind.adult);

      await store.selectProfile(kid.id);
      expect(store.visibleLists(lists).map((l) => l.id), ['kids']);

      await store.selectProfile(adult.id);
      expect(store.visibleLists(lists), hasLength(2));

      // Ticking another list widens the kid's view on next select.
      await store.setAllowedListIds(kid.id, {'kids', 'movies'});
      await store.selectProfile(kid.id);
      expect(store.visibleLists(lists), hasLength(2));
    });
  });

  group('Per-profile scoping', () {
    test('watch states are isolated per profile; admin rows survive',
        () async {
      final store = ProfileStore.instance;
      await store.ensureLoaded();
      final entry = _e('Movie.2020.mkv', 1);
      await WatchStateStore.instance.record(entry,
          position: const Duration(minutes: 10),
          duration: const Duration(minutes: 100));
      expect(await WatchStateStore.instance.stateFor(entry), isNotNull);

      final kid = await store.create(name: 'Kid', kind: ProfileKind.kid);
      await store.selectProfile(kid.id);
      WatchStateStore.instance.onProfileSwitched();
      expect(await WatchStateStore.instance.stateFor(entry), isNull);

      await WatchStateStore.instance.record(entry,
          position: const Duration(minutes: 3),
          duration: const Duration(minutes: 100));
      final kidState = await WatchStateStore.instance.stateFor(entry);
      expect(kidState!.positionMs, const Duration(minutes: 3).inMilliseconds);

      await store.selectProfile(kAdminProfileId);
      WatchStateStore.instance.onProfileSwitched();
      final adminState = await WatchStateStore.instance.stateFor(entry);
      expect(
          adminState!.positionMs, const Duration(minutes: 10).inMilliseconds);

      // mergeAll (bundle import / My W@tch sync) always lands on Admin.
      await store.selectProfile(kid.id);
      WatchStateStore.instance.onProfileSwitched();
      await WatchStateStore.instance.mergeAll([
        WatchState(
            address: _addr(2),
            positionMs: 5000,
            durationMs: 60000,
            completed: false,
            updatedAt: 99),
      ]);
      expect(await WatchStateStore.instance.stateFor(_e('X.mkv', 2)), isNull);
      expect(
          (await WatchStateStore.instance.all(profileId: kAdminProfileId))
              .map((s) => s.address),
          contains(_addr(2)));
    });

    test('deleting a profile drops its watch states', () async {
      final store = ProfileStore.instance;
      await store.ensureLoaded();
      final kid = await store.create(name: 'Kid', kind: ProfileKind.kid);
      await store.selectProfile(kid.id);
      WatchStateStore.instance.onProfileSwitched();
      await WatchStateStore.instance.record(_e('A.mkv', 1),
          position: const Duration(minutes: 5),
          duration: const Duration(minutes: 50));
      expect(await WatchStateStore.instance.all(profileId: kid.id),
          hasLength(1));
      await store.deleteProfile(kid.id);
      expect(await WatchStateStore.instance.all(profileId: kid.id), isEmpty);
    });

    test('favourites live in per-profile slots (admin keeps the old key)',
        () async {
      final store = ProfileStore.instance;
      await store.ensureLoaded();
      await FavouritesStore.instance.ensureLoaded();
      await FavouritesStore.instance.toggle(_addr(1));
      expect(FavouritesStore.instance.isFavourite(_addr(1)), isTrue);

      final kid = await store.create(name: 'Kid', kind: ProfileKind.kid);
      await store.selectProfile(kid.id);
      await FavouritesStore.instance.onProfileSwitched();
      expect(FavouritesStore.instance.isFavourite(_addr(1)), isFalse);
      await FavouritesStore.instance.toggle(_addr(2));

      await store.selectProfile(kAdminProfileId);
      await FavouritesStore.instance.onProfileSwitched();
      expect(FavouritesStore.instance.isFavourite(_addr(1)), isTrue);
      expect(FavouritesStore.instance.isFavourite(_addr(2)), isFalse);

      final prefs = await SharedPreferences.getInstance();
      // Admin kept the historic key; the kid got a suffixed slot.
      expect(prefs.getStringList('favourites_v1'), [_addr(1)]);
      expect(prefs.getStringList('favourites_v1_p_${kid.id}'), [_addr(2)]);
    });
  });

  group('PINs and recovery', () {
    test('set / verify / wrong; lockout after too many tries', () async {
      final store = ProfileStore.instance;
      await store.ensureLoaded();
      final kid = await store.create(name: 'Kid', kind: ProfileKind.kid);
      await store.setPin(kid.id, '1234');
      expect(store.profiles.firstWhere((p) => p.id == kid.id).hasPin, isTrue);

      expect(await store.verifyPin(kid.id, '1234'), PinVerify.ok);
      expect(await store.verifyPin(kid.id, '9999'), PinVerify.wrong);
      // 4 more wrong tries (5 total) lock it…
      for (var i = 0; i < 3; i++) {
        expect(await store.verifyPin(kid.id, '0000'), PinVerify.wrong);
      }
      expect(await store.verifyPin(kid.id, '0000'), PinVerify.locked);
      // …even for the RIGHT pin while locked.
      expect(await store.verifyPin(kid.id, '1234'), PinVerify.locked);

      await store.clearPin(kid.id);
      expect(
          store.profiles.firstWhere((p) => p.id == kid.id).hasPin, isFalse);
      expect(await store.verifyPin(kid.id, 'anything'), PinVerify.ok);
    });

    test('pin hashes are salted — same pin, different stored values', () {
      final a = ProfileStore.encodePin('1234');
      final b = ProfileStore.encodePin('1234');
      expect(a, isNot(b));
      expect(a, contains(':'));
    });

    test('admin recovery code removes the PIN once, then stops working',
        () async {
      final store = ProfileStore.instance;
      await store.ensureLoaded();
      final code = await store.setAdminPin('4321');
      expect(code, matches(RegExp(r'^[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}$')));
      expect(store.adminHasPin, isTrue);

      expect(await store.recoverAdminPin('WRONG-CODE-HERE'), isFalse);
      expect(store.adminHasPin, isTrue);

      // Case/dash-insensitive on entry.
      expect(
          await store.recoverAdminPin(
              code.toLowerCase().replaceAll('-', '')),
          isTrue);
      expect(store.adminHasPin, isFalse);
      // One-time: the code is gone with the PIN.
      expect(await store.recoverAdminPin(code), isFalse);
    });

    test('changing the admin PIN mints a fresh code and voids the old one',
        () async {
      final store = ProfileStore.instance;
      await store.ensureLoaded();
      final first = await store.setAdminPin('1111');
      final second = await store.setAdminPin('2222');
      expect(first, isNot(second));
      expect(await store.recoverAdminPin(first), isFalse);
      expect(await store.recoverAdminPin(second), isTrue);
    });
  });

  group('Schema migration v13', () {
    test('v12 watch states become the Admin profile\'s on upgrade',
        () async {
      final dir = await Directory.systemTemp.createTemp('watchit-migration');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/watchit.sqlite');

      // Hand-build the alpha.79–92 (schema v12) watch_states shape.
      final raw = sqlite3.open(file.path);
      raw.execute('''
        CREATE TABLE watch_states (
          address TEXT NOT NULL,
          position_ms INTEGER NOT NULL,
          duration_ms INTEGER NOT NULL,
          completed INTEGER NOT NULL DEFAULT 0,
          updated_at INTEGER NOT NULL,
          PRIMARY KEY (address));
        INSERT INTO watch_states VALUES ('${_addr(1)}', 60000, 600000, 0, 5);
        PRAGMA user_version = 12;
      ''');
      raw.close();

      await LibraryStore.useForTesting(
          AppDatabase.forTesting(NativeDatabase(file)));
      ProfileStore.instance = ProfileStore();
      await ProfileStore.instance.ensureLoaded();
      WatchStateStore.instance = WatchStateStore();

      // The pre-profile row now belongs to the migrated Admin profile.
      final states =
          await WatchStateStore.instance.all(profileId: kAdminProfileId);
      expect(states.single.address, _addr(1));
      expect(states.single.positionMs, 60000);

      // And the profile tables exist and hold the lone Admin.
      expect(ProfileStore.instance.profiles.single.id, kAdminProfileId);
    });
  });
}
