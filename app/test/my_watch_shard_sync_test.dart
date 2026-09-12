// The sharded sync doc (alpha.98): a library too big for one
// value-capped store doc splits across `<agent>/sync` + `<agent>/sync/N`
// parts, and whatever still does not fit rotates through later cycles
// instead of the same tail starving forever — the Fire-Stick follow-up
// to the alpha.96 budget fix ("85 list entries did not fit … every
// cycle").
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:watchit/models/media_list.dart';
import 'package:watchit/services/my_watch_api.dart';
import 'package:watchit/services/my_watch_sync.dart';

String _addr(int i) => i.toRadixString(16).padLeft(64, '0');

/// ~150 doc bytes per entry, like a real library row.
MediaEntry _fatEntry(int i) => MediaEntry(
      name: 'A rather long movie file name number $i (1080p).mp4',
      address: _addr(i + 1),
      addedAt: 1000 + i,
      sizeBytes: 1234567890,
      videoInfo: '1080p H.264 AAC stereo 2.4 GB',
    );

List<Map<String, dynamic>> _fatMetaRows(int n) => [
      // Newest-first, like _localMetaRows().
      for (var i = 0; i < n; i++)
        {
          'key': 'movie:title $i:2020',
          'updated_ms': 5000 - i,
          'title': 'Edited title $i',
          'overview': 'd' * 1500,
        },
    ];

List<String> _docAddresses(Map<String, dynamic> doc) => [
      for (final l in doc['lists'] as List? ?? const [])
        for (final e in (l as Map)['entries'] as List? ?? const [])
          (e as Map)['address'] as String,
    ];

List<String> _docMetaKeys(Map<String, dynamic> doc) => [
      for (final r in (doc['meta'] as Map?)?['rows'] as List? ?? const [])
        (r as Map)['key'] as String,
    ];

void main() {
  group('buildDoc entryOffset', () {
    test('the window wraps around the flattened entry sequence', () {
      final lists = [
        MediaList(id: 'a', title: 'Movies', entries: [
          for (var i = 0; i < 6; i++) _fatEntry(i),
        ]),
        MediaList(id: 'b', title: 'Shows', entries: [
          for (var i = 6; i < 10; i++) _fatEntry(i),
        ]),
      ];
      final doc = MyWatchSync.buildDoc(
        lists: lists,
        tombstones: const {},
        watchStates: const [],
        nowMs: 1,
        entryCap: 4,
        entryOffset: 8,
      );
      // Global indices 8, 9 (tail of Shows) then 0, 1 (head of Movies).
      expect(_docAddresses(doc),
          [_addr(1), _addr(2), _addr(9), _addr(10)]);
    });

    test('offset 0 keeps the historic head-first selection', () {
      final lists = [
        MediaList(id: 'a', title: 'Movies', entries: [
          for (var i = 0; i < 6; i++) _fatEntry(i),
        ]),
      ];
      final doc = MyWatchSync.buildDoc(
        lists: lists,
        tombstones: const {},
        watchStates: const [],
        nowMs: 1,
        entryCap: 3,
      );
      expect(_docAddresses(doc), [_addr(1), _addr(2), _addr(3)]);
    });
  });

  group('buildDocParts', () {
    test('the Fire-Stick library that could never fit one doc now ships '
        'whole across parts, nothing dropped', () {
      // 400 fat entries (~80 KB alone) + 40 fat detail edits (~60 KB):
      // far over one doc's budget, comfortably inside three.
      final lists = [
        MediaList(id: 'a', title: 'Movies', entries: [
          for (var i = 0; i < MyWatchSync.maxDocEntries; i++) _fatEntry(i),
        ]),
      ];
      final built = MyWatchSync.buildDocParts(
        lists: lists,
        tombstones: {
          'movies': {_addr(9999): 42},
        },
        watchStates: const [],
        nowMs: 1,
        metaRows: _fatMetaRows(40),
      );
      expect(built.entriesDropped, 0);
      expect(built.metaDropped, 0);
      expect(built.parts.length, greaterThan(1));
      expect(built.parts.length, lessThanOrEqualTo(MyWatchSync.maxSyncParts));
      for (final p in built.parts) {
        expect(utf8.encode(jsonEncode(p)).length,
            lessThanOrEqualTo(MyWatchSync.maxDocBytes));
      }
      // Every entry appears exactly once across the parts.
      final all = [for (final p in built.parts) ..._docAddresses(p)];
      expect(all.length, MyWatchSync.maxDocEntries);
      expect(all.toSet().length, MyWatchSync.maxDocEntries);
      // Every detail edit made it too.
      final metaKeys = [for (final p in built.parts) ..._docMetaKeys(p)];
      expect(metaKeys.toSet().length, 40);
      // Tombstones ride only the main doc (what old builds read).
      expect(((built.parts.first['lists'] as List).first as Map)['removed'],
          isNotNull);
      for (final p in built.parts.skip(1)) {
        for (final l in p['lists'] as List) {
          expect((l as Map)['removed'], isNull);
        }
      }
    });

    test('a library that fits one doc builds exactly one part — the '
        'published shape is unchanged for small libraries', () {
      final built = MyWatchSync.buildDocParts(
        lists: [
          MediaList(id: 'a', title: 'Movies', entries: [_fatEntry(1)]),
        ],
        tombstones: const {},
        watchStates: const [],
        nowMs: 1,
      );
      expect(built.parts, hasLength(1));
      expect(built.entriesDropped, 0);
    });

    test('entry rotation: what one cycle drops leads the next — the '
        'whole library propagates in turns', () {
      // maxParts: 1 makes a small over-budget case: 400 entries where
      // only ~350 fit one doc.
      final lists = [
        MediaList(id: 'a', title: 'Movies', entries: [
          for (var i = 0; i < MyWatchSync.maxDocEntries; i++) _fatEntry(i),
        ]),
      ];
      var rot = 0;
      final seen = <String>{};
      var cycles = 0;
      while (cycles < 10) {
        cycles++;
        final built = MyWatchSync.buildDocParts(
          lists: lists,
          tombstones: const {},
          watchStates: const [],
          nowMs: 1,
          entryRotation: rot,
          maxParts: 1,
        );
        expect(utf8.encode(jsonEncode(built.parts.single)).length,
            lessThanOrEqualTo(MyWatchSync.maxDocBytes));
        seen.addAll(_docAddresses(built.parts.single));
        if (built.entriesDropped == 0) break;
        final total = built.entriesKept + built.entriesDropped;
        rot = (rot + built.entriesKept.clamp(1, total)) % total;
        if (seen.length == MyWatchSync.maxDocEntries) break;
      }
      expect(seen.length, MyWatchSync.maxDocEntries,
          reason: 'every entry must get a turn within a few cycles');
      expect(cycles, lessThanOrEqualTo(3));
    });

    test('meta rotation: starved detail edits get their turn', () {
      final metaRows = _fatMetaRows(60); // only ~35 fit one doc
      var rot = 0;
      final seen = <String>{};
      var cycles = 0;
      while (cycles < 10) {
        cycles++;
        final built = MyWatchSync.buildDocParts(
          lists: const [],
          tombstones: const {},
          watchStates: const [],
          nowMs: 1,
          metaRows: metaRows,
          metaRotation: rot,
          maxParts: 1,
        );
        seen.addAll(_docMetaKeys(built.parts.single));
        if (built.metaDropped == 0) break;
        final kept = metaRows.length - built.metaDropped;
        rot = (rot + kept.clamp(1, metaRows.length)) % metaRows.length;
        if (seen.length == metaRows.length) break;
      }
      expect(seen.length, 60,
          reason: 'every detail edit must get a turn within a few cycles');
      expect(cycles, lessThanOrEqualTo(3));
    });
  });

  group('combinedSyncDoc', () {
    test('no parts returns the doc untouched', () {
      final doc = {'v': 1, 'lists': [], 'have': []};
      expect(identical(combinedSyncDoc(doc, const []), doc), isTrue);
    });

    test('parts fold back into one union doc', () {
      final doc = {
        'v': 1,
        'updated_ms': 10,
        'lists': [
          {
            'title': 'Movies',
            'entries': [
              {'name': 'a.mp4', 'address': _addr(1), 'added_ms': 1},
            ],
            'removed': {_addr(7): 5},
          },
        ],
        'have': ['aaaa0000'],
        'watch': [
          {'address': _addr(1), 'pos_ms': 1, 'updated_ms': 1},
        ],
        'meta': {
          'v': 1,
          'rows': [
            {'key': 'movie:a:2020', 'updated_ms': 1},
          ],
        },
        'channels': {
          'subs': {
            'pk1': {'code': 'wchn1-x', 'added_ms': 1},
          },
        },
      };
      final part = {
        'v': 1,
        'updated_ms': 20,
        'lists': [
          {
            'title': 'Movies',
            'entries': [
              {'name': 'b.mp4', 'address': _addr(2), 'added_ms': 2},
            ],
            'removed': {_addr(7): 9, _addr(8): 2},
          },
          {
            'title': 'Shows',
            'kind': 'playlist',
            'entries': [
              {'name': 'c.mp4', 'address': _addr(3), 'added_ms': 3},
            ],
          },
        ],
        'have': ['aaaa0000', 'bbbb1111'],
        'watch': [
          {'address': _addr(2), 'pos_ms': 2, 'updated_ms': 2},
        ],
        'meta': {
          'v': 1,
          'rows': [
            {'key': 'movie:b:2021', 'updated_ms': 2},
          ],
        },
        'tmdb': {
          'v': 1,
          'rows': [
            {'key': 'movie:c:2022'},
          ],
          'files': {'movie_1.jpg': {'sha256': 'ab', 'size': 1}},
        },
      };
      final out = combinedSyncDoc(doc, [part]);
      final lists = out['lists'] as List;
      expect(lists, hasLength(2));
      final movies = lists.first as Map;
      expect([for (final e in movies['entries'] as List) (e as Map)['address']],
          [_addr(1), _addr(2)]);
      // Removal stones union on the newest stamp.
      expect(movies['removed'], {_addr(7): 9, _addr(8): 2});
      final shows = lists.last as Map;
      expect(shows['kind'], 'playlist');
      expect(out['have'], ['aaaa0000', 'bbbb1111']);
      expect(out['watch'], hasLength(2));
      expect((out['meta'] as Map)['rows'], hasLength(2));
      expect(((out['tmdb'] as Map)['rows'] as List), hasLength(1));
      expect(out['updated_ms'], 20);
      // Channels come from the main doc.
      expect((out['channels'] as Map)['subs'], isNotNull);
    });

    test('a malformed part is skipped without breaking the doc', () {
      final doc = {
        'v': 1,
        'lists': [
          {
            'title': 'Movies',
            'entries': [
              {'name': 'a.mp4', 'address': _addr(1), 'added_ms': 1},
            ],
          },
        ],
        'have': <dynamic>[],
        'watch': <dynamic>[],
      };
      final out = combinedSyncDoc(doc, ['garbage', 42, null, {}]);
      expect(_docAddresses(out), [_addr(1)]);
    });
  });
}
