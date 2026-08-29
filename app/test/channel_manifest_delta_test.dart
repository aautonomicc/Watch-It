import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchit/services/channel_manifest_delta.dart';
import 'package:watchit/services/channel_service.dart';
import 'package:watchit/services/channels_api.dart';
import 'package:watchit/services/list_import.dart';
import 'package:watchit/services/zip_ranges.dart';

/// Deterministic incompressible bytes (posters are stored uncompressed,
/// like real JPEGs).
Uint8List noise(int len, int seed) {
  final rng = Random(seed);
  return Uint8List.fromList(
      List<int>.generate(len, (_) => rng.nextInt(256)));
}

/// A channel manifest zip in buildBundle's member order: channel.json
/// first, then datamaps + list.txt + metadata.json, posters last.
Uint8List manifestZip({
  required Map<String, Uint8List> posters,
  String pubkey = 'abababababababababababababababababababababababababababababababab',
}) {
  final archive = Archive();
  archive.addFile(ArchiveFile.string(
      'channel.json',
      jsonEncode(
          {'version': 1, 'name': 'Nature', 'description': '', 'pubkey': pubkey, 'seq': 2})));
  final listText = StringBuffer()..writeln('ListName="Nature"');
  for (var i = 0; i < 3; i++) {
    archive.addFile(ArchiveFile.bytes(
        'datamaps/Clip $i (2026).mp4.datamap', noise(300, 900 + i)));
    listText.writeln('Clip $i (2026).mp4.datamap');
  }
  archive.addFile(ArchiveFile.string('list.txt', listText.toString()));
  archive.addFile(ArchiveFile.string(
      'metadata.json',
      jsonEncode({
        'version': 1,
        'entries': [
          for (final name in posters.keys)
            {'lookupKey': 'movie:$name', 'title': name, 'posterFile': name},
        ],
      })));
  for (final e in posters.entries) {
    archive.addFile(
        ArchiveFile.noCompress('posters/${e.key}', e.value.length, e.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// A range-header-honouring fake of the manifest route, recording every
/// requested absolute range.
ManifestRangeFetch rangeServer(Uint8List zip, List<(int, int)> log) {
  return (String range) async {
    final suffix = RegExp(r'^bytes=-(\d+)$').firstMatch(range);
    final explicit = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range);
    int start, end; // inclusive
    if (suffix != null) {
      start = max(0, zip.length - int.parse(suffix.group(1)!));
      end = zip.length - 1;
    } else if (explicit != null) {
      start = int.parse(explicit.group(1)!);
      end = min(int.parse(explicit.group(2)!), zip.length - 1);
    } else {
      throw StateError('unsupported range: $range');
    }
    log.add((start, end));
    return ManifestRangeResponse(
      status: 206,
      bytes: Uint8List.sublistView(zip, start, end + 1),
      start: start,
      total: zip.length,
    );
  };
}

void main() {
  final posters = {
    for (var i = 0; i < 4; i++) 'movie_$i.jpg': noise(40 * 1024, i),
  };
  final zip = manifestZip(posters: posters);

  test('the manifest layout is bigger than the tail read', () {
    // The delta path only exists past the tail; keep the fixture honest.
    expect(zip.length, greaterThan(kManifestTailBytes));
  });

  group('zip_ranges', () {
    test('crc32 matches the known check vector', () {
      expect(zipCrc32(Uint8List.fromList(utf8.encode('123456789'))),
          0xCBF43926);
    });

    test('directory parse + extraction reproduce every member', () {
      final tailStart = zip.length - kManifestTailBytes;
      final tail = Uint8List.sublistView(zip, tailStart);
      final eocd = findZipEocd(tail, tailStart, zip.length)!;
      final cd =
          Uint8List.sublistView(zip, eocd.cdOffset, eocd.cdOffset + eocd.cdSize);
      final entries = parseZipCentralDirectory(cd, eocd)!;
      final decoded = ZipDecoder().decodeBytes(zip, verify: true);
      expect(entries.map((e) => e.name).toSet(),
          decoded.files.map((f) => f.name).toSet());
      final spans = zipMemberSpans(entries, eocd.cdOffset)!;
      for (final entry in entries) {
        final data =
            extractZipMember(entry, spans[entry]!, zip, 0);
        expect(data, isNotNull, reason: entry.name);
        expect(data, decoded.files.firstWhere((f) => f.name == entry.name).readBytes(),
            reason: entry.name);
      }
    });

    test('a corrupted member fails extraction instead of lying', () {
      final tailStart = zip.length - kManifestTailBytes;
      final tail = Uint8List.sublistView(zip, tailStart);
      final eocd = findZipEocd(tail, tailStart, zip.length)!;
      final cd =
          Uint8List.sublistView(zip, eocd.cdOffset, eocd.cdOffset + eocd.cdSize);
      final entries = parseZipCentralDirectory(cd, eocd)!;
      final spans = zipMemberSpans(entries, eocd.cdOffset)!;
      final poster =
          entries.firstWhere((e) => e.name.startsWith('posters/'));
      final corrupted = Uint8List.fromList(zip);
      // Near the span's end — inside the stored poster's data, safely
      // past the local header + name.
      corrupted[spans[poster]!.end - 10] ^= 0xFF;
      expect(extractZipMember(poster, spans[poster]!, corrupted, 0), isNull);
    });

    test('no end-of-directory record means no plan', () {
      final garbage = noise(4096, 7);
      expect(findZipEocd(garbage, 1000, 1000 + garbage.length), isNull);
    });

    test('coalesce merges only close neighbours', () {
      final merged = coalesceSpans([
        (start: 0, end: 10),
        (start: 12, end: 20),
        (start: 500, end: 600),
      ], gap: 16);
      expect(merged, [(start: 0, end: 20), (start: 500, end: 600)]);
    });
  });

  group('fetchManifestMembersDelta', () {
    test('skips held posters and never requests their bytes', () async {
      final held = {'movie_0.jpg', 'movie_1.jpg', 'movie_2.jpg'};
      final log = <(int, int)>[];
      final delta = await fetchManifestMembersDelta(
        fetch: rangeServer(zip, log),
        havePoster: held.contains,
        tailBytes: 4096,
      );
      expect(delta, isNotNull);
      expect(delta!.members, isNotNull);
      expect(delta.postersSkipped, 3);
      expect(delta.totalSize, zip.length);
      expect(delta.bytesFetched, lessThan(zip.length - 2 * 40 * 1024),
          reason: 'held posters must not be downloaded');

      // The held posters' data ranges were never requested (their spans
      // may graze a neighbour's coalesced read, so check the bulk).
      final tailStart = zip.length - 4096;
      final tail = Uint8List.sublistView(zip, tailStart);
      final eocd = findZipEocd(tail, tailStart, zip.length)!;
      final cd = Uint8List.sublistView(
          zip, eocd.cdOffset, eocd.cdOffset + eocd.cdSize);
      final entries = parseZipCentralDirectory(cd, eocd)!;
      final spans = zipMemberSpans(entries, eocd.cdOffset)!;
      final dataRequests =
          log.where((r) => !(r.$1 == tailStart && r.$2 == zip.length - 1));
      for (final entry in entries) {
        final base = posterMemberBase(entry.name);
        if (base == null || !held.contains(base)) continue;
        final span = spans[entry]!;
        if (span.start >= tailStart) continue; // free with the tail read
        final mid = (span.start + span.end) ~/ 2;
        expect(dataRequests.any((r) => r.$1 <= mid && mid <= r.$2), isFalse,
            reason: '${entry.name} bytes were fetched');
      }

      // The assembled members parse into the same manifest, minus the
      // held posters.
      final parsed = parseChannelManifestMembers(delta.members!);
      final full = parseChannelManifest(zip);
      expect(parsed.channel.pubkey, full.channel.pubkey);
      expect(parsed.channel.seq, full.channel.seq);
      expect(parsed.bundle.listText, full.bundle.listText);
      expect(parsed.bundle.datamapMembers.keys.toSet(),
          full.bundle.datamapMembers.keys.toSet());
      for (final name in full.bundle.datamapMembers.keys) {
        expect(parsed.bundle.datamapMembers[name],
            full.bundle.datamapMembers[name]);
      }
      expect(parsed.bundle.metadataRows.keys.toSet(),
          full.bundle.metadataRows.keys.toSet());
      expect(parsed.bundle.posters.keys.toSet(), {'movie_3.jpg'});
      expect(parsed.bundle.posters['movie_3.jpg'], posters['movie_3.jpg']);
    });

    test('an unchanged channel avatar is skipped like any held poster',
        () async {
      // A manifest whose channel.json names an avatar member; the
      // subscriber already holds the avatar file (unchanged since the
      // last import) but not the new poster.
      final avatarBytes = noise(50 * 1024, 77);
      final avatarName = channelAvatarMemberName(avatarBytes);
      final archive = Archive();
      archive.addFile(ArchiveFile.string(
          'channel.json',
          jsonEncode({
            'version': 1,
            'name': 'Nature',
            'description': '',
            'author': 'Neil',
            'avatar': avatarName,
            'pubkey': 'ab' * 32,
            'seq': 3,
          })));
      archive.addFile(ArchiveFile.bytes(
          'datamaps/Clip (2026).mp4.datamap', noise(300, 1)));
      archive.addFile(
          ArchiveFile.string('list.txt', 'ListName="Nature"\nClip (2026).mp4.datamap\n'));
      final newPoster = noise(40 * 1024, 78);
      archive.addFile(ArchiveFile.noCompress(
          'posters/movie_9.jpg', newPoster.length, newPoster));
      archive.addFile(ArchiveFile.noCompress(
          'posters/$avatarName', avatarBytes.length, avatarBytes));
      final avatarZip = Uint8List.fromList(ZipEncoder().encode(archive));

      final log = <(int, int)>[];
      final delta = await fetchManifestMembersDelta(
        fetch: rangeServer(avatarZip, log),
        havePoster: (base) => base == avatarName,
        tailBytes: 4096,
      );
      expect(delta, isNotNull);
      expect(delta!.postersSkipped, 1);
      expect(delta.bytesFetched, lessThan(avatarZip.length - 40 * 1024),
          reason: 'the held avatar must not be downloaded');
      final parsed = parseChannelManifestMembers(delta.members!);
      expect(parsed.channel.avatar, avatarName);
      expect(parsed.channel.author, 'Neil');
      // The new poster still travelled; the avatar bytes did not.
      expect(parsed.bundle.posters.keys.toSet(), {'movie_9.jpg'});
    });

    test('nothing held falls back to the plain fetch (null)', () async {
      final log = <(int, int)>[];
      final delta = await fetchManifestMembersDelta(
        fetch: rangeServer(zip, log),
        havePoster: (_) => false,
        tailBytes: 4096,
      );
      expect(delta, isNull);
    });

    test('a 200 answer is used as the whole manifest', () async {
      final delta = await fetchManifestMembersDelta(
        fetch: (_) async => ManifestRangeResponse(status: 200, bytes: zip),
        havePoster: (_) => true,
      );
      expect(delta, isNotNull);
      expect(delta!.fullBytes, zip);
      expect(delta.members, isNull);
      final parsed = parseChannelManifest(delta.fullBytes!);
      expect(parsed.bundle.posters.length, posters.length);
    });

    test('a tail that covers the whole zip is used directly', () async {
      final log = <(int, int)>[];
      final delta = await fetchManifestMembersDelta(
        fetch: rangeServer(zip, log),
        havePoster: (_) => true,
        tailBytes: zip.length + 100,
      );
      expect(delta, isNotNull);
      expect(delta!.fullBytes, isNotNull);
      expect(Uint8List.fromList(delta.fullBytes!), zip);
      expect(log, hasLength(1));
    });

    test('garbage bytes cannot be planned', () async {
      final junk = noise(200 * 1024, 3);
      final delta = await fetchManifestMembersDelta(
        fetch: rangeServer(junk, []),
        havePoster: (_) => true,
        tailBytes: 4096,
      );
      expect(delta, isNull);
    });

    test('an over-cap manifest is refused, not fallen back on', () {
      expect(
        fetchManifestMembersDelta(
          fetch: (_) async => ManifestRangeResponse(
              status: 206,
              bytes: Uint8List(10),
              start: 300 * 1024 * 1024 - 10,
              total: 300 * 1024 * 1024),
          havePoster: (_) => true,
        ),
        throwsA(isA<ListImportException>()),
      );
    });

    test('range responses parse Content-Range (real socket)', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      String? seenRange;
      server.listen((req) {
        seenRange = req.headers.value('range');
        req.response.statusCode = 206;
        req.response.headers.set('content-range', 'bytes 10-19/1234');
        req.response.add(List.filled(10, 7));
        req.response.close();
      });
      final api = ChannelsApi(
          base: 'http://127.0.0.1:${server.port}', token: 'test-token');
      final res = await api.fetchManifestRange('aa' * 32, 'bytes=10-19');
      expect(seenRange, 'bytes=10-19');
      expect(res.status, 206);
      expect(res.start, 10);
      expect(res.total, 1234);
      expect(res.bytes, List.filled(10, 7));
      await server.close();
    });

    test('members straddling the tail boundary stitch cleanly', () async {
      // Tiny tail: the directory read lands mid-poster, so at least one
      // needed member crosses the boundary. Hold nothing needed? Hold
      // one early poster so the delta path runs while later posters
      // (including the straddler) must be fetched + stitched.
      final log = <(int, int)>[];
      final delta = await fetchManifestMembersDelta(
        fetch: rangeServer(zip, log),
        havePoster: {'movie_0.jpg'}.contains,
        tailBytes: 2048,
      );
      expect(delta, isNotNull, reason: 'stitching must not fail the plan');
      expect(delta!.postersSkipped, 1);
      final parsed = parseChannelManifestMembers(delta.members!);
      expect(parsed.bundle.posters.keys.toSet(),
          {'movie_1.jpg', 'movie_2.jpg', 'movie_3.jpg'});
      for (final name in parsed.bundle.posters.keys) {
        expect(parsed.bundle.posters[name], posters[name], reason: name);
      }
    });
  });
}
