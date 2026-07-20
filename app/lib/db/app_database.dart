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

@DriftDatabase(tables: [MediaLists, MediaEntries])
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
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );
}
