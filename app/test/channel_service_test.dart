import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/services/channel_service.dart';
import 'package:watchit/services/channels_api.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/list_import.dart';
import 'package:watchit/services/publish_api.dart';

import 'fake_embedded_http.dart';

/// A minimal channel manifest zip: channel.json + one `.datamap` member
/// whose first byte determines the fake-derived address.
Uint8List manifestZip({
  required String pubkey,
  String name = 'Nature Films',
  String description = 'My own footage',
  String? author,
  String? avatarName,
  List<int>? avatarBytes,
  Map<String, List<int>> members = const {
    'Waterfall (2026).mp4.datamap': [0x11],
  },
  bool withChannelJson = true,
}) {
  final archive = Archive();
  if (withChannelJson) {
    archive.addFile(ArchiveFile.string(
      'channel.json',
      jsonEncode({
        'version': 1,
        'name': name,
        'description': description,
        'author': ?author,
        'avatar': ?avatarName,
        'pubkey': pubkey,
        'seq': 1,
      }),
    ));
  }
  final listText = StringBuffer()..writeln('ListName="$name"');
  for (final e in members.entries) {
    archive.addFile(
        ArchiveFile.bytes('datamaps/${e.key}', Uint8List.fromList(e.value)));
    listText.writeln(e.key);
  }
  archive.addFile(ArchiveFile.string('list.txt', listText.toString()));
  if (avatarBytes != null) {
    final member = avatarName ?? channelAvatarMemberName(avatarBytes);
    archive.addFile(ArchiveFile.bytes(
        'posters/$member', Uint8List.fromList(avatarBytes)));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late FakeEmbeddedHttp fake;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    fake = FakeEmbeddedHttp();
    HttpOverrides.global = fake;
    ChannelService.resetForTesting();
    ChannelService.instance.api = ChannelsApi(base: FakeEmbeddedHttp.base);
    ChannelService.instance.publishApi =
        PublishApi(base: FakeEmbeddedHttp.base);
    ChannelService.instance.importBase = FakeEmbeddedHttp.base;
    ChannelService.instance.postersDirProvider =
        () async => await Directory.systemTemp.createTemp('wi-ch-posters');
  });

  tearDown(() {
    HttpOverrides.global = null;
  });

  group('parseChannelManifest', () {
    test('reads channel.json plus the bundle members', () {
      final zip = manifestZip(pubkey: 'AB' * 32);
      final parsed = parseChannelManifest(zip);
      expect(parsed.channel.name, 'Nature Films');
      expect(parsed.channel.description, 'My own footage');
      // Pubkey normalized to lowercase.
      expect(parsed.channel.pubkey, 'ab' * 32);
      expect(parsed.channel.seq, 1);
      expect(parsed.bundle.datamapMembers.keys,
          ['Waterfall (2026).mp4.datamap']);
    });

    test('a plain bundle without channel.json is refused', () {
      final zip = manifestZip(pubkey: 'ab' * 32, withChannelJson: false);
      expect(() => parseChannelManifest(zip),
          throwsA(isA<ListImportException>()));
    });

    test('garbage is refused', () {
      expect(() => parseChannelManifest(Uint8List.fromList([1, 2, 3])),
          throwsA(isA<ListImportException>()));
    });
  });

  group('subscribe / unsubscribe', () {
    test('subscribe registers with the core and creates a record',
        () async {
      final code = 'wchn1-${'b' * 52}';
      await ChannelService.instance.subscribe(code);
      expect(fake.channelSubscribes, [code]);
      final pubkey = FakeEmbeddedHttp.subscribePubkeyFor(code);
      final record = await ChannelService.instance.record(pubkey);
      expect(record, isNotNull);
      expect(record!.importedSeq, 0);
    });

    test('unsubscribe drops the core sub, the record, and the list',
        () async {
      final pubkey = 'cd' * 32;
      await LibraryStore.save([
        MediaList(
          id: 'channel-x',
          title: 'Their channel',
          entries: const [MediaEntry(name: 'a.mp4', address: 'ff00')],
          channelPubkey: pubkey,
        ),
        const MediaList(id: 'mine', title: 'Mine'),
      ]);
      // Seed a record via the same path subscribe would use.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          'channel_subs_v1', jsonEncode({pubkey: {'importedSeq': 3}}));
      await ChannelService.instance.unsubscribe(pubkey);
      expect(fake.channelUnsubscribes, [pubkey]);
      expect(await ChannelService.instance.record(pubkey), isNull);
      final lists = await LibraryStore.load();
      expect(lists.map((l) => l.id), ['mine']);
    });
  });

  group('syncNow', () {
    final pubkey = 'ab' * 32; // matches manifestZip's default (lowercased)
    final manifestAddr = 'ee' * 32;

    Future<void> seedSubscription({int importedSeq = 0}) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('channel_subs_v1',
          jsonEncode({pubkey: {'importedSeq': importedSeq}}));
      fake.channelsStatus = {
        'supported': true,
        'state': 'ready',
        'own': null,
        'subs': [
          {
            'pubkey': pubkey,
            'code': 'wchn1-x',
            'head': {'seq': 2, 'manifest': manifestAddr},
          },
        ],
      };
    }

    test('imports a newer manifest as a read-only channel list', () async {
      await seedSubscription();
      fake.channelManifests[manifestAddr] = manifestZip(pubkey: pubkey);
      await ChannelService.instance.syncNow();
      final lists = await LibraryStore.load();
      final channel = lists.singleWhere((l) => l.channelPubkey == pubkey);
      expect(channel.title, 'Nature Films');
      expect(channel.isChannel, isTrue);
      expect(channel.entries.single.address, '11' * 32);
      final record = await ChannelService.instance.record(pubkey);
      expect(record!.importedSeq, 2);
      expect(record.name, 'Nature Films');
      expect(ChannelService.instance.lastProblem, isEmpty);
    });

    test('replaces the list wholesale on the next version', () async {
      await seedSubscription();
      fake.channelManifests[manifestAddr] = manifestZip(pubkey: pubkey);
      await ChannelService.instance.syncNow();
      // v3 renames the channel and swaps the item.
      final addr3 = 'dd' * 32;
      fake.channelsStatus = {
        ...fake.channelsStatus,
        'subs': [
          {
            'pubkey': pubkey,
            'code': 'wchn1-x',
            'head': {'seq': 3, 'manifest': addr3},
          },
        ],
      };
      fake.channelManifests[addr3] = manifestZip(
        pubkey: pubkey,
        name: 'Nature Films HD',
        members: const {'Glacier (2026).mp4.datamap': [0x22]},
      );
      await ChannelService.instance.syncNow();
      final lists = await LibraryStore.load();
      final channel = lists.singleWhere((l) => l.channelPubkey == pubkey);
      expect(channel.title, 'Nature Films HD');
      expect(channel.entries.single.address, '22' * 32);
      expect(channel.entries.single.name, 'Glacier (2026).mp4');
    });

    test('already-imported seq is not refetched', () async {
      await seedSubscription(importedSeq: 2);
      await ChannelService.instance.syncNow();
      expect(
          fake.requests.where((r) => r.contains('/channel/manifest/')),
          isEmpty);
    });

    test('a manifest claiming another channel\'s pubkey is refused',
        () async {
      await seedSubscription();
      fake.channelManifests[manifestAddr] =
          manifestZip(pubkey: 'ff' * 32);
      await ChannelService.instance.syncNow();
      expect(ChannelService.instance.lastProblem[pubkey],
          contains('different channel'));
      final lists = await LibraryStore.load();
      expect(lists.where((l) => l.isChannel), isEmpty);
      // Not marked imported — the next head check retries.
      final record = await ChannelService.instance.record(pubkey);
      expect(record!.importedSeq, 0);
    });
  });

  group('my channel items + manifest build', () {
    test('items stage one at a time, dedup by address', () async {
      const entry =
          MediaEntry(name: 'My Film (2026).mp4', address: 'AA11');
      await ChannelService.instance.addMyItem(entry);
      await ChannelService.instance.addMyItem(entry);
      final items = await ChannelService.instance.myItems();
      expect(items.length, 1);
      expect(items.single.address, 'aa11');
      await ChannelService.instance.removeMyItem('aa11');
      expect(await ChannelService.instance.myItems(), isEmpty);
    });

    test('buildMyManifest writes channel.json + datamap members',
        () async {
      final addr = FakeEmbeddedHttp.addrForByte(0x42);
      fake.datamaps[addr] = [0x42];
      await ChannelService.instance.addMyItem(
          MediaEntry(name: 'My Film (2026).mp4', address: addr));
      const own = OwnChannel(
        name: 'Nature Films',
        description: 'My own footage',
        pubkey: 'ab',
        code: 'wchn1-x',
        seq: 3,
        manifest: 'cc',
        createdAtMs: 1,
      );
      final build =
          await ChannelService.instance.buildMyManifest(own: own);
      final bytes = await File(build.path).readAsBytes();
      final parsed = parseChannelManifest(bytes);
      expect(parsed.channel.name, 'Nature Films');
      expect(parsed.channel.seq, 4); // advisory: last published + 1
      expect(parsed.channel.previous, 'cc');
      expect(parsed.bundle.datamapMembers.keys,
          ['My Film (2026).mp4.datamap']);
      expect(build.entriesIncluded, 1);
      File(build.path).parent.deleteSync(recursive: true);
    });

    test('an empty channel refuses to build', () async {
      const own = OwnChannel(
        name: 'x',
        description: '',
        pubkey: 'ab',
        code: 'c',
        seq: 0,
        manifest: '',
        createdAtMs: 1,
      );
      expect(ChannelService.instance.buildMyManifest(own: own),
          throwsA(isA<PublishApiException>()));
    });
  });

  group('own channel in the library', () {
    final pubkey = 'ab' * 32; // matches manifestZip's default (lowercased)
    final manifestAddr = 'ee' * 32;

    void seedOwn({Map<String, dynamic>? head, String name = 'Nature Films'}) {
      fake.channelsStatus = {
        'supported': true,
        'state': 'ready',
        'own': {
          'name': name,
          'description': '',
          'pubkey': pubkey,
          'code': 'wchn1-own',
          'seq': head?['seq'] ?? 0,
          'manifest': '',
          'created_at_ms': 5,
          'head': head,
        },
        'subs': const [],
      };
    }

    test('a freshly created channel appears as an empty amber list',
        () async {
      seedOwn();
      await ChannelService.instance.syncNow();
      final lists = await LibraryStore.load();
      final channel = lists.singleWhere((l) => l.channelPubkey == pubkey);
      expect(channel.isChannel, isTrue);
      expect(channel.title, 'Nature Films');
      expect(channel.entries, isEmpty);
    });

    test('a rename before the first publish follows the config name',
        () async {
      seedOwn();
      await ChannelService.instance.syncNow();
      seedOwn(name: 'Nature Films HD');
      await ChannelService.instance.syncNow();
      final lists = await LibraryStore.load();
      final channel = lists.singleWhere((l) => l.channelPubkey == pubkey);
      expect(channel.title, 'Nature Films HD');
      expect(lists.where((l) => l.isChannel).length, 1);
    });

    test('a published head imports the manifest into the own list',
        () async {
      seedOwn(head: {'seq': 1, 'manifest': manifestAddr});
      fake.channelManifests[manifestAddr] = manifestZip(pubkey: pubkey);
      await ChannelService.instance.syncNow();
      final lists = await LibraryStore.load();
      final channel = lists.singleWhere((l) => l.channelPubkey == pubkey);
      expect(channel.title, 'Nature Films');
      expect(channel.entries.single.address, '11' * 32);
      expect(ChannelService.instance.lastProblem, isEmpty);
      // The imported seq is remembered — no refetch on the next check.
      fake.requests.clear();
      await ChannelService.instance.syncNow();
      expect(fake.requests.where((r) => r.contains('/channel/manifest/')),
          isEmpty);
    });

    test('removing the channel removes its list', () async {
      seedOwn();
      await ChannelService.instance.syncNow();
      fake.channelsStatus = {
        'supported': true,
        'state': 'ready',
        'own': null,
        'subs': const [],
      };
      await ChannelService.instance.syncNow();
      final lists = await LibraryStore.load();
      expect(lists.where((l) => l.isChannel), isEmpty);
    });

    test('a failed manifest fetch still leaves the list standing',
        () async {
      seedOwn(head: {'seq': 1, 'manifest': manifestAddr});
      // No manifest served — the fetch 404s.
      await ChannelService.instance.syncNow();
      final lists = await LibraryStore.load();
      expect(lists.singleWhere((l) => l.channelPubkey == pubkey).entries,
          isEmpty);
      expect(ChannelService.instance.lastProblem[pubkey], isNotNull);
    });
  });

  group('sync view + tombstones', () {
    test('unsubscribe leaves a tombstone; re-subscribe keeps its own time',
        () async {
      final code = 'wchn1-${'b' * 52}';
      await ChannelService.instance.subscribe(code, addedMs: 111);
      final pubkey = FakeEmbeddedHttp.subscribePubkeyFor(code);
      final record = await ChannelService.instance.record(pubkey);
      expect(record!.addedMs, 111);
      await ChannelService.instance.unsubscribe(pubkey, removedMs: 222);
      expect(await ChannelService.instance.subStones(), {pubkey: 222});
      // An older stone never regresses a newer one.
      await ChannelService.instance.unsubscribe(pubkey, removedMs: 5);
      expect(await ChannelService.instance.subStones(), {pubkey: 222});
    });

    test('adoptSubStones keeps only newer stones', () async {
      await ChannelService.instance
          .adoptSubStones({'aa' * 32: 100, 'bb' * 32: 50});
      await ChannelService.instance
          .adoptSubStones({'aa' * 32: 90, 'bb' * 32: 60});
      expect(await ChannelService.instance.subStones(),
          {'aa' * 32: 100, 'bb' * 32: 60});
    });

    test('syncView carries subs with codes, stones, and the own channel',
        () async {
      final subPubkey = 'cd' * 32;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('channel_subs_v1',
          jsonEncode({subPubkey: {'addedMs': 777, 'importedSeq': 1}}));
      await prefs.setString(
          'channel_sub_stones_v1', jsonEncode({'ee' * 32: 42}));
      fake.channelsStatus = {
        'supported': true,
        'state': 'ready',
        'own': {
          'name': 'Mine',
          'description': '',
          'pubkey': 'ab' * 32,
          'code': 'wchn1-own',
          'seq': 0,
          'manifest': '',
          'created_at_ms': 5,
          'head': null,
        },
        'subs': [
          {'pubkey': subPubkey, 'code': 'wchn1-sub', 'head': null},
        ],
      };
      final view = await ChannelService.instance.syncView();
      expect(view, isNotNull);
      expect(view!.subs[subPubkey]!.code, 'wchn1-sub');
      expect(view.subs[subPubkey]!.addedMs, 777);
      expect(view.stones, {'ee' * 32: 42});
      expect(view.ownPubkey, 'ab' * 32);
      expect(view.ownCode, 'wchn1-own');
      expect(view.ownAddedMs, 5);
    });

    test('syncView is null while channels are unsupported', () async {
      fake.channelsStatus = {'supported': false, 'state': 'off'};
      expect(await ChannelService.instance.syncView(), isNull);
    });
  });

  group('channel profile (author + avatar)', () {
    final pubkey = 'ab' * 32;
    final manifestAddr = 'ee' * 32;
    final avatarBytes = List<int>.generate(64, (i) => i);
    late String avatarName;
    late Directory postersDir;
    late Directory profileDir;

    setUp(() async {
      avatarName = channelAvatarMemberName(avatarBytes);
      postersDir = await Directory.systemTemp.createTemp('wi-ch-posters');
      profileDir = await Directory.systemTemp.createTemp('wi-ch-profile');
      addTearDown(() => postersDir.delete(recursive: true));
      addTearDown(() {
        if (profileDir.existsSync()) profileDir.deleteSync(recursive: true);
      });
      ChannelService.instance.postersDirProvider = () async => postersDir;
      ChannelService.instance.profileDirProvider = () async => profileDir;
    });

    test('member names are content-hashed and validated', () {
      expect(avatarName, matches(r'^channel_avatar_[0-9a-f]{8}\.img$'));
      expect(channelAvatarMemberName(avatarBytes), avatarName);
      expect(channelAvatarMemberName([1, 2, 3]), isNot(avatarName));
      expect(isChannelAvatarMemberName(avatarName), isTrue);
      expect(isChannelAvatarMemberName('../evil.img'), isFalse);
      expect(isChannelAvatarMemberName('channel_avatar_x.img'), isFalse);
      expect(
          isChannelAvatarMemberName('posters/channel_avatar_00112233.img'),
          isFalse);
    });

    test('parse reads author + avatar; hostile avatar names drop', () {
      final parsed = parseChannelManifest(manifestZip(
        pubkey: pubkey,
        author: '  @neil  ',
        avatarName: avatarName,
        avatarBytes: avatarBytes,
      ));
      expect(parsed.channel.author, '@neil');
      expect(parsed.channel.avatar, avatarName);
      expect(parsed.bundle.posters[avatarName], avatarBytes);

      final evil = parseChannelManifest(
          manifestZip(pubkey: pubkey, avatarName: '../../etc/passwd'));
      expect(evil.channel.avatar, isNull);

      final plain = parseChannelManifest(manifestZip(pubkey: pubkey));
      expect(plain.channel.author, isEmpty);
      expect(plain.channel.avatar, isNull);
    });

    test('setMyAvatar stores the crop + a posters copy; clear removes',
        () async {
      final service = ChannelService.instance;
      await service.setMyAvatar(Uint8List.fromList(avatarBytes));
      final file = await service.myAvatarFile();
      expect(file, isNotNull);
      expect(file!.uri.pathSegments.last, avatarName);
      expect(File('${postersDir.path}/$avatarName').existsSync(), isTrue);

      // A new crop replaces the old one (fresh hash name).
      final other = List<int>.filled(16, 7);
      await service.setMyAvatar(Uint8List.fromList(other));
      final replaced = await service.myAvatarFile();
      expect(replaced!.uri.pathSegments.last,
          channelAvatarMemberName(other));
      expect(File('${profileDir.path}/$avatarName').existsSync(), isFalse);

      await service.clearMyAvatar();
      expect(await service.myAvatarFile(), isNull);
    });

    test('an avatar over the 2 MB cap is refused', () async {
      final big = Uint8List(kMaxChannelAvatarBytes + 1);
      expect(ChannelService.instance.setMyAvatar(big),
          throwsA(isA<PublishApiException>()));
    });

    test('buildMyManifest carries author + the avatar poster member',
        () async {
      final addr = FakeEmbeddedHttp.addrForByte(0x42);
      fake.datamaps[addr] = [0x42];
      await ChannelService.instance
          .addMyItem(MediaEntry(name: 'My Film (2026).mp4', address: addr));
      await ChannelService.instance
          .setMyAvatar(Uint8List.fromList(avatarBytes));
      const own = OwnChannel(
        name: 'Nature Films',
        description: 'My own footage',
        author: 'Neil',
        pubkey: 'ab',
        code: 'wchn1-x',
        seq: 0,
        manifest: '',
        createdAtMs: 1,
      );
      final build =
          await ChannelService.instance.buildMyManifest(own: own);
      final parsed =
          parseChannelManifest(await File(build.path).readAsBytes());
      expect(parsed.channel.author, 'Neil');
      expect(parsed.channel.avatar, avatarName);
      expect(parsed.bundle.posters[avatarName], avatarBytes);
      File(build.path).parent.deleteSync(recursive: true);
    });

    test('an authorless, avatarless build omits both keys', () async {
      final addr = FakeEmbeddedHttp.addrForByte(0x42);
      fake.datamaps[addr] = [0x42];
      await ChannelService.instance
          .addMyItem(MediaEntry(name: 'My Film (2026).mp4', address: addr));
      const own = OwnChannel(
        name: 'Nature Films',
        description: '',
        pubkey: 'ab',
        code: 'wchn1-x',
        seq: 0,
        manifest: '',
        createdAtMs: 1,
      );
      final build =
          await ChannelService.instance.buildMyManifest(own: own);
      final bytes = await File(build.path).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      final channelJson = jsonDecode(utf8.decode(
              archive.files.singleWhere((f) => f.name == 'channel.json').readBytes()!))
          as Map<String, dynamic>;
      expect(channelJson.containsKey('author'), isFalse);
      expect(channelJson.containsKey('avatar'), isFalse);
      expect(archive.files.where((f) => f.name.startsWith('posters/')),
          isEmpty);
      File(build.path).parent.deleteSync(recursive: true);
    });

    test('import refreshes the list + record profile from the manifest',
        () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('channel_subs_v1',
          jsonEncode({pubkey: {'importedSeq': 0}}));
      fake.channelsStatus = {
        'supported': true,
        'state': 'ready',
        'own': null,
        'subs': [
          {
            'pubkey': pubkey,
            'code': 'wchn1-x',
            'head': {'seq': 2, 'manifest': manifestAddr},
          },
        ],
      };
      fake.channelManifests[manifestAddr] = manifestZip(
        pubkey: pubkey,
        author: '@neil',
        avatarName: avatarName,
        avatarBytes: avatarBytes,
      );
      await ChannelService.instance.syncNow();
      final lists = await LibraryStore.load();
      final channel = lists.singleWhere((l) => l.channelPubkey == pubkey);
      expect(channel.channelAuthor, '@neil');
      expect(channel.channelAvatar, avatarName);
      // The avatar member landed in the posters dir (gap-fill).
      expect(File('${postersDir.path}/$avatarName').readAsBytesSync(),
          avatarBytes);
      final record = await ChannelService.instance.record(pubkey);
      expect(record!.author, '@neil');
      expect(record.avatar, avatarName);
    });

    test('a manifest without profile keys clears both on the list',
        () async {
      await LibraryStore.save([
        MediaList(
          id: 'channel-x',
          title: 'Old name',
          channelPubkey: pubkey,
          channelAuthor: 'Old author',
          channelAvatar: 'channel_avatar_00000000.img',
        ),
      ]);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('channel_subs_v1',
          jsonEncode({pubkey: {'importedSeq': 0}}));
      fake.channelsStatus = {
        'supported': true,
        'state': 'ready',
        'own': null,
        'subs': [
          {
            'pubkey': pubkey,
            'code': 'wchn1-x',
            'head': {'seq': 2, 'manifest': manifestAddr},
          },
        ],
      };
      fake.channelManifests[manifestAddr] = manifestZip(pubkey: pubkey);
      await ChannelService.instance.syncNow();
      final channel = (await LibraryStore.load())
          .singleWhere((l) => l.channelPubkey == pubkey);
      expect(channel.channelAuthor, isNull);
      expect(channel.channelAvatar, isNull);
    });

    test('the own pre-publish list shows the config author + avatar',
        () async {
      await ChannelService.instance
          .setMyAvatar(Uint8List.fromList(avatarBytes));
      fake.channelsStatus = {
        'supported': true,
        'state': 'ready',
        'own': {
          'name': 'Nature Films',
          'description': '',
          'author': 'Neil',
          'pubkey': pubkey,
          'code': 'wchn1-own',
          'seq': 0,
          'manifest': '',
          'created_at_ms': 5,
          'head': null,
        },
        'subs': const [],
      };
      await ChannelService.instance.syncNow();
      final channel = (await LibraryStore.load())
          .singleWhere((l) => l.channelPubkey == pubkey);
      expect(channel.channelAuthor, 'Neil');
      expect(channel.channelAvatar, avatarName);
    });

    test('restore recovers author + avatar from the fetched manifest',
        () async {
      fake.channelManifests[manifestAddr] = manifestZip(
        pubkey: pubkey,
        author: '@neil',
        avatarName: avatarName,
        avatarBytes: avatarBytes,
      );
      final count = await ChannelService.instance
          .restoreMyItemsFromManifest(
              ChannelHead(seq: 1, manifest: manifestAddr));
      expect(count, 1);
      // setMeta got the author back…
      expect(fake.channelMetaPosts.single, contains('"author":"@neil"'));
      // …and the avatar crop is back in place for the next publish.
      final file = await ChannelService.instance.myAvatarFile();
      expect(file, isNotNull);
      expect(file!.uri.pathSegments.last, avatarName);
      expect(file.readAsBytesSync(), avatarBytes);
    });
  });
}
