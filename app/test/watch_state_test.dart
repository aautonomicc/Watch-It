import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/watch_state.dart';

const _addr =
    'a3f1c9e07b6d5a4f2e8c1b0d9f7a6e5c4b3a2d1e0f9c8b7a6d5e4f3c2b1a0d9e';

const _entry = MediaEntry(name: 'Movie.2020.mkv', address: _addr);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late WatchStateStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    store = WatchStateStore.instance = WatchStateStore();
  });

  test('record round-trips a resume point', () async {
    await store.record(_entry,
        position: const Duration(minutes: 10),
        duration: const Duration(minutes: 100));
    final state = await store.stateFor(_entry);
    expect(state, isNotNull);
    expect(state!.positionMs, const Duration(minutes: 10).inMilliseconds);
    expect(state.durationMs, const Duration(minutes: 100).inMilliseconds);
    expect(state.completed, isFalse);
    expect(state.resumable, isTrue);
    expect(state.progress, closeTo(0.1, 0.001));
    expect(state.remainingLabel, '1 h 30 min left');
  });

  test('address lookup normalizes case and 0x prefix', () async {
    await store.record(_entry,
        position: const Duration(minutes: 10),
        duration: const Duration(minutes: 100));
    final upper = MediaEntry(
        name: 'Movie.2020.mkv', address: '0x${_addr.toUpperCase()}');
    expect(await store.stateFor(upper), isNotNull);
  });

  test('under a minute of progress is not resumable', () async {
    await store.record(_entry,
        position: const Duration(seconds: 45),
        duration: const Duration(minutes: 100));
    final state = await store.stateFor(_entry);
    expect(state!.resumable, isFalse);
    expect(state.completed, isFalse);
  });

  test('the last 5% of a file counts as watched', () async {
    await store.record(_entry,
        position: const Duration(minutes: 97),
        duration: const Duration(minutes: 100));
    final state = await store.stateFor(_entry);
    expect(state!.completed, isTrue);
    expect(state.resumable, isFalse);
  });

  test('rewatching from earlier clears the watched flag', () async {
    await store.markCompleted(_entry, duration: const Duration(minutes: 100));
    await store.record(_entry,
        position: const Duration(minutes: 5),
        duration: const Duration(minutes: 100));
    final state = await store.stateFor(_entry);
    expect(state!.completed, isFalse);
    expect(state.resumable, isTrue);
  });

  test('markCompleted works without a known duration', () async {
    await store.markCompleted(_entry);
    final state = await store.stateFor(_entry);
    expect(state!.completed, isTrue);
    expect(state.resumable, isFalse);
  });

  test('all() returns most recently updated first', () async {
    final other = MediaEntry(
        name: 'Other.2021.mkv', address: 'b' * 64);
    await store.record(_entry,
        position: const Duration(minutes: 10),
        duration: const Duration(minutes: 100));
    // updatedAt has millisecond resolution — make sure the clock moves.
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await store.record(other,
        position: const Duration(minutes: 20),
        duration: const Duration(minutes: 100));
    final all = await store.all();
    expect(all.map((s) => s.address).toList(), ['b' * 64, _addr]);
  });

  test('record notifies listeners', () async {
    var notified = 0;
    store.addListener(() => notified++);
    await store.record(_entry,
        position: const Duration(minutes: 10),
        duration: const Duration(minutes: 100));
    expect(notified, 1);
  });

  test('positionLabel formats with and without hours', () {
    expect(positionLabel(const Duration(minutes: 43, seconds: 12)
        .inMilliseconds), '43:12');
    expect(
        positionLabel(const Duration(hours: 1, minutes: 3, seconds: 5)
            .inMilliseconds),
        '1:03:05');
    expect(positionLabel(9000), '0:09');
  });
}
