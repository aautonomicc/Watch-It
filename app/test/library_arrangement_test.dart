import 'package:flutter_test/flutter_test.dart';

import 'package:watchit/models/media_list.dart';
import 'package:watchit/services/home_sections.dart';
import 'package:watchit/services/library_arrangement.dart';

String _addr(int i) => i.toRadixString(16).padLeft(64, '0');

void main() {
  test('browsableLists keeps only enabled lists', () {
    final lists = [
      MediaList(id: 'l1', title: 'One', entries: [
        MediaEntry(name: 'Alpha.2020.mkv', address: _addr(1)),
      ]),
      MediaList(id: 'l2', title: 'Off', enabled: false),
    ];
    expect(browsableLists(lists).map((l) => l.id), ['l1']);
  });

  test('browsableLists follows the stored home-screen order', () {
    final lists = [
      MediaList(id: 'l1', title: 'One'),
      MediaList(id: 'l2', title: 'Two'),
      MediaList(id: 'l3', title: 'Off', enabled: false),
    ];
    const stored = [
      HomeSection(id: 'list:l2'),
      HomeSection(id: 'continue'),
      HomeSection(id: 'list:l3'),
      HomeSection(id: 'list:l1'),
    ];
    expect(browsableLists(lists, stored).map((l) => l.id), ['l2', 'l1']);
  });

  test('browsableLists puts channels missing from the order first', () {
    final lists = [
      MediaList(id: 'l1', title: 'One'),
      MediaList(id: 'ch', title: 'Chan', channelPubkey: 'aa' * 32),
    ];
    const stored = [HomeSection(id: 'list:l1')];
    expect(browsableLists(lists, stored).map((l) => l.id), ['ch', 'l1']);
  });

  test('genreNames splits the category string', () {
    expect(genreNames('Horror · Thriller'), ['Horror', 'Thriller']);
    expect(genreNames('Comedy'), ['Comedy']);
    expect(genreNames(null), isEmpty);
    expect(genreNames('  '), isEmpty);
  });
}
