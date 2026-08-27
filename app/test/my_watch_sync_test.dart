import 'package:flutter_test/flutter_test.dart';

import 'package:watchit/models/media_list.dart';
import 'package:watchit/services/channel_service.dart';
import 'package:watchit/services/my_watch_api.dart';
import 'package:watchit/services/my_watch_sync.dart';
import 'package:watchit/services/watch_state.dart';

String _addr(int i) => i.toRadixString(16).padLeft(64, '0');

MediaEntry _entry(int i, {int addedMs = 1000}) =>
    MediaEntry(name: 'Movie $i.mp4', address: _addr(i), addedAt: addedMs);

void main() {
  group('membershipOf', () {
    test('maps titles and addresses lowercased, 0/null add time → 1', () {
      final lists = [
        MediaList(id: 'a', title: 'Movies', entries: [
          const MediaEntry(name: 'x', address: 'ABC', addedAt: 0),
          const MediaEntry(name: 'y', address: 'def', addedAt: 42),
          const MediaEntry(name: 'z', address: 'ff'),
        ]),
      ];
      expect(MyWatchSync.membershipOf(lists), {
        'movies': {'abc': 1, 'def': 42, 'ff': 1},
      });
    });
  });

  group('updatedTombstones', () {
    test('a disappeared entry becomes a tombstone stamped now', () {
      final out = MyWatchSync.updatedTombstones(
        previous: {
          'movies': {_addr(1): 100, _addr(2): 100}
        },
        current: {
          'movies': {_addr(1): 100}
        },
        tombstones: const {},
        nowMs: 5000,
        ttlMs: 1000000,
      );
      expect(out, {
        'movies': {_addr(2): 5000}
      });
    });

    test('re-adding after the tombstone clears it', () {
      final out = MyWatchSync.updatedTombstones(
        previous: const {},
        current: {
          'movies': {_addr(1): 6000}
        },
        tombstones: {
          'movies': {_addr(1): 5000}
        },
        nowMs: 7000,
        ttlMs: 1000000,
      );
      expect(out, isEmpty);
    });

    test('a tombstone older than the ttl falls off', () {
      final out = MyWatchSync.updatedTombstones(
        previous: const {},
        current: const {},
        tombstones: {
          'movies': {_addr(1): 1000}
        },
        nowMs: 1000 + 2000000,
        ttlMs: 1000000,
      );
      expect(out, isEmpty);
    });
  });

  group('buildDoc', () {
    test('carries lists, tombstones and capped watch states', () {
      final doc = MyWatchSync.buildDoc(
        lists: [
          MediaList(id: 'a', title: 'Movies', entries: [_entry(1)]),
        ],
        tombstones: {
          'movies': {_addr(9): 500},
          'gone list': {_addr(8): 600},
        },
        watchStates: [
          for (var i = 0; i < MyWatchSync.maxDocWatchStates + 5; i++)
            WatchState(
              address: _addr(100 + i),
              positionMs: 60000,
              durationMs: 120000,
              completed: false,
              updatedAt: 1000 + i,
            ),
        ],
        nowMs: 9999,
      );
      final lists = doc['lists'] as List;
      expect(lists, hasLength(2));
      final movies = lists[0] as Map<String, dynamic>;
      expect(movies['title'], 'Movies');
      expect((movies['entries'] as List).single['address'], _addr(1));
      expect(movies['removed'], {_addr(9): 500});
      // The deleted list's stones still publish, entryless.
      final gone = lists[1] as Map<String, dynamic>;
      expect(gone['entries'], isEmpty);
      expect(gone['removed'], {_addr(8): 600});
      expect(doc['watch'] as List, hasLength(MyWatchSync.maxDocWatchStates));
    });

    test('round-trips watch states through watchStatesFromDoc', () {
      final doc = MyWatchSync.buildDoc(
        lists: const [],
        tombstones: const {},
        watchStates: [
          WatchState(
            address: _addr(1),
            positionMs: 61000,
            durationMs: 120000,
            completed: true,
            updatedAt: 777,
          ),
        ],
        nowMs: 1,
      );
      final back = MyWatchSync.watchStatesFromDoc(doc);
      expect(back.single.address, _addr(1));
      expect(back.single.positionMs, 61000);
      expect(back.single.completed, true);
      expect(back.single.updatedAt, 777);
    });
  });

  group('buildDocWithinBudget', () {
    List<WatchState> states(int n) => [
          // Newest-first, like WatchStateStore.all().
          for (var i = 0; i < n; i++)
            WatchState(
              address: _addr(1000 + i),
              positionMs: 600000,
              durationMs: 1200000,
              completed: false,
              updatedAt: 999999 - i,
            ),
        ];

    List<Map<String, dynamic>> metaRows(int n) => [
          // Newest-first, like _localMetaRows().
          for (var i = 0; i < n; i++)
            {
              'key': 'movie:title $i:2020',
              'updated_ms': 5000 - i,
              'title': 'Edited title $i',
              'overview': 'd' * 1500,
            },
        ];

    test('nothing is dropped while the doc fits', () {
      final built = MyWatchSync.buildDocWithinBudget(
        lists: [
          MediaList(id: 'a', title: 'Movies', entries: [_entry(1)]),
        ],
        tombstones: const {},
        watchStates: states(20),
        nowMs: 1,
        metaRows: metaRows(3),
      );
      expect(built.watchDropped, 0);
      expect(built.metaDropped, 0);
      expect((built.doc['watch'] as List), hasLength(20));
      expect(((built.doc['meta'] as Map)['rows'] as List), hasLength(3));
    });

    test('watch states drop before detail edits — a long viewing history '
        'must not crowd the edits out of the doc', () {
      // 300 states + 15 fat meta rows is well over the byte budget; the
      // pre-fix code dropped every meta row and kept all 300 states.
      final built = MyWatchSync.buildDocWithinBudget(
        lists: const [],
        tombstones: const {},
        watchStates: states(MyWatchSync.maxDocWatchStates),
        nowMs: 1,
        metaRows: metaRows(15),
      );
      expect(built.metaDropped, 0);
      expect(built.watchDropped, greaterThan(0));
      final rows = (built.doc['meta'] as Map)['rows'] as List;
      expect(rows, hasLength(15));
      // The trim keeps the newest states (the head of the list).
      final kept = built.doc['watch'] as List;
      expect((kept.first as Map)['address'], _addr(1000));
      expect(kept.length, lessThan(MyWatchSync.maxDocWatchStates));
    });

    test('meta rows drop oldest-first only once no watch state is left', () {
      final built = MyWatchSync.buildDocWithinBudget(
        lists: const [],
        tombstones: const {},
        watchStates: const [],
        nowMs: 1,
        metaRows: metaRows(60), // ~90 KB of descriptions alone
      );
      expect(built.watchDropped, 0);
      expect(built.metaDropped, greaterThan(0));
      final rows = (built.doc['meta'] as Map)['rows'] as List;
      // Newest-first input, dropped from the tail: the newest edits stay.
      expect((rows.first as Map)['key'], 'movie:title 0:2020');
      expect(rows, hasLength(60 - built.metaDropped));
    });
  });

  group('mergeRemoteDocs', () {
    Map<String, dynamic> docWith({
      List<Map<String, dynamic>> entries = const [],
      Map<String, int> removed = const {},
      String title = 'Movies',
    }) =>
        {
          'v': 1,
          'lists': [
            {
              'title': title,
              'entries': entries,
              if (removed.isNotEmpty) 'removed': removed,
            },
          ],
        };

    test('a remote add lands in the matching-title list', () {
      final result = MyWatchSync.mergeRemoteDocs(
        lists: [
          MediaList(id: 'a', title: 'movies', entries: [_entry(1)]),
        ],
        tombstones: const {},
        remoteDocs: [
          docWith(entries: [
            {'name': 'New.mp4', 'address': _addr(2), 'added_ms': 2000},
          ]),
        ],
      );
      expect(result.changed, true);
      expect(result.entriesAdded, 1);
      expect(result.lists.single.entries, hasLength(2));
      expect(result.lists.single.entries.last.address, _addr(2));
      expect(result.lists.single.entries.last.addedAt, 2000);
    });

    test('an unknown list title is created', () {
      final result = MyWatchSync.mergeRemoteDocs(
        lists: const [],
        tombstones: const {},
        remoteDocs: [
          docWith(title: 'Shows', entries: [
            {'name': 'S.mp4', 'address': _addr(3), 'added_ms': 10},
          ]),
        ],
      );
      expect(result.lists.single.title, 'Shows');
      expect(result.lists.single.entries.single.address, _addr(3));
    });

    test('a remote tombstone newer than the add removes and is adopted', () {
      final result = MyWatchSync.mergeRemoteDocs(
        lists: [
          MediaList(id: 'a', title: 'Movies', entries: [
            _entry(1, addedMs: 1000),
            _entry(2, addedMs: 1000),
          ]),
        ],
        tombstones: const {},
        remoteDocs: [
          docWith(removed: {_addr(2): 2000}),
        ],
      );
      expect(result.entriesRemoved, 1);
      expect(result.lists.single.entries.single.address, _addr(1));
      expect(result.tombstones['movies']![_addr(2)], 2000);
    });

    test('a local tombstone newer than the remote add blocks resurrection',
        () {
      final result = MyWatchSync.mergeRemoteDocs(
        lists: [
          MediaList(id: 'a', title: 'Movies', entries: const []),
        ],
        tombstones: {
          'movies': {_addr(1): 5000}
        },
        remoteDocs: [
          docWith(entries: [
            {'name': 'Old.mp4', 'address': _addr(1), 'added_ms': 4000},
          ]),
        ],
      );
      expect(result.changed, false);
      expect(result.lists.single.entries, isEmpty);
    });

    test('a re-add newer than the tombstone wins', () {
      final result = MyWatchSync.mergeRemoteDocs(
        lists: [
          MediaList(id: 'a', title: 'Movies', entries: const []),
        ],
        tombstones: {
          'movies': {_addr(1): 5000}
        },
        remoteDocs: [
          docWith(entries: [
            {'name': 'Back.mp4', 'address': _addr(1), 'added_ms': 6000},
          ]),
        ],
      );
      expect(result.entriesAdded, 1);
      expect(result.lists.single.entries.single.address, _addr(1));
    });

    test('a list emptied purely by remote tombstones is deleted', () {
      final result = MyWatchSync.mergeRemoteDocs(
        lists: [
          MediaList(id: 'a', title: 'Movies', entries: [
            _entry(1, addedMs: 1000),
          ]),
        ],
        tombstones: const {},
        remoteDocs: [
          docWith(removed: {_addr(1): 2000}),
        ],
      );
      expect(result.lists, isEmpty);
      expect(result.entriesRemoved, 1);
    });

    test('invalid addresses are skipped', () {
      final result = MyWatchSync.mergeRemoteDocs(
        lists: const [],
        tombstones: const {},
        remoteDocs: [
          docWith(entries: [
            {'name': 'Bad.mp4', 'address': 'nope', 'added_ms': 10},
          ]),
        ],
      );
      expect(result.changed, false);
      expect(result.lists, isEmpty);
    });

    test('two devices converge after exchanging documents', () {
      // Device A holds 1+2 and deleted 3; device B holds 3 (older than
      // A's delete) and added 4.
      final aLists = [
        MediaList(id: 'a', title: 'Movies', entries: [
          _entry(1, addedMs: 100),
          _entry(2, addedMs: 200),
        ]),
      ];
      final aStones = {
        'movies': {_addr(3): 900}
      };
      final bLists = [
        MediaList(id: 'b', title: 'Movies', entries: [
          _entry(3, addedMs: 300),
          _entry(4, addedMs: 400),
        ]),
      ];
      final aDoc = MyWatchSync.buildDoc(
        lists: aLists,
        tombstones: aStones,
        watchStates: const [],
        nowMs: 1000,
      );
      final bDoc = MyWatchSync.buildDoc(
        lists: bLists,
        tombstones: const {},
        watchStates: const [],
        nowMs: 1000,
      );
      final aMerged = MyWatchSync.mergeRemoteDocs(
        lists: aLists,
        tombstones: aStones,
        remoteDocs: [bDoc],
      );
      final bMerged = MyWatchSync.mergeRemoteDocs(
        lists: bLists,
        tombstones: const {},
        remoteDocs: [aDoc],
      );
      Set<String> addrs(List<MediaList> lists) => {
            for (final l in lists)
              for (final e in l.entries) e.address,
          };
      expect(addrs(aMerged.lists), {_addr(1), _addr(2), _addr(4)});
      expect(addrs(bMerged.lists), {_addr(1), _addr(2), _addr(4)});
      expect(bMerged.tombstones['movies']![_addr(3)], 900);
    });
  });

  group('channel lists stay out of personal sync', () {
    MediaList channelList({String title = 'Nature Films'}) => MediaList(
          id: 'channel-x',
          title: title,
          entries: [_entry(9, addedMs: 500)],
          channelPubkey: 'ab' * 32,
        );

    test('membershipOf and libraryLookupKeys skip channel lists', () {
      final lists = [
        MediaList(id: 'a', title: 'Movies', entries: [_entry(1)]),
        channelList(),
      ];
      expect(MyWatchSync.membershipOf(lists).keys, ['movies']);
      expect(MyWatchSync.libraryLookupKeys(lists),
          MyWatchSync.libraryLookupKeys(lists.sublist(0, 1)));
    });

    test('buildDoc omits channel lists and carries the channels section',
        () {
      final doc = MyWatchSync.buildDoc(
        lists: [
          MediaList(id: 'a', title: 'Movies', entries: [_entry(1)]),
          channelList(),
        ],
        tombstones: const {},
        watchStates: const [],
        nowMs: 1000,
        channelSubs: {
          'cd' * 32: const ChannelSyncSub(code: 'wchn1-abc', addedMs: 42),
        },
        channelStones: {'ee' * 32: 77},
      );
      expect([for (final l in doc['lists'] as List) l['title']], ['Movies']);
      expect(doc['channels'], {
        'subs': {
          'cd' * 32: {'code': 'wchn1-abc', 'added_ms': 42},
        },
        'removed': {'ee' * 32: 77},
      });
    });

    test('buildDoc has no channels section when there is nothing to say',
        () {
      final doc = MyWatchSync.buildDoc(
        lists: const [],
        tombstones: const {},
        watchStates: const [],
        nowMs: 1000,
      );
      expect(doc.containsKey('channels'), isFalse);
    });

    test('remote personal lists never merge into a channel list', () {
      final result = MyWatchSync.mergeRemoteDocs(
        lists: [channelList()],
        tombstones: const {},
        remoteDocs: [
          {
            'lists': [
              {
                'title': 'Nature Films',
                'entries': [
                  {'name': 'Old.mp4', 'address': _addr(7), 'added_ms': 10},
                ],
              },
            ],
          },
        ],
      );
      expect(result.changed, isFalse);
      expect(result.lists.single.entries.single.address, _addr(9));
    });

    test('tombstones never strip a channel list', () {
      final result = MyWatchSync.mergeRemoteDocs(
        lists: [channelList()],
        tombstones: const {},
        remoteDocs: [
          {
            'lists': [
              {
                'title': 'Nature Films',
                'entries': const [],
                'removed': {_addr(9): 999999},
              },
            ],
          },
        ],
      );
      expect(result.lists.single.entries.single.address, _addr(9));
      // The stone itself is still adopted (it cleans up badge-less
      // copies of the old sync format on other devices).
      expect(result.tombstones['nature films']![_addr(9)], 999999);
    });
  });

  group('channelActions', () {
    RemoteSyncDoc docWith({
      Map<String, dynamic> subs = const {},
      Map<String, dynamic> removed = const {},
    }) =>
        RemoteSyncDoc(agentId: 'peer', doc: {
          'channels': {'subs': subs, 'removed': removed},
        }, maps: const {});

    final pk = 'cd' * 32;

    test('a remote subscription this device lacks is subscribed', () {
      final actions = MyWatchSync.channelActions(
        localSubs: const {},
        localStones: const {},
        ownPubkey: null,
        remote: [
          docWith(subs: {
            pk: {'code': 'wchn1-abc', 'added_ms': 42},
          }),
        ],
      );
      expect(actions.subscribe.single.pubkey, pk);
      expect(actions.subscribe.single.code, 'wchn1-abc');
      expect(actions.subscribe.single.addedMs, 42);
      expect(actions.unsubscribe, isEmpty);
    });

    test('own channel and existing subscriptions are not re-subscribed',
        () {
      final actions = MyWatchSync.channelActions(
        localSubs: {
          'ee' * 32: const ChannelSyncSub(code: 'wchn1-e', addedMs: 1),
        },
        localStones: const {},
        ownPubkey: pk,
        remote: [
          docWith(subs: {
            pk: {'code': 'wchn1-own', 'added_ms': 42},
            'ee' * 32: {'code': 'wchn1-e', 'added_ms': 42},
          }),
        ],
      );
      expect(actions.subscribe, isEmpty);
      expect(actions.unsubscribe, isEmpty);
    });

    test('a tombstone at or after the newest add wins', () {
      final actions = MyWatchSync.channelActions(
        localSubs: const {},
        localStones: const {},
        ownPubkey: null,
        remote: [
          docWith(subs: {
            pk: {'code': 'wchn1-abc', 'added_ms': 42},
          }, removed: {
            pk: 42,
          }),
        ],
      );
      expect(actions.subscribe, isEmpty);
      expect(actions.stones, {pk: 42});
    });

    test('a newer tombstone unsubscribes, carrying the stone time', () {
      final actions = MyWatchSync.channelActions(
        localSubs: {
          pk: const ChannelSyncSub(code: 'wchn1-abc', addedMs: 40),
        },
        localStones: const {},
        ownPubkey: null,
        remote: [
          docWith(removed: {pk: 50}),
        ],
      );
      expect(actions.unsubscribe, {pk: 50});
    });

    test('a re-subscribe newer than the tombstone stands', () {
      final actions = MyWatchSync.channelActions(
        localSubs: {
          pk: const ChannelSyncSub(code: 'wchn1-abc', addedMs: 60),
        },
        localStones: {pk: 50},
        ownPubkey: null,
        remote: [docWith()],
      );
      expect(actions.unsubscribe, isEmpty);
    });

    test('only stones newer than local ones are adopted', () {
      final actions = MyWatchSync.channelActions(
        localSubs: const {},
        localStones: {pk: 100},
        ownPubkey: null,
        remote: [
          docWith(removed: {pk: 90, 'ee' * 32: 10}),
        ],
      );
      expect(actions.stones, {'ee' * 32: 10});
    });

    test('bad pubkeys and codes are ignored', () {
      final actions = MyWatchSync.channelActions(
        localSubs: const {},
        localStones: const {},
        ownPubkey: null,
        remote: [
          docWith(subs: {
            'not-hex': {'code': 'wchn1-abc', 'added_ms': 42},
            pk: {'code': 'https://evil', 'added_ms': 42},
            'ff' * 32: {'code': 'wchn1-abc', 'added_ms': 0},
          }, removed: {
            'nope': 42,
          }),
        ],
      );
      expect(actions.subscribe, isEmpty);
      expect(actions.stones, isEmpty);
    });
  });
}
