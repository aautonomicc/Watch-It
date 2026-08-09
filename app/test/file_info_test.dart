import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/metadata.dart';
import 'package:watchit/services/seed_catalog.dart';

// Per-entry file size + video-format info (what tells two uploads of
// the same title in different formats apart).

const _addrA =
    'a3f1c9e07b6d5a4f2e8c1b0d9f7a6e5c4b3a2d1e0f9c8b7a6d5e4f3c2b1a0d9e';
const _addrB =
    'b4a2d8f16c7e5b3a1f9d0c8e6b4a2d0f8e6c4b2a0d8f6e4c2b0a8d6f4e2c0b8a';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
  });

  group('format info helpers', () {
    test('formatInfoLine combines label and size, omits unknowns', () {
      expect(
          formatInfoLine(const MediaEntry(
              name: 'a', address: _addrA, sizeBytes: 597585042,
              videoInfo: '480p H.264')),
          '480p H.264 · 570 MB');
      expect(
          formatInfoLine(const MediaEntry(
              name: 'a', address: _addrA, sizeBytes: 2088102883)),
          '1.94 GB');
      expect(
          formatInfoLine(const MediaEntry(
              name: 'a', address: _addrA, videoInfo: '1080p')),
          '1080p');
      expect(formatInfoLine(const MediaEntry(name: 'a', address: _addrA)),
          isNull);
      // Zero/empty values count as unknown, not as data.
      expect(
          formatInfoLine(const MediaEntry(
              name: 'a', address: _addrA, sizeBytes: 0, videoInfo: '')),
          isNull);
    });

    test('resolutionLabel buckets to the standard ladder', () {
      expect(resolutionLabel(2160), '2160p');
      expect(resolutionLabel(1080), '1080p');
      expect(resolutionLabel(1072), '1080p'); // cropped 1080p encode
      expect(resolutionLabel(720), '720p');
      expect(resolutionLabel(576), '576p');
      expect(resolutionLabel(480), '480p');
      expect(resolutionLabel(360), '360p');
      expect(resolutionLabel(240), '240p'); // below the ladder: verbatim
    });

    test('entry JSON round-trips size and format info', () {
      const entry = MediaEntry(
          name: 'Movie.mp4',
          address: _addrA,
          sizeBytes: 123,
          videoInfo: '480p H.264');
      final restored = MediaEntry.fromJson(entry.toJson());
      expect(restored.sizeBytes, 123);
      expect(restored.videoInfo, '480p H.264');
      // Absent stays null (not 0 / empty string).
      final bare = MediaEntry.fromJson(
          const MediaEntry(name: 'a', address: _addrA).toJson());
      expect(bare.sizeBytes, isNull);
      expect(bare.videoInfo, isNull);
    });
  });

  group('seed catalog file info', () {
    test('every catalog entry carries exact size and probed format', () {
      for (final list in kSeedLists) {
        for (final e in list.entries) {
          expect(e.sizeBytes, greaterThan(0), reason: e.name);
          expect(e.videoInfo, matches(RegExp(r'^\d{3,4}p H\.264$')),
              reason: e.name);
        }
      }
    });

    test('format info is the probed truth, not the file name tag', () {
      // The NOTLD archive.org upload says [1080p] in its name but is
      // really 480p — the catalog must carry what ffprobe measured, or
      // the info is worse than none.
      final movies =
          kSeedLists.singleWhere((l) => l.id == 'default-test-movies');
      final notld = movies.entries
          .singleWhere((e) => e.address == kDefaultMovieAddress);
      expect(notld.name, contains('[1080p]'));
      expect(notld.videoInfo, '480p H.264');
    });

    test('the two NOTLD uploads share a name, differ by format info', () {
      // Same film stored twice under the identical network file name —
      // the size/format columns are the only thing telling them apart,
      // which is exactly what they exist for.
      final movies =
          kSeedLists.singleWhere((l) => l.id == 'default-test-movies');
      final notld1080 = movies.entries
          .singleWhere((e) => e.address == kDefaultMovie1080Address);
      expect(notld1080.name, kDefaultMovieName);
      expect(notld1080.videoInfo, '1080p H.264');
      expect(notld1080.sizeBytes, 5682464056);
    });
  });

  group('LibraryStore file info', () {
    test('save/load round-trips size and format info', () async {
      await LibraryStore.save([
        const MediaList(id: 'l', title: 'L', entries: [
          MediaEntry(
              name: 'Movie.mp4',
              address: _addrA,
              sizeBytes: 42,
              videoInfo: '720p'),
          MediaEntry(name: 'Other.mp4', address: _addrB),
        ]),
      ]);
      final loaded = await LibraryStore.load();
      expect(loaded.single.entries[0].sizeBytes, 42);
      expect(loaded.single.entries[0].videoInfo, '720p');
      expect(loaded.single.entries[1].sizeBytes, isNull);
      expect(loaded.single.entries[1].videoInfo, isNull);
    });

    test('noteEntryInfo annotates every list holding the address', () async {
      await LibraryStore.save([
        const MediaList(id: 'l1', title: 'One', entries: [
          MediaEntry(name: 'Movie.mp4', address: _addrA),
          MediaEntry(name: 'Other.mp4', address: _addrB),
        ]),
        const MediaList(id: 'l2', title: 'Two', entries: [
          MediaEntry(name: 'Copy of Movie.mp4', address: _addrA),
        ]),
      ]);
      await LibraryStore.noteEntryInfo(_addrA.toUpperCase(),
          sizeBytes: 99, videoInfo: '1080p');
      final lists = await LibraryStore.load();
      final copies = [
        for (final l in lists)
          for (final e in l.entries)
            if (e.address == _addrA) e,
      ];
      expect(copies, hasLength(2));
      for (final e in copies) {
        expect(e.sizeBytes, 99);
        expect(e.videoInfo, '1080p');
      }
      // The unrelated entry stays untouched.
      final other = lists
          .expand((l) => l.entries)
          .singleWhere((e) => e.address == _addrB);
      expect(other.sizeBytes, isNull);
      expect(other.videoInfo, isNull);
    });

    test('a null argument leaves that column alone', () async {
      await LibraryStore.save([
        const MediaList(id: 'l', title: 'L', entries: [
          MediaEntry(
              name: 'Movie.mp4',
              address: _addrA,
              sizeBytes: 42,
              videoInfo: '720p'),
        ]),
      ]);
      await LibraryStore.noteEntryInfo(_addrA, videoInfo: '1080p');
      final entry = (await LibraryStore.load()).single.entries.single;
      expect(entry.sizeBytes, 42);
      expect(entry.videoInfo, '1080p');
    });

    test('gap-fills catalog info onto an already-seeded install', () async {
      // Seeded before the columns existed: the flag is set and the
      // entries carry no info.
      SharedPreferences.setMockInitialValues({'defaults_seeded_v4': true});
      await LibraryStore.save([
        const MediaList(id: 'default-test-movies', title: 'Movies', entries: [
          MediaEntry(name: kDefaultMovieName, address: kDefaultMovieAddress),
          MediaEntry(name: 'My Import.mp4', address: _addrB),
        ]),
      ]);
      await LibraryStore.ensureDefaults();
      final entries = (await LibraryStore.load())
          .expand((l) => l.entries)
          .toList();
      final seedInfo = kSeedLists
          .expand((l) => l.entries)
          .singleWhere((e) => e.address == kDefaultMovieAddress);
      final notld = entries
          .singleWhere((e) => e.address == kDefaultMovieAddress);
      expect(notld.sizeBytes, seedInfo.sizeBytes);
      expect(notld.videoInfo, seedInfo.videoInfo);
      // Non-catalog entries are never touched, and nothing is re-added.
      final mine = entries.singleWhere((e) => e.address == _addrB);
      expect(mine.sizeBytes, isNull);
      expect(mine.videoInfo, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('seed_fileinfo_v1'), isTrue);
    });

    test('fresh seeding writes the catalog info directly', () async {
      await LibraryStore.ensureDefaults();
      final lists = await LibraryStore.load();
      for (final seed in kSeedLists) {
        final seeded = lists.singleWhere((l) => l.title == seed.title);
        for (final (i, e) in seed.entries.indexed) {
          expect(seeded.entries[i].sizeBytes, e.sizeBytes, reason: e.name);
          expect(seeded.entries[i].videoInfo, e.videoInfo, reason: e.name);
        }
      }
    });
  });
}
