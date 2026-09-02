import 'package:flutter_test/flutter_test.dart';

import 'package:watchit/models/media_list.dart';
import 'package:watchit/services/library_search.dart';

String _addr(int i) => i.toRadixString(16).padLeft(64, '0');

MediaEntry _e(String name, int i) => MediaEntry(name: name, address: _addr(i));

MediaList _list(List<MediaEntry> entries,
        {String id = 'l1', bool enabled = true}) =>
    MediaList(id: id, title: 'List', entries: entries, enabled: enabled);

void main() {
  group('normalizeSearchText', () {
    test('lowercases, folds diacritics, strips punctuation', () {
      expect(normalizeSearchText('Amélie'), 'amelie');
      expect(normalizeSearchText('The.Dark-Knight!'), 'the dark knight');
      expect(normalizeSearchText('  Über  Straße  '), 'uber strasse');
      expect(normalizeSearchText('...'), '');
    });
  });

  group('SearchIndex', () {
    SearchIndex index() => SearchIndex.build([
          _list([
            _e('The Dark Knight (2008).mkv', 1),
            _e('Dark S01E01.mkv', 2),
            _e('Dark S01E02.mkv', 3),
            _e('Dark S02E01.mkv', 4),
            _e('Alien (1979).mkv', 5),
            _e('Alien Covenant (2017).mkv', 6),
          ]),
        ]);

    test('classifies shows, movies, and episodes', () {
      final results = index().query('dark');
      final show = results.whereType<ShowResult>().single;
      expect(show.show.seasons, hasLength(2));
      expect(show.show.episodeCount, 3);
      final entries = results.whereType<EntryResult>();
      expect(entries.where((r) => !r.isEpisode).single.entry.name,
          'The Dark Knight (2008).mkv');
      expect(entries.where((r) => r.isEpisode), hasLength(3));
    });

    test('every token must match, in any order', () {
      final i = index();
      expect(i.query('dark kni'), hasLength(1));
      expect(i.query('knight dark'), hasLength(1));
      expect(i.query('dark zzz'), isEmpty);
    });

    test('ranks title-prefix over word-start over substring', () {
      final i = SearchIndex.build([
        _list([
          _e('Knightfall (2017).mkv', 1),
          _e('The Long Night (2020).mkv', 2),
          _e('Night Train (2009).mkv', 3),
        ]),
      ]);
      final names = [
        for (final r in i.query('night')) (r as EntryResult).entry.name,
      ];
      expect(names, [
        'Night Train (2009).mkv', // title starts with the query
        'The Long Night (2020).mkv', // word-start match
        'Knightfall (2017).mkv', // substring only
      ]);
    });

    test('year tokens match the parsed year', () {
      final results = index().query('alien 1979');
      expect((results.single as EntryResult).entry.name, 'Alien (1979).mkv');
    });

    test('episode marker tokens match season/episode', () {
      final i = index();
      expect((i.query('s01e02').single as EntryResult).entry.name,
          'Dark S01E02.mkv');
      expect((i.query('1x02').single as EntryResult).entry.name,
          'Dark S01E02.mkv');
      // Season-only marker: both S01 episodes, no S02, no show/movie.
      final s1 = i.query('s01');
      expect(s1, hasLength(2));
      expect([for (final r in s1) (r as EntryResult).entry.name],
          ['Dark S01E01.mkv', 'Dark S01E02.mkv']);
    });

    test('episodes of one show sort by season and episode', () {
      final episodes = [
        for (final r in index().query('dark'))
          if (r is EntryResult && r.isEpisode) r.entry.name,
      ];
      expect(episodes,
          ['Dark S01E01.mkv', 'Dark S01E02.mkv', 'Dark S02E01.mkv']);
    });

    test('matches cached episode names when supplied', () {
      final i = SearchIndex.build(
        [
          _list([_e('Thrones S01E01.mkv', 1), _e('Thrones S01E02.mkv', 2)]),
        ],
        episodeName: (e) =>
            e.name.contains('S01E01') ? 'Winter Is Coming' : null,
      );
      final results = i.query('winter');
      expect((results.single as EntryResult).entry.name, 'Thrones S01E01.mkv');
    });

    test('skips disabled lists', () {
      final i = SearchIndex.build([
        _list([_e('Shown Movie (2000).mkv', 1)]),
        _list([_e('Hidden Gem (1999).mkv', 2)], id: 'l2', enabled: false),
      ]);
      expect(i.query('hidden'), isEmpty);
      expect(i.query('shown'), hasLength(1));
    });

    test('drops duplicate addresses across lists', () {
      final i = SearchIndex.build([
        _list([_e('Twice Listed (2001).mkv', 7)]),
        _list([_e('Twice Listed (2001).mkv', 7)], id: 'l2'),
      ]);
      expect(i.query('twice'), hasLength(1));
    });

    test('empty and whitespace queries return nothing', () {
      expect(index().query(''), isEmpty);
      expect(index().query('   '), isEmpty);
      expect(index().query('!?'), isEmpty);
    });

    test('artist-folded albums keep every track searchable', () {
      // Two albums by one artist fold into a HomeArtist on the wall —
      // the index must still reach each album's tracks.
      final i = SearchIndex.build([
        _list([
          _e('Solo Star - First Album (1990) - 01 Opening Song.mp3', 21),
          _e('Solo Star - Second Album (1992) - 01 Comeback.mp3', 22),
        ]),
      ]);
      expect(i.query('solo star'), hasLength(2));
      expect((i.query('comeback').single as EntryResult).entry.name,
          'Solo Star - Second Album (1992) - 01 Comeback.mp3');
      expect(i.query('first album'), hasLength(1));
    });

    test("a compilation track's own artist is searchable", () {
      const mbid = 'c07f0676-9d95-4443-a841-b1cbcfa48f4e';
      final i = SearchIndex.build([
        _list([
          _e('Singer A - Duets (2001) - 01 First {mbid-$mbid}.mp3', 31),
          _e('Singer B - Duets (2001) - 02 Second {mbid-$mbid}.mp3', 32),
        ]),
      ]);
      // The album credit reads Various Artists; the per-track credit
      // still finds its track.
      expect((i.query('singer b').single as EntryResult).entry.name,
          contains('02 Second'));
      expect(i.query('various artists'), hasLength(2));
    });
  });
}
