import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/storage_usage.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('wi-storage-test');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<void> seed() async {
    await File('${dir.path}/watchit.sqlite').writeAsBytes(List.filled(100, 1));
    final posters = Directory('${dir.path}/posters')..createSync();
    await File('${posters.path}/a.jpg').writeAsBytes(List.filled(50, 2));
    await File('${posters.path}/b.jpg').writeAsBytes(List.filled(25, 3));
  }

  test('directorySizeBytes sums files recursively', () async {
    await seed();
    expect(await directorySizeBytes(dir), 175);
  });

  test('appDataSizeBytes with an explicit dir', () async {
    await seed();
    expect(await appDataSizeBytes(dir: dir), 175);
    expect(await appDataSizeBytes(dir: Directory('${dir.path}/nope')),
        isNull);
  });

  test('wipeDirectory empties the directory but keeps it', () async {
    await seed();
    await wipeDirectory(dir);
    expect(await dir.exists(), isTrue);
    expect(await dir.list().toList(), isEmpty);
  });

  test('factoryReset clears preferences and wipes the data dir', () async {
    SharedPreferences.setMockInitialValues({'some_setting': 'kept?'});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    await seed();
    await factoryReset(dir: dir);
    expect(await dir.list().toList(), isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), isEmpty);
  });

  test('formatBytes picks sensible units', () {
    expect(formatBytes(0), '0 B');
    expect(formatBytes(900), '900 B');
    expect(formatBytes(8 * 1024), '8 KB');
    expect(formatBytes(64 * 1024 * 1024 + 200 * 1024), '64.2 MB');
    expect(formatBytes(150 * 1024 * 1024), '150 MB');
    expect(formatBytes((1.38 * 1024 * 1024 * 1024).round()), '1.38 GB');
  });
}
