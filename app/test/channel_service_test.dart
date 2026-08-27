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
}
