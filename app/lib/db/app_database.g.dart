// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $MediaListsTable extends MediaLists
    with TableInfo<$MediaListsTable, MediaListRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MediaListsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _positionMeta = const VerificationMeta(
    'position',
  );
  @override
  late final GeneratedColumn<int> position = GeneratedColumn<int>(
    'position',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [id, title, position];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'media_lists';
  @override
  VerificationContext validateIntegrity(
    Insertable<MediaListRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('position')) {
      context.handle(
        _positionMeta,
        position.isAcceptableOrUnknown(data['position']!, _positionMeta),
      );
    } else if (isInserting) {
      context.missing(_positionMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  MediaListRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MediaListRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      position: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}position'],
      )!,
    );
  }

  @override
  $MediaListsTable createAlias(String alias) {
    return $MediaListsTable(attachedDatabase, alias);
  }
}

class MediaListRow extends DataClass implements Insertable<MediaListRow> {
  final String id;
  final String title;
  final int position;
  const MediaListRow({
    required this.id,
    required this.title,
    required this.position,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['title'] = Variable<String>(title);
    map['position'] = Variable<int>(position);
    return map;
  }

  MediaListsCompanion toCompanion(bool nullToAbsent) {
    return MediaListsCompanion(
      id: Value(id),
      title: Value(title),
      position: Value(position),
    );
  }

  factory MediaListRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MediaListRow(
      id: serializer.fromJson<String>(json['id']),
      title: serializer.fromJson<String>(json['title']),
      position: serializer.fromJson<int>(json['position']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'title': serializer.toJson<String>(title),
      'position': serializer.toJson<int>(position),
    };
  }

  MediaListRow copyWith({String? id, String? title, int? position}) =>
      MediaListRow(
        id: id ?? this.id,
        title: title ?? this.title,
        position: position ?? this.position,
      );
  MediaListRow copyWithCompanion(MediaListsCompanion data) {
    return MediaListRow(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      position: data.position.present ? data.position.value : this.position,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MediaListRow(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('position: $position')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, title, position);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MediaListRow &&
          other.id == this.id &&
          other.title == this.title &&
          other.position == this.position);
}

class MediaListsCompanion extends UpdateCompanion<MediaListRow> {
  final Value<String> id;
  final Value<String> title;
  final Value<int> position;
  final Value<int> rowid;
  const MediaListsCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.position = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MediaListsCompanion.insert({
    required String id,
    required String title,
    required int position,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       title = Value(title),
       position = Value(position);
  static Insertable<MediaListRow> custom({
    Expression<String>? id,
    Expression<String>? title,
    Expression<int>? position,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (position != null) 'position': position,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MediaListsCompanion copyWith({
    Value<String>? id,
    Value<String>? title,
    Value<int>? position,
    Value<int>? rowid,
  }) {
    return MediaListsCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      position: position ?? this.position,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (position.present) {
      map['position'] = Variable<int>(position.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MediaListsCompanion(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('position: $position, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MediaEntriesTable extends MediaEntries
    with TableInfo<$MediaEntriesTable, MediaEntryRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MediaEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _entryIdMeta = const VerificationMeta(
    'entryId',
  );
  @override
  late final GeneratedColumn<int> entryId = GeneratedColumn<int>(
    'entry_id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _listIdMeta = const VerificationMeta('listId');
  @override
  late final GeneratedColumn<String> listId = GeneratedColumn<String>(
    'list_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES media_lists (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _addressMeta = const VerificationMeta(
    'address',
  );
  @override
  late final GeneratedColumn<String> address = GeneratedColumn<String>(
    'address',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _positionMeta = const VerificationMeta(
    'position',
  );
  @override
  late final GeneratedColumn<int> position = GeneratedColumn<int>(
    'position',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    entryId,
    listId,
    name,
    address,
    position,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'media_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<MediaEntryRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('entry_id')) {
      context.handle(
        _entryIdMeta,
        entryId.isAcceptableOrUnknown(data['entry_id']!, _entryIdMeta),
      );
    }
    if (data.containsKey('list_id')) {
      context.handle(
        _listIdMeta,
        listId.isAcceptableOrUnknown(data['list_id']!, _listIdMeta),
      );
    } else if (isInserting) {
      context.missing(_listIdMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('address')) {
      context.handle(
        _addressMeta,
        address.isAcceptableOrUnknown(data['address']!, _addressMeta),
      );
    } else if (isInserting) {
      context.missing(_addressMeta);
    }
    if (data.containsKey('position')) {
      context.handle(
        _positionMeta,
        position.isAcceptableOrUnknown(data['position']!, _positionMeta),
      );
    } else if (isInserting) {
      context.missing(_positionMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {entryId};
  @override
  MediaEntryRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MediaEntryRow(
      entryId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}entry_id'],
      )!,
      listId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}list_id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      address: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}address'],
      )!,
      position: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}position'],
      )!,
    );
  }

  @override
  $MediaEntriesTable createAlias(String alias) {
    return $MediaEntriesTable(attachedDatabase, alias);
  }
}

class MediaEntryRow extends DataClass implements Insertable<MediaEntryRow> {
  final int entryId;
  final String listId;
  final String name;
  final String address;
  final int position;
  const MediaEntryRow({
    required this.entryId,
    required this.listId,
    required this.name,
    required this.address,
    required this.position,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['entry_id'] = Variable<int>(entryId);
    map['list_id'] = Variable<String>(listId);
    map['name'] = Variable<String>(name);
    map['address'] = Variable<String>(address);
    map['position'] = Variable<int>(position);
    return map;
  }

  MediaEntriesCompanion toCompanion(bool nullToAbsent) {
    return MediaEntriesCompanion(
      entryId: Value(entryId),
      listId: Value(listId),
      name: Value(name),
      address: Value(address),
      position: Value(position),
    );
  }

  factory MediaEntryRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MediaEntryRow(
      entryId: serializer.fromJson<int>(json['entryId']),
      listId: serializer.fromJson<String>(json['listId']),
      name: serializer.fromJson<String>(json['name']),
      address: serializer.fromJson<String>(json['address']),
      position: serializer.fromJson<int>(json['position']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'entryId': serializer.toJson<int>(entryId),
      'listId': serializer.toJson<String>(listId),
      'name': serializer.toJson<String>(name),
      'address': serializer.toJson<String>(address),
      'position': serializer.toJson<int>(position),
    };
  }

  MediaEntryRow copyWith({
    int? entryId,
    String? listId,
    String? name,
    String? address,
    int? position,
  }) => MediaEntryRow(
    entryId: entryId ?? this.entryId,
    listId: listId ?? this.listId,
    name: name ?? this.name,
    address: address ?? this.address,
    position: position ?? this.position,
  );
  MediaEntryRow copyWithCompanion(MediaEntriesCompanion data) {
    return MediaEntryRow(
      entryId: data.entryId.present ? data.entryId.value : this.entryId,
      listId: data.listId.present ? data.listId.value : this.listId,
      name: data.name.present ? data.name.value : this.name,
      address: data.address.present ? data.address.value : this.address,
      position: data.position.present ? data.position.value : this.position,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MediaEntryRow(')
          ..write('entryId: $entryId, ')
          ..write('listId: $listId, ')
          ..write('name: $name, ')
          ..write('address: $address, ')
          ..write('position: $position')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(entryId, listId, name, address, position);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MediaEntryRow &&
          other.entryId == this.entryId &&
          other.listId == this.listId &&
          other.name == this.name &&
          other.address == this.address &&
          other.position == this.position);
}

class MediaEntriesCompanion extends UpdateCompanion<MediaEntryRow> {
  final Value<int> entryId;
  final Value<String> listId;
  final Value<String> name;
  final Value<String> address;
  final Value<int> position;
  const MediaEntriesCompanion({
    this.entryId = const Value.absent(),
    this.listId = const Value.absent(),
    this.name = const Value.absent(),
    this.address = const Value.absent(),
    this.position = const Value.absent(),
  });
  MediaEntriesCompanion.insert({
    this.entryId = const Value.absent(),
    required String listId,
    required String name,
    required String address,
    required int position,
  }) : listId = Value(listId),
       name = Value(name),
       address = Value(address),
       position = Value(position);
  static Insertable<MediaEntryRow> custom({
    Expression<int>? entryId,
    Expression<String>? listId,
    Expression<String>? name,
    Expression<String>? address,
    Expression<int>? position,
  }) {
    return RawValuesInsertable({
      if (entryId != null) 'entry_id': entryId,
      if (listId != null) 'list_id': listId,
      if (name != null) 'name': name,
      if (address != null) 'address': address,
      if (position != null) 'position': position,
    });
  }

  MediaEntriesCompanion copyWith({
    Value<int>? entryId,
    Value<String>? listId,
    Value<String>? name,
    Value<String>? address,
    Value<int>? position,
  }) {
    return MediaEntriesCompanion(
      entryId: entryId ?? this.entryId,
      listId: listId ?? this.listId,
      name: name ?? this.name,
      address: address ?? this.address,
      position: position ?? this.position,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (entryId.present) {
      map['entry_id'] = Variable<int>(entryId.value);
    }
    if (listId.present) {
      map['list_id'] = Variable<String>(listId.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (address.present) {
      map['address'] = Variable<String>(address.value);
    }
    if (position.present) {
      map['position'] = Variable<int>(position.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MediaEntriesCompanion(')
          ..write('entryId: $entryId, ')
          ..write('listId: $listId, ')
          ..write('name: $name, ')
          ..write('address: $address, ')
          ..write('position: $position')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $MediaListsTable mediaLists = $MediaListsTable(this);
  late final $MediaEntriesTable mediaEntries = $MediaEntriesTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    mediaLists,
    mediaEntries,
  ];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules([
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'media_lists',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('media_entries', kind: UpdateKind.delete)],
    ),
  ]);
}

typedef $$MediaListsTableCreateCompanionBuilder =
    MediaListsCompanion Function({
      required String id,
      required String title,
      required int position,
      Value<int> rowid,
    });
typedef $$MediaListsTableUpdateCompanionBuilder =
    MediaListsCompanion Function({
      Value<String> id,
      Value<String> title,
      Value<int> position,
      Value<int> rowid,
    });

final class $$MediaListsTableReferences
    extends BaseReferences<_$AppDatabase, $MediaListsTable, MediaListRow> {
  $$MediaListsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$MediaEntriesTable, List<MediaEntryRow>>
  _mediaEntriesRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.mediaEntries,
    aliasName: 'media_lists__id__media_entries__list_id',
  );

  $$MediaEntriesTableProcessedTableManager get mediaEntriesRefs {
    final manager = $$MediaEntriesTableTableManager(
      $_db,
      $_db.mediaEntries,
    ).filter((f) => f.listId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_mediaEntriesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$MediaListsTableFilterComposer
    extends Composer<_$AppDatabase, $MediaListsTable> {
  $$MediaListsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> mediaEntriesRefs(
    Expression<bool> Function($$MediaEntriesTableFilterComposer f) f,
  ) {
    final $$MediaEntriesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.mediaEntries,
      getReferencedColumn: (t) => t.listId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MediaEntriesTableFilterComposer(
            $db: $db,
            $table: $db.mediaEntries,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$MediaListsTableOrderingComposer
    extends Composer<_$AppDatabase, $MediaListsTable> {
  $$MediaListsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$MediaListsTableAnnotationComposer
    extends Composer<_$AppDatabase, $MediaListsTable> {
  $$MediaListsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<int> get position =>
      $composableBuilder(column: $table.position, builder: (column) => column);

  Expression<T> mediaEntriesRefs<T extends Object>(
    Expression<T> Function($$MediaEntriesTableAnnotationComposer a) f,
  ) {
    final $$MediaEntriesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.mediaEntries,
      getReferencedColumn: (t) => t.listId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MediaEntriesTableAnnotationComposer(
            $db: $db,
            $table: $db.mediaEntries,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$MediaListsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $MediaListsTable,
          MediaListRow,
          $$MediaListsTableFilterComposer,
          $$MediaListsTableOrderingComposer,
          $$MediaListsTableAnnotationComposer,
          $$MediaListsTableCreateCompanionBuilder,
          $$MediaListsTableUpdateCompanionBuilder,
          (MediaListRow, $$MediaListsTableReferences),
          MediaListRow,
          PrefetchHooks Function({bool mediaEntriesRefs})
        > {
  $$MediaListsTableTableManager(_$AppDatabase db, $MediaListsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MediaListsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MediaListsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MediaListsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<int> position = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MediaListsCompanion(
                id: id,
                title: title,
                position: position,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String title,
                required int position,
                Value<int> rowid = const Value.absent(),
              }) => MediaListsCompanion.insert(
                id: id,
                title: title,
                position: position,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$MediaListsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({mediaEntriesRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (mediaEntriesRefs) db.mediaEntries],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (mediaEntriesRefs)
                    await $_getPrefetchedData<
                      MediaListRow,
                      $MediaListsTable,
                      MediaEntryRow
                    >(
                      currentTable: table,
                      referencedTable: $$MediaListsTableReferences
                          ._mediaEntriesRefsTable(db),
                      managerFromTypedResult: (p0) =>
                          $$MediaListsTableReferences(
                            db,
                            table,
                            p0,
                          ).mediaEntriesRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where((e) => e.listId == item.id),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$MediaListsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $MediaListsTable,
      MediaListRow,
      $$MediaListsTableFilterComposer,
      $$MediaListsTableOrderingComposer,
      $$MediaListsTableAnnotationComposer,
      $$MediaListsTableCreateCompanionBuilder,
      $$MediaListsTableUpdateCompanionBuilder,
      (MediaListRow, $$MediaListsTableReferences),
      MediaListRow,
      PrefetchHooks Function({bool mediaEntriesRefs})
    >;
typedef $$MediaEntriesTableCreateCompanionBuilder =
    MediaEntriesCompanion Function({
      Value<int> entryId,
      required String listId,
      required String name,
      required String address,
      required int position,
    });
typedef $$MediaEntriesTableUpdateCompanionBuilder =
    MediaEntriesCompanion Function({
      Value<int> entryId,
      Value<String> listId,
      Value<String> name,
      Value<String> address,
      Value<int> position,
    });

final class $$MediaEntriesTableReferences
    extends BaseReferences<_$AppDatabase, $MediaEntriesTable, MediaEntryRow> {
  $$MediaEntriesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $MediaListsTable _listIdTable(_$AppDatabase db) =>
      db.mediaLists.createAlias('media_entries__list_id__media_lists__id');

  $$MediaListsTableProcessedTableManager get listId {
    final $_column = $_itemColumn<String>('list_id')!;

    final manager = $$MediaListsTableTableManager(
      $_db,
      $_db.mediaLists,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_listIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$MediaEntriesTableFilterComposer
    extends Composer<_$AppDatabase, $MediaEntriesTable> {
  $$MediaEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get entryId => $composableBuilder(
    column: $table.entryId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get address => $composableBuilder(
    column: $table.address,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnFilters(column),
  );

  $$MediaListsTableFilterComposer get listId {
    final $$MediaListsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.listId,
      referencedTable: $db.mediaLists,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MediaListsTableFilterComposer(
            $db: $db,
            $table: $db.mediaLists,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$MediaEntriesTableOrderingComposer
    extends Composer<_$AppDatabase, $MediaEntriesTable> {
  $$MediaEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get entryId => $composableBuilder(
    column: $table.entryId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get address => $composableBuilder(
    column: $table.address,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnOrderings(column),
  );

  $$MediaListsTableOrderingComposer get listId {
    final $$MediaListsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.listId,
      referencedTable: $db.mediaLists,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MediaListsTableOrderingComposer(
            $db: $db,
            $table: $db.mediaLists,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$MediaEntriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $MediaEntriesTable> {
  $$MediaEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get entryId =>
      $composableBuilder(column: $table.entryId, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get address =>
      $composableBuilder(column: $table.address, builder: (column) => column);

  GeneratedColumn<int> get position =>
      $composableBuilder(column: $table.position, builder: (column) => column);

  $$MediaListsTableAnnotationComposer get listId {
    final $$MediaListsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.listId,
      referencedTable: $db.mediaLists,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MediaListsTableAnnotationComposer(
            $db: $db,
            $table: $db.mediaLists,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$MediaEntriesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $MediaEntriesTable,
          MediaEntryRow,
          $$MediaEntriesTableFilterComposer,
          $$MediaEntriesTableOrderingComposer,
          $$MediaEntriesTableAnnotationComposer,
          $$MediaEntriesTableCreateCompanionBuilder,
          $$MediaEntriesTableUpdateCompanionBuilder,
          (MediaEntryRow, $$MediaEntriesTableReferences),
          MediaEntryRow,
          PrefetchHooks Function({bool listId})
        > {
  $$MediaEntriesTableTableManager(_$AppDatabase db, $MediaEntriesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MediaEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MediaEntriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MediaEntriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> entryId = const Value.absent(),
                Value<String> listId = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> address = const Value.absent(),
                Value<int> position = const Value.absent(),
              }) => MediaEntriesCompanion(
                entryId: entryId,
                listId: listId,
                name: name,
                address: address,
                position: position,
              ),
          createCompanionCallback:
              ({
                Value<int> entryId = const Value.absent(),
                required String listId,
                required String name,
                required String address,
                required int position,
              }) => MediaEntriesCompanion.insert(
                entryId: entryId,
                listId: listId,
                name: name,
                address: address,
                position: position,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$MediaEntriesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({listId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (listId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.listId,
                                referencedTable: $$MediaEntriesTableReferences
                                    ._listIdTable(db),
                                referencedColumn: $$MediaEntriesTableReferences
                                    ._listIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$MediaEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $MediaEntriesTable,
      MediaEntryRow,
      $$MediaEntriesTableFilterComposer,
      $$MediaEntriesTableOrderingComposer,
      $$MediaEntriesTableAnnotationComposer,
      $$MediaEntriesTableCreateCompanionBuilder,
      $$MediaEntriesTableUpdateCompanionBuilder,
      (MediaEntryRow, $$MediaEntriesTableReferences),
      MediaEntryRow,
      PrefetchHooks Function({bool listId})
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$MediaListsTableTableManager get mediaLists =>
      $$MediaListsTableTableManager(_db, _db.mediaLists);
  $$MediaEntriesTableTableManager get mediaEntries =>
      $$MediaEntriesTableTableManager(_db, _db.mediaEntries);
}
