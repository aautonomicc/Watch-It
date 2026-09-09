import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/profile_transfer.dart';
import 'package:watchit/services/profiles.dart';
import 'package:watchit/services/watch_state.dart';

String _addr(int i) => i.toRadixString(16).padLeft(2, '0') * 32;

Future<void> _seedState(String address, String profileId,
    {int positionMs = 60000, int updatedAt = 1000}) async {
  final db = await LibraryStore.database();
  await db.into(db.watchStates).insertOnConflictUpdate(
        WatchStatesCompanion.insert(
          address: address,
          profileId: Value(profileId),
          positionMs: positionMs,
          durationMs: 120000,
          updatedAt: updatedAt,
        ),
      );
}

Future<WatchState?> _stateOf(String address, String profileId) async {
  final db = await LibraryStore.database();
  final row = await (db.select(db.watchStates)
        ..where((t) =>
            t.address.equals(address) & t.profileId.equals(profileId)))
      .getSingleOrNull();
  return row == null
      ? null
      : WatchState(
          address: row.address,
          positionMs: row.positionMs,
          durationMs: row.durationMs,
          completed: row.completed,
          updatedAt: row.updatedAt,
        );
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory postersDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'defaults_seeded_v4': true});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    ProfileStore.onSwitch = null;
    ProfileStore.instance = ProfileStore();
    WatchStateStore.instance = WatchStateStore();
    postersDir = await Directory.systemTemp.createTemp('wi-ptransfer');
    ProfileStore.postersDirProvider = () async => postersDir;
  });

  tearDown(() {
    ProfileStore.postersDirProvider = null;
    if (postersDir.existsSync()) postersDir.deleteSync(recursive: true);
  });

  group('buildProfilesExport', () {
    test(
        'carries profiles, PINs, the admin recovery hash, kid list '
        'titles, per-profile member-keyed history and avatar bytes',
        () async {
      final store = ProfileStore.instance;
      await store.ensureLoaded();
      await store.setAdminPin('1234');
      await LibraryStore.save([
        MediaList(id: 'l1', title: 'Movies', entries: const [
          MediaEntry(name: 'A (2020).mp4', address: ''),
        ]),
      ]);
      final kid = await store.create(
          name: 'Ellie', kind: ProfileKind.kid, allowedLists: {'l1'});
      final avatarName = await ProfileStore.saveAvatarImage(
          kid.id, Uint8List.fromList([1, 2, 3]));
      await store.updateProfile(kid.copyWith(avatar: avatarName));
      await _seedState(_addr(1), kAdminProfileId, updatedAt: 111);
      await _seedState(_addr(1), kid.id, positionMs: 90000, updatedAt: 222);
      await _seedState(_addr(2), kid.id); // not exported — no member

      final export = await buildProfilesExport(
          memberByAddr: {_addr(1): 'A (2020).mp4.datamap'});
      final decoded = jsonDecode(export.json) as Map<String, dynamic>;
      expect(decoded['adminRecovery'], contains(':'));
      final profiles = (decoded['profiles'] as List)
          .cast<Map<String, dynamic>>();
      expect(profiles, hasLength(2));
      final admin = profiles.firstWhere((p) => p['kind'] == 'admin');
      expect(admin['pinHash'], contains(':'));
      expect((admin['history'] as List).single['updatedAt'], 111);
      final ellie = profiles.firstWhere((p) => p['name'] == 'Ellie');
      expect(ellie['kind'], 'kid');
      expect(ellie['allowedLists'], ['Movies']);
      expect(ellie['avatar'], avatarName);
      final row = (ellie['history'] as List).single;
      expect(row['member'], 'A (2020).mp4.datamap');
      expect(row['positionMs'], 90000);
      expect(export.avatarFiles[avatarName], [1, 2, 3]);
    });
  });

  group('parseProfilesJson', () {
    test('round-trips the export and drops junk hashes/rows', () {
      final parsed = parseProfilesJson(jsonEncode(<String, dynamic>{
        'version': 1,
        'profiles': [
          {
            'name': 'Neil',
            'kind': 'adult',
            'pinHash': 'salt:hash',
            'autoLogin': true,
            'history': [
              {'member': 'a.datamap', 'positionMs': 5, 'updatedAt': 9},
              {'positionMs': 5}, // memberless — dropped
            ],
          },
          {'name': '', 'kind': 'kid'}, // nameless — dropped
          {'name': 'Junk PIN', 'kind': 'weird', 'pinHash': 'nocolon'},
        ],
        'adminRecovery': 'not-a-hash',
      }))!;
      expect(parsed.profiles, hasLength(2));
      expect(parsed.adminRecovery, isNull);
      final neil = parsed.profiles.first;
      expect(neil.pinHash, 'salt:hash');
      expect(neil.autoLogin, isTrue);
      expect(neil.historyByMember.keys, ['a.datamap']);
      expect(parsed.profiles.last.pinHash, isNull);
      expect(parsed.profiles.last.kind, 'weird'); // imports as adult
    });

    test('no usable profile parses to null', () {
      expect(parseProfilesJson(jsonEncode({'profiles': []})), isNull);
      expect(parseProfilesJson(jsonEncode({'x': 1})), isNull);
    });
  });

  group('importProfilesData — collisions (device wins)', () {
    test(
        'name/kind/avatar kept, device PIN kept, backup PIN fills a '
        'gap, auto-login dropped when a device profile has it', () async {
      final store = ProfileStore.instance;
      await store.ensureLoaded();
      final neil = await store.create(
          name: 'Neil', kind: ProfileKind.adult, avatar: 'preset:1');
      await store.setPin(neil.id, '1111');
      final devicePin =
          store.profiles.firstWhere((p) => p.id == neil.id).pinHash;
      final pia = await store.create(name: 'Pia', kind: ProfileKind.adult);
      await store.setAutoLogin(neil.id);

      final summary = await importProfilesData(
        const ParsedProfiles(profiles: [
          // Different case, kid kind, own PIN + auto-login: all lose.
          BundleProfile(
              name: 'neil',
              kind: 'kid',
              avatar: 'preset:9',
              pinHash: 'backup:pin',
              autoLogin: true),
          // Fills the PIN gap on Pia.
          BundleProfile(name: 'Pia', kind: 'adult', pinHash: 'backup:pia'),
        ]),
        const {},
        addressByMember: const {},
        lists: const [],
      );
      expect(summary.merged, 2);
      expect(summary.added, 0);
      final after = store.profiles;
      final neilAfter = after.firstWhere((p) => p.id == neil.id);
      expect(neilAfter.name, 'Neil');
      expect(neilAfter.kind, ProfileKind.adult); // never Adult→Kid
      expect(neilAfter.avatar, 'preset:1');
      expect(neilAfter.pinHash, devicePin);
      expect(neilAfter.autoLogin, isTrue); // device designation kept
      final piaAfter = after.firstWhere((p) => p.id == pia.id);
      expect(piaAfter.pinHash, 'backup:pia');
      expect(piaAfter.autoLogin, isFalse); // dropped — Neil has it
    });

    test('backup avatar fills a gap; file avatars re-save locally',
        () async {
      final store = ProfileStore.instance;
      await store.ensureLoaded();
      final pia = await store.create(name: 'Pia', kind: ProfileKind.adult);
      await importProfilesData(
        const ParsedProfiles(profiles: [
          BundleProfile(
              name: 'Pia',
              kind: 'adult',
              avatar: 'profile_avatar_x_1.img'),
        ]),
        {
          'profile_avatar_x_1.img': Uint8List.fromList([7, 8]),
        },
        addressByMember: const {},
        lists: const [],
      );
      final avatar =
          store.profiles.firstWhere((p) => p.id == pia.id).avatar;
      expect(avatar, isNotNull);
      expect(avatar, startsWith('profile_avatar_${pia.id}_'));
      final file = await ProfileStore.avatarFile(avatar);
      expect(await file!.readAsBytes(), [7, 8]);
    });

    test('kid allowed lists are the union, resolved by title', () async {
      final store = ProfileStore.instance;
      await store.ensureLoaded();
      final lists = [
        MediaList(id: 'l1', title: 'Movies', entries: const []),
        MediaList(id: 'l2', title: 'Cartoons', entries: const []),
      ];
      await LibraryStore.save(lists);
      final kid = await store.create(
          name: 'Ellie', kind: ProfileKind.kid, allowedLists: {'l1'});
      await importProfilesData(
        const ParsedProfiles(profiles: [
          BundleProfile(
              name: 'ellie',
              kind: 'kid',
              allowedLists: ['Cartoons', 'No Such List']),
        ]),
        const {},
        addressByMember: const {},
        lists: lists,
      );
      expect(await store.allowedListIds(kid.id), {'l1', 'l2'});
    });

    test('per-profile history lands on the merged profile, newest wins',
        () async {
      final store = ProfileStore.instance;
      await store.ensureLoaded();
      final kid = await store.create(name: 'Ellie', kind: ProfileKind.kid);
      await _seedState(_addr(1), kid.id, positionMs: 10000, updatedAt: 900);
      await _seedState(_addr(2), kid.id, positionMs: 10000, updatedAt: 900);
      final summary = await importProfilesData(
        const ParsedProfiles(profiles: [
          BundleProfile(name: 'Ellie', kind: 'kid', historyByMember: {
            // Newer than the device row — wins.
            'a.datamap': (
              positionMs: 50000,
              durationMs: 120000,
              completed: false,
              updatedAt: 2000
            ),
            // Older — device row survives.
            'b.datamap': (
              positionMs: 99000,
              durationMs: 120000,
              completed: false,
              updatedAt: 100
            ),
            // No imported member — dropped.
            'gone.datamap': (
              positionMs: 1,
              durationMs: 2,
              completed: false,
              updatedAt: 3
            ),
          }),
        ]),
        const {},
        addressByMember: {'a.datamap': _addr(1), 'b.datamap': _addr(2)},
        lists: const [],
      );
      expect(summary.historyMerged, 1);
      expect((await _stateOf(_addr(1), kid.id))!.positionMs, 50000);
      expect((await _stateOf(_addr(2), kid.id))!.positionMs, 10000);
      // Nothing leaked onto the admin profile.
      expect(await _stateOf(_addr(1), kAdminProfileId), isNull);
    });
  });

  group('importProfilesData — admin PIN pair', () {
    test('adopted only when the device admin has no PIN AND the backup '
        'carries the recovery hash', () async {
      final store = ProfileStore.instance;
      await store.ensureLoaded();

      // No recovery hash → PIN not adopted.
      var summary = await importProfilesData(
        const ParsedProfiles(profiles: [
          BundleProfile(name: 'Admin', kind: 'admin', pinHash: 'b:pin'),
        ]),
        const {},
        addressByMember: const {},
        lists: const [],
      );
      expect(summary.adminPinAdopted, isFalse);
      expect(store.adminProfile!.pinHash, isNull);

      // With the pair → both adopted together.
      summary = await importProfilesData(
        const ParsedProfiles(
          profiles: [
            BundleProfile(name: 'Admin', kind: 'admin', pinHash: 'b:pin'),
          ],
          adminRecovery: 'b:recovery',
        ),
        const {},
        addressByMember: const {},
        lists: const [],
      );
      expect(summary.adminPinAdopted, isTrue);
      expect(store.adminProfile!.pinHash, 'b:pin');
      expect(await store.adminRecoveryHash(), 'b:recovery');
    });

    test('a device admin PIN always wins; the backup admin merges by '
        'kind whatever it is named', () async {
      final store = ProfileStore.instance;
      await store.ensureLoaded();
      await store.setAdminPin('9999');
      final devicePin = store.adminProfile!.pinHash;
      final deviceRecovery = await store.adminRecoveryHash();
      final summary = await importProfilesData(
        const ParsedProfiles(
          profiles: [
            BundleProfile(name: 'Papa', kind: 'admin', pinHash: 'b:pin'),
          ],
          adminRecovery: 'b:recovery',
        ),
        const {},
        addressByMember: const {},
        lists: const [],
      );
      expect(summary.merged, 1);
      expect(summary.added, 0); // never a second admin
      expect(store.adminProfile!.pinHash, devicePin);
      expect(await store.adminRecoveryHash(), deviceRecovery);
      expect(store.profiles, hasLength(1));
    });
  });

  group('importProfilesData — new profiles', () {
    test('unmatched backup profiles are created fresh with PIN, lists, '
        'file avatar, auto-login and history', () async {
      final store = ProfileStore.instance;
      await store.ensureLoaded();
      final lists = [MediaList(id: 'l1', title: 'Movies', entries: const [])];
      await LibraryStore.save(lists);
      final summary = await importProfilesData(
        const ParsedProfiles(profiles: [
          BundleProfile(
              name: 'Ellie',
              kind: 'kid',
              avatar: 'profile_avatar_old_2.img',
              pinHash: 'kid:pin',
              autoLogin: true,
              allowedLists: ['Movies'],
              historyByMember: {
                'a.datamap': (
                  positionMs: 60000,
                  durationMs: 120000,
                  completed: false,
                  updatedAt: 500
                ),
              }),
        ]),
        {
          'profile_avatar_old_2.img': Uint8List.fromList([9]),
        },
        addressByMember: {'a.datamap': _addr(3)},
        lists: lists,
      );
      expect(summary.added, 1);
      expect(summary.merged, 0);
      expect(summary.historyMerged, 1);
      final ellie = store.profiles.firstWhere((p) => p.name == 'Ellie');
      expect(ellie.kind, ProfileKind.kid);
      expect(ellie.pinHash, 'kid:pin');
      expect(ellie.autoLogin, isTrue); // nobody on the device had it
      expect(ellie.avatar, startsWith('profile_avatar_${ellie.id}_'));
      expect(await store.allowedListIds(ellie.id), {'l1'});
      expect((await _stateOf(_addr(3), ellie.id))!.positionMs, 60000);
    });
  });
}
