import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';

part 'app_database.g.dart';

/// A user-held media list (see docs/ARCHITECTURE.md). Ordering on the
/// home screen follows [position].
@DataClassName('MediaListRow')
class MediaLists extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  IntColumn get position => integer()();

  /// Disabled lists are hidden from the home screen but kept intact.
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {id};
}

/// One `{XOR address, file name}` entry inside a list. Ordering within
/// the list follows [position].
@DataClassName('MediaEntryRow')
class MediaEntries extends Table {
  IntColumn get entryId => integer().autoIncrement()();
  TextColumn get listId =>
      text().references(MediaLists, #id, onDelete: KeyAction.cascade)();
  TextColumn get name => text()();
  TextColumn get address => text()();
  IntColumn get position => integer()();
}

/// Cached TMDB match for one parsed-file-name lookup, keyed by
/// [ParsedName.lookupKey] (services/metadata.dart) so renamed copies of
/// the same movie share a row. `found == false` records a confirmed
/// TMDB miss so it is not retried on every launch (metadata_service.dart
/// re-tries misses after a TTL).
@DataClassName('MetadataCacheRow')
class MetadataCache extends Table {
  TextColumn get lookupKey => text()();
  BoolColumn get found => boolean()();
  TextColumn get title => text().nullable()();
  IntColumn get year => integer().nullable()();
  TextColumn get overview => text().nullable()();
  TextColumn get category => text().nullable()();
  TextColumn get episodeLabel => text().nullable()();

  /// Artwork file name inside the app's posters dir (not a full path —
  /// the app support dir can move between launches on mobile).
  TextColumn get posterFile => text().nullable()();
  TextColumn get mediaType => text().nullable()(); // 'movie' | 'tv'
  IntColumn get tmdbId => integer().nullable()();
  IntColumn get fetchedAt => integer()(); // epoch ms

  @override
  Set<Column> get primaryKey => {lookupKey};
}

@DriftDatabase(tables: [MediaLists, MediaEntries, MetadataCache])
class AppDatabase extends _$AppDatabase {
  // Keep the database in the app support dir with the rest of the app
  // data — drift_flutter's default (documents dir) degrades to $HOME on
  // headless Linux.
  AppDatabase()
      : super(driftDatabase(
          name: 'watchit',
          native: const DriftNativeOptions(
            databaseDirectory: getApplicationSupportDirectory,
          ),
        ));

  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from < 2) await m.createTable(metadataCache); // alpha.23
          if (from < 3) {
            // alpha.25: per-list home-screen visibility toggle.
            await m.addColumn(mediaLists, mediaLists.enabled);
          }
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );
}
