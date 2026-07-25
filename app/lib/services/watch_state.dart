import 'package:drift/drift.dart' hide Column;
import 'package:flutter/foundation.dart';

import '../db/app_database.dart';
import '../models/media_list.dart';
import 'library_store.dart';

/// Playback progress for one file, keyed by its (normalized) XOR address.
class WatchState {
  const WatchState({
    required this.address,
    required this.positionMs,
    required this.durationMs,
    required this.completed,
    required this.updatedAt,
  });

  final String address;
  final int positionMs;

  /// 0 while the player never reported a duration.
  final int durationMs;

  /// Played to (near) the end.
  final bool completed;
  final int updatedAt; // epoch ms

  /// 0..1 through the file; 0 when the duration is unknown.
  double get progress =>
      durationMs > 0 ? (positionMs / durationMs).clamp(0.0, 1.0) : 0;

  /// Worth resuming: some real progress made and not (re)finished.
  bool get resumable => !completed && positionMs >= WatchStateStore.minResumeMs;

  /// `42 min left` / `1 h 10 min left`; null when the duration is unknown.
  String? get remainingLabel {
    if (durationMs <= 0) return null;
    final mins = ((durationMs - positionMs) / 60000).ceil();
    if (mins >= 60) return '${mins ~/ 60} h ${mins % 60} min left';
    return '$mins min left';
  }
}

/// Persists resume points in SQLite (watch_states table) and notifies the
/// home screen / detail pages when one changes. Local-only by design —
/// no accounts, no telemetry (docs/ARCHITECTURE.md).
class WatchStateStore extends ChangeNotifier {
  /// Replaceable for tests (fresh instance per test).
  static WatchStateStore instance = WatchStateStore();

  /// Progress below this is noise (a tapped-then-closed player), not a
  /// resume point.
  static const minResumeMs = 60 * 1000;

  /// address → state mirror of the table for sync lookups from card
  /// builders; null until [cachedStateFor] triggers the first load.
  Map<String, WatchState>? _memory;
  bool _loadingMemory = false;

  /// Position at/after this fraction of the duration counts as watched.
  static const completedFraction = 0.95;

  static String _normalize(String address) =>
      address.toLowerCase().replaceFirst('0x', '');

  /// Record playback progress for [entry]. Positions in the last 5% of a
  /// known duration mark the file completed; watching again from earlier
  /// clears the flag (a rewatch resumes like anything else).
  Future<void> record(MediaEntry entry,
      {required Duration position, required Duration duration}) async {
    final db = await LibraryStore.database();
    final completed = duration > Duration.zero &&
        position.inMilliseconds >=
            duration.inMilliseconds * completedFraction;
    final state = WatchState(
      address: _normalize(entry.address),
      positionMs: position.inMilliseconds,
      durationMs: duration.inMilliseconds,
      completed: completed,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await db.into(db.watchStates).insertOnConflictUpdate(
          WatchStatesCompanion.insert(
            address: state.address,
            positionMs: state.positionMs,
            durationMs: state.durationMs,
            completed: Value(state.completed),
            updatedAt: state.updatedAt,
          ),
        );
    _memory?[state.address] = state;
    notifyListeners();
  }

  /// Mark [entry] fully watched (playback reached the end). Works even
  /// when the player never learned the duration.
  Future<void> markCompleted(MediaEntry entry, {Duration? duration}) async {
    final d = duration ?? Duration.zero;
    if (d > Duration.zero) {
      await record(entry, position: d, duration: d);
      return;
    }
    final db = await LibraryStore.database();
    final state = WatchState(
      address: _normalize(entry.address),
      positionMs: 0,
      durationMs: 0,
      completed: true,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await db.into(db.watchStates).insertOnConflictUpdate(
          WatchStatesCompanion.insert(
            address: state.address,
            positionMs: state.positionMs,
            durationMs: state.durationMs,
            completed: Value(state.completed),
            updatedAt: state.updatedAt,
          ),
        );
    _memory?[state.address] = state;
    notifyListeners();
  }

  /// Merge externally sourced states (a bundle's history.json):
  /// newer-updatedAt-wins per address, so an import never regresses local
  /// progress. Returns how many rows were written.
  Future<int> mergeAll(Iterable<WatchState> states) async {
    final db = await LibraryStore.database();
    var written = 0;
    for (final state in states) {
      final address = _normalize(state.address);
      final existing = await (db.select(db.watchStates)
            ..where((t) => t.address.equals(address)))
          .getSingleOrNull();
      if (existing != null && existing.updatedAt >= state.updatedAt) {
        continue;
      }
      await db.into(db.watchStates).insertOnConflictUpdate(
            WatchStatesCompanion.insert(
              address: address,
              positionMs: state.positionMs,
              durationMs: state.durationMs,
              completed: Value(state.completed),
              updatedAt: state.updatedAt,
            ),
          );
      written++;
    }
    if (written > 0) {
      // Imports are rare — drop the mirror and let the next lookup
      // rebuild it rather than replaying the merge logic here.
      _memory = null;
      notifyListeners();
    }
    return written;
  }

  /// Sync lookup for card builders: the state for [entry], or null when
  /// never played — or while the mirror is still loading its first
  /// snapshot (listeners are notified once it lands).
  WatchState? cachedStateFor(MediaEntry entry) {
    final memory = _memory;
    if (memory == null) {
      _warmMemory();
      return null;
    }
    return memory[_normalize(entry.address)];
  }

  void _warmMemory() {
    if (_loadingMemory) return;
    _loadingMemory = true;
    all().then((states) {
      _memory = {for (final s in states) s.address: s};
      _loadingMemory = false;
      notifyListeners();
    });
  }

  /// The stored state for [entry]'s address, or null when never played.
  Future<WatchState?> stateFor(MediaEntry entry) async {
    final db = await LibraryStore.database();
    final row = await (db.select(db.watchStates)
          ..where((t) => t.address.equals(_normalize(entry.address))))
        .getSingleOrNull();
    return row == null ? null : _fromRow(row);
  }

  /// All stored states, most recently updated first.
  Future<List<WatchState>> all() async {
    final db = await LibraryStore.database();
    final rows = await (db.select(db.watchStates)
          ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
        .get();
    return [for (final row in rows) _fromRow(row)];
  }

  static WatchState _fromRow(WatchStateRow row) => WatchState(
        address: row.address,
        positionMs: row.positionMs,
        durationMs: row.durationMs,
        completed: row.completed,
        updatedAt: row.updatedAt,
      );
}

/// `43:12` / `1:03:12` — a resume position for the Resume button.
String positionLabel(int ms) {
  final total = ms ~/ 1000;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = (total % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}
