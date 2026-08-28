import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/models/media_list.dart';
import 'package:watchit/services/app_settings.dart';
import 'package:watchit/services/home_sections.dart';

MediaList _list(String id, {bool enabled = true}) =>
    MediaList(id: id, title: id, enabled: enabled);

List<String> _ids(List<HomeSection> sections) =>
    [for (final s in sections) s.id];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('reconcileHomeSections', () {
    test('nothing stored yields the default order', () {
      final out = reconcileHomeSections(
          const [], [_list('a'), _list('b')]);
      expect(_ids(out), [
        'continue',
        'favourites',
        'downloads',
        'recent',
        'list:a',
        'list:b',
      ]);
      expect(out.every((s) => s.visible), isTrue);
    });

    test('stored order wins, specials and lists interleaved', () {
      final out = reconcileHomeSections(
        const [
          HomeSection(id: 'list:b'),
          HomeSection(id: 'recent', visible: false),
          HomeSection(id: 'continue'),
          HomeSection(id: 'downloads'),
          HomeSection(id: 'list:a'),
        ],
        [_list('a'), _list('b')],
      );
      // Missing specials (favourites here) append after the stored order.
      expect(_ids(out),
          ['list:b', 'recent', 'continue', 'downloads', 'list:a', 'favourites']);
      expect(out[1].visible, isFalse);
    });

    test('new list is appended, deleted list is dropped', () {
      final out = reconcileHomeSections(
        const [
          HomeSection(id: 'continue'),
          HomeSection(id: 'list:gone'),
          HomeSection(id: 'downloads'),
          HomeSection(id: 'recent'),
        ],
        [_list('fresh')],
      );
      expect(_ids(out),
          ['continue', 'downloads', 'recent', 'favourites', 'list:fresh']);
    });

    test('missing special rows are appended visible', () {
      final out = reconcileHomeSections(
        const [HomeSection(id: 'recent', visible: false)],
        [_list('a')],
      );
      expect(_ids(out),
          ['recent', 'continue', 'favourites', 'downloads', 'list:a']);
      expect(out.first.visible, isFalse);
      expect(out[1].visible, isTrue);
    });

    test('list visibility mirrors MediaList.enabled, not the stored flag',
        () {
      final out = reconcileHomeSections(
        const [
          HomeSection(id: 'continue'),
          HomeSection(id: 'favourites'),
          HomeSection(id: 'downloads'),
          HomeSection(id: 'recent'),
          HomeSection(id: 'list:a', visible: true),
        ],
        [_list('a', enabled: false)],
      );
      expect(out.last.visible, isFalse);
    });

    test('a channel list the order does not know goes to the top', () {
      final out = reconcileHomeSections(
        const [
          HomeSection(id: 'continue'),
          HomeSection(id: 'favourites'),
          HomeSection(id: 'downloads'),
          HomeSection(id: 'recent'),
          HomeSection(id: 'list:a'),
        ],
        [
          _list('a'),
          _list('fresh'),
          MediaList(id: 'ch', title: 'ch', channelPubkey: 'aa' * 32),
        ],
      );
      // Fresh channel first; a fresh plain list still appends at the end.
      expect(_ids(out), [
        'list:ch',
        'continue',
        'favourites',
        'downloads',
        'recent',
        'list:a',
        'list:fresh',
      ]);
    });

    test('a channel already in the stored order stays where it was put', () {
      final out = reconcileHomeSections(
        const [
          HomeSection(id: 'continue'),
          HomeSection(id: 'list:ch'),
          HomeSection(id: 'recent'),
        ],
        [
          _list('a'),
          MediaList(id: 'ch', title: 'ch', channelPubkey: 'aa' * 32),
        ],
      );
      expect(_ids(out), [
        'continue',
        'list:ch',
        'recent',
        'favourites',
        'downloads',
        'list:a',
      ]);
    });

    test('duplicate stored ids collapse to the first occurrence', () {
      final out = reconcileHomeSections(
        const [
          HomeSection(id: 'recent', visible: false),
          HomeSection(id: 'recent'),
          HomeSection(id: 'continue'),
          HomeSection(id: 'downloads'),
        ],
        const [],
      );
      expect(_ids(out), ['recent', 'continue', 'downloads', 'favourites']);
      expect(out.first.visible, isFalse);
    });
  });

  group('codec', () {
    test('encode/decode round-trip', () {
      const sections = [
        HomeSection(id: 'downloads', visible: false),
        HomeSection(id: 'list:x'),
      ];
      final out = decodeHomeSections(encodeHomeSections(sections));
      expect(_ids(out), ['downloads', 'list:x']);
      expect(out.first.visible, isFalse);
      expect(out.last.visible, isTrue);
    });

    test('garbage decodes to empty (defaults)', () {
      expect(decodeHomeSections(''), isEmpty);
      expect(decodeHomeSections('not json'), isEmpty);
      expect(decodeHomeSections('{"id":"x"}'), isEmpty);
      expect(decodeHomeSections('[42, {"visible":true}]'), isEmpty);
    });
  });

  group('AppSettings.homeSections', () {
    test('round-trips through shared_preferences', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await AppSettings.homeSections(), isEmpty);
      const sections = [
        HomeSection(id: 'recent', visible: false),
        HomeSection(id: 'continue'),
        HomeSection(id: 'downloads'),
      ];
      await AppSettings.setHomeSections(sections);
      final out = await AppSettings.homeSections();
      expect(_ids(out), ['recent', 'continue', 'downloads']);
      expect(out.first.visible, isFalse);
    });
  });

  group('HomeSection', () {
    test('ids classify and title correctly', () {
      const cont = HomeSection(id: 'continue');
      expect(cont.isSpecial, isTrue);
      expect(cont.listId, isNull);
      expect(cont.title, 'Continue Watching');
      const favs = HomeSection(id: 'favourites');
      expect(favs.isSpecial, isTrue);
      expect(favs.title, 'Favourites');
      final listRow = HomeSection(id: listSectionId('abc'));
      expect(listRow.isSpecial, isFalse);
      expect(listRow.listId, 'abc');
    });
  });
}
