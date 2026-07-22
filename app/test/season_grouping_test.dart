import 'package:flutter_test/flutter_test.dart';

import 'package:watchit/models/media_list.dart';
import 'package:watchit/services/season_grouping.dart';

const _addr =
    'a3f1c9e07b6d5a4f2e8c1b0d9f7a6e5c4b3a2d1e0f9c8b7a6d5e4f3c2b1a0d9e';

MediaEntry _e(String name) => MediaEntry(name: name, address: _addr);

void main() {
  group('groupSeasons', () {
    test('episodes of one show+season fold into a single group', () {
      final items = groupSeasons([
        _e('Show.S01E01.mkv'),
        _e('Show.S01E02.mkv'),
        _e('Show.S01E03.mkv'),
      ]);
      final season = items.single as HomeSeason;
      expect(season.show, 'Show');
      expect(season.season, 1);
      expect(season.episodes.map((e) => e.name),
          ['Show.S01E01.mkv', 'Show.S01E02.mkv', 'Show.S01E03.mkv']);
    });

    test('episodes sort by number regardless of list order', () {
      final items = groupSeasons([
        _e('Show.S01E03.mkv'),
        _e('Show.S01E01.mkv'),
        _e('Show 1x02.mkv'), // 1x02 marker groups with SxxEyy names
      ]);
      final season = items.single as HomeSeason;
      expect(season.episodes.map((e) => e.name),
          ['Show.S01E01.mkv', 'Show 1x02.mkv', 'Show.S01E03.mkv']);
    });

    test('different seasons and shows stay separate groups', () {
      final items = groupSeasons([
        _e('Show.S01E01.mkv'),
        _e('Show.S02E01.mkv'),
        _e('Other Show S01E01.mkv'),
      ]);
      expect(items, hasLength(3));
      expect(items.whereType<HomeSeason>().map((s) => '${s.show} ${s.season}'),
          ['Show 1', 'Show 2', 'Other Show 1']);
    });

    test('movies stay single cards, in place around groups', () {
      final items = groupSeasons([
        _e('First Movie (2020).mkv'),
        _e('Show.S01E02.mkv'),
        _e('Second Movie (2021).mkv'),
        _e('Show.S01E01.mkv'),
      ]);
      expect(items, hasLength(3));
      expect((items[0] as HomeEntry).entry.name, 'First Movie (2020).mkv');
      // The group sits where its first episode appeared.
      final season = items[1] as HomeSeason;
      expect(season.episodes.map((e) => e.name),
          ['Show.S01E01.mkv', 'Show.S01E02.mkv']);
      expect((items[2] as HomeEntry).entry.name, 'Second Movie (2021).mkv');
    });

    test('a lone episode still forms a season group', () {
      final items = groupSeasons([_e('Show.S03E07.mkv')]);
      final season = items.single as HomeSeason;
      expect(season.season, 3);
      expect(season.episodes, hasLength(1));
    });

    test('resolutions like 1920x1080 do not group as episodes', () {
      final items = groupSeasons([_e('The.Movie.2024.1920x1080.mkv')]);
      expect(items.single, isA<HomeEntry>());
    });
  });

  group('showSeasons', () {
    test('collects one show\'s seasons sorted by number', () {
      final entries = [
        _e('Show.S02E01.mkv'),
        _e('A Movie (2020).mkv'),
        _e('Show.S01E01.mkv'),
        _e('Other Show S01E01.mkv'),
        _e('Show.S01E02.mkv'),
      ];
      final seasons = showSeasons(entries, 'Show');
      expect(seasons.map((s) => s.season), [1, 2]);
      expect(seasons.first.episodes, hasLength(2));
    });

    test('matches the show name case-insensitively', () {
      expect(showSeasons([_e('Show.S01E01.mkv')], 'SHOW'), hasLength(1));
    });

    test('unknown show yields no seasons', () {
      expect(showSeasons([_e('Show.S01E01.mkv')], 'Other'), isEmpty);
    });
  });

  group('episodeNameFromLabel', () {
    test('extracts the TMDB episode name', () {
      expect(episodeNameFromLabel('S01E02 · The Second One'),
          'The Second One');
      expect(episodeNameFromLabel('S01E02'), isNull);
      expect(episodeNameFromLabel(null), isNull);
      expect(episodeNameFromLabel('S01E02 · '), isNull);
    });
  });
}
