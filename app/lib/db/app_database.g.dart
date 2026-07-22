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
  static const VerificationMeta _enabledMeta = const VerificationMeta(
    'enabled',
  );
  @override
  late final GeneratedColumn<bool> enabled = GeneratedColumn<bool>(
    'enabled',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("enabled" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  @override
  List<GeneratedColumn> get $columns => [id, title, position, enabled];
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
    if (data.containsKey('enabled')) {
      context.handle(
        _enabledMeta,
        enabled.isAcceptableOrUnknown(data['enabled']!, _enabledMeta),
      );
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
      enabled: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}enabled'],
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

  /// Disabled lists are hidden from the home screen but kept intact.
  final bool enabled;
  const MediaListRow({
    required this.id,
    required this.title,
    required this.position,
    required this.enabled,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['title'] = Variable<String>(title);
    map['position'] = Variable<int>(position);
    map['enabled'] = Variable<bool>(enabled);
    return map;
  }

  MediaListsCompanion toCompanion(bool nullToAbsent) {
    return MediaListsCompanion(
      id: Value(id),
      title: Value(title),
      position: Value(position),
      enabled: Value(enabled),
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
      enabled: serializer.fromJson<bool>(json['enabled']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'title': serializer.toJson<String>(title),
      'position': serializer.toJson<int>(position),
      'enabled': serializer.toJson<bool>(enabled),
    };
  }

  MediaListRow copyWith({
    String? id,
    String? title,
    int? position,
    bool? enabled,
  }) => MediaListRow(
    id: id ?? this.id,
    title: title ?? this.title,
    position: position ?? this.position,
    enabled: enabled ?? this.enabled,
  );
  MediaListRow copyWithCompanion(MediaListsCompanion data) {
    return MediaListRow(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      position: data.position.present ? data.position.value : this.position,
      enabled: data.enabled.present ? data.enabled.value : this.enabled,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MediaListRow(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('position: $position, ')
          ..write('enabled: $enabled')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, title, position, enabled);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MediaListRow &&
          other.id == this.id &&
          other.title == this.title &&
          other.position == this.position &&
          other.enabled == this.enabled);
}

class MediaListsCompanion extends UpdateCompanion<MediaListRow> {
  final Value<String> id;
  final Value<String> title;
  final Value<int> position;
  final Value<bool> enabled;
  final Value<int> rowid;
  const MediaListsCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.position = const Value.absent(),
    this.enabled = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MediaListsCompanion.insert({
    required String id,
    required String title,
    required int position,
    this.enabled = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       title = Value(title),
       position = Value(position);
  static Insertable<MediaListRow> custom({
    Expression<String>? id,
    Expression<String>? title,
    Expression<int>? position,
    Expression<bool>? enabled,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (position != null) 'position': position,
      if (enabled != null) 'enabled': enabled,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MediaListsCompanion copyWith({
    Value<String>? id,
    Value<String>? title,
    Value<int>? position,
    Value<bool>? enabled,
    Value<int>? rowid,
  }) {
    return MediaListsCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      position: position ?? this.position,
      enabled: enabled ?? this.enabled,
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
    if (enabled.present) {
      map['enabled'] = Variable<bool>(enabled.value);
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
          ..write('enabled: $enabled, ')
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

class $MetadataCacheTable extends MetadataCache
    with TableInfo<$MetadataCacheTable, MetadataCacheRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MetadataCacheTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _lookupKeyMeta = const VerificationMeta(
    'lookupKey',
  );
  @override
  late final GeneratedColumn<String> lookupKey = GeneratedColumn<String>(
    'lookup_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _foundMeta = const VerificationMeta('found');
  @override
  late final GeneratedColumn<bool> found = GeneratedColumn<bool>(
    'found',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("found" IN (0, 1))',
    ),
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _yearMeta = const VerificationMeta('year');
  @override
  late final GeneratedColumn<int> year = GeneratedColumn<int>(
    'year',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _overviewMeta = const VerificationMeta(
    'overview',
  );
  @override
  late final GeneratedColumn<String> overview = GeneratedColumn<String>(
    'overview',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _categoryMeta = const VerificationMeta(
    'category',
  );
  @override
  late final GeneratedColumn<String> category = GeneratedColumn<String>(
    'category',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _episodeLabelMeta = const VerificationMeta(
    'episodeLabel',
  );
  @override
  late final GeneratedColumn<String> episodeLabel = GeneratedColumn<String>(
    'episode_label',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _posterFileMeta = const VerificationMeta(
    'posterFile',
  );
  @override
  late final GeneratedColumn<String> posterFile = GeneratedColumn<String>(
    'poster_file',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _mediaTypeMeta = const VerificationMeta(
    'mediaType',
  );
  @override
  late final GeneratedColumn<String> mediaType = GeneratedColumn<String>(
    'media_type',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _tmdbIdMeta = const VerificationMeta('tmdbId');
  @override
  late final GeneratedColumn<int> tmdbId = GeneratedColumn<int>(
    'tmdb_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _fetchedAtMeta = const VerificationMeta(
    'fetchedAt',
  );
  @override
  late final GeneratedColumn<int> fetchedAt = GeneratedColumn<int>(
    'fetched_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    lookupKey,
    found,
    title,
    year,
    overview,
    category,
    episodeLabel,
    posterFile,
    mediaType,
    tmdbId,
    fetchedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'metadata_cache';
  @override
  VerificationContext validateIntegrity(
    Insertable<MetadataCacheRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('lookup_key')) {
      context.handle(
        _lookupKeyMeta,
        lookupKey.isAcceptableOrUnknown(data['lookup_key']!, _lookupKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_lookupKeyMeta);
    }
    if (data.containsKey('found')) {
      context.handle(
        _foundMeta,
        found.isAcceptableOrUnknown(data['found']!, _foundMeta),
      );
    } else if (isInserting) {
      context.missing(_foundMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    }
    if (data.containsKey('year')) {
      context.handle(
        _yearMeta,
        year.isAcceptableOrUnknown(data['year']!, _yearMeta),
      );
    }
    if (data.containsKey('overview')) {
      context.handle(
        _overviewMeta,
        overview.isAcceptableOrUnknown(data['overview']!, _overviewMeta),
      );
    }
    if (data.containsKey('category')) {
      context.handle(
        _categoryMeta,
        category.isAcceptableOrUnknown(data['category']!, _categoryMeta),
      );
    }
    if (data.containsKey('episode_label')) {
      context.handle(
        _episodeLabelMeta,
        episodeLabel.isAcceptableOrUnknown(
          data['episode_label']!,
          _episodeLabelMeta,
        ),
      );
    }
    if (data.containsKey('poster_file')) {
      context.handle(
        _posterFileMeta,
        posterFile.isAcceptableOrUnknown(data['poster_file']!, _posterFileMeta),
      );
    }
    if (data.containsKey('media_type')) {
      context.handle(
        _mediaTypeMeta,
        mediaType.isAcceptableOrUnknown(data['media_type']!, _mediaTypeMeta),
      );
    }
    if (data.containsKey('tmdb_id')) {
      context.handle(
        _tmdbIdMeta,
        tmdbId.isAcceptableOrUnknown(data['tmdb_id']!, _tmdbIdMeta),
      );
    }
    if (data.containsKey('fetched_at')) {
      context.handle(
        _fetchedAtMeta,
        fetchedAt.isAcceptableOrUnknown(data['fetched_at']!, _fetchedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_fetchedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {lookupKey};
  @override
  MetadataCacheRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MetadataCacheRow(
      lookupKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}lookup_key'],
      )!,
      found: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}found'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      ),
      year: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}year'],
      ),
      overview: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}overview'],
      ),
      category: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}category'],
      ),
      episodeLabel: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}episode_label'],
      ),
      posterFile: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}poster_file'],
      ),
      mediaType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}media_type'],
      ),
      tmdbId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}tmdb_id'],
      ),
      fetchedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}fetched_at'],
      )!,
    );
  }

  @override
  $MetadataCacheTable createAlias(String alias) {
    return $MetadataCacheTable(attachedDatabase, alias);
  }
}

class MetadataCacheRow extends DataClass
    implements Insertable<MetadataCacheRow> {
  final String lookupKey;
  final bool found;
  final String? title;
  final int? year;
  final String? overview;
  final String? category;
  final String? episodeLabel;

  /// Artwork file name inside the app's posters dir (not a full path —
  /// the app support dir can move between launches on mobile).
  final String? posterFile;
  final String? mediaType;
  final int? tmdbId;
  final int fetchedAt;
  const MetadataCacheRow({
    required this.lookupKey,
    required this.found,
    this.title,
    this.year,
    this.overview,
    this.category,
    this.episodeLabel,
    this.posterFile,
    this.mediaType,
    this.tmdbId,
    required this.fetchedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['lookup_key'] = Variable<String>(lookupKey);
    map['found'] = Variable<bool>(found);
    if (!nullToAbsent || title != null) {
      map['title'] = Variable<String>(title);
    }
    if (!nullToAbsent || year != null) {
      map['year'] = Variable<int>(year);
    }
    if (!nullToAbsent || overview != null) {
      map['overview'] = Variable<String>(overview);
    }
    if (!nullToAbsent || category != null) {
      map['category'] = Variable<String>(category);
    }
    if (!nullToAbsent || episodeLabel != null) {
      map['episode_label'] = Variable<String>(episodeLabel);
    }
    if (!nullToAbsent || posterFile != null) {
      map['poster_file'] = Variable<String>(posterFile);
    }
    if (!nullToAbsent || mediaType != null) {
      map['media_type'] = Variable<String>(mediaType);
    }
    if (!nullToAbsent || tmdbId != null) {
      map['tmdb_id'] = Variable<int>(tmdbId);
    }
    map['fetched_at'] = Variable<int>(fetchedAt);
    return map;
  }

  MetadataCacheCompanion toCompanion(bool nullToAbsent) {
    return MetadataCacheCompanion(
      lookupKey: Value(lookupKey),
      found: Value(found),
      title: title == null && nullToAbsent
          ? const Value.absent()
          : Value(title),
      year: year == null && nullToAbsent ? const Value.absent() : Value(year),
      overview: overview == null && nullToAbsent
          ? const Value.absent()
          : Value(overview),
      category: category == null && nullToAbsent
          ? const Value.absent()
          : Value(category),
      episodeLabel: episodeLabel == null && nullToAbsent
          ? const Value.absent()
          : Value(episodeLabel),
      posterFile: posterFile == null && nullToAbsent
          ? const Value.absent()
          : Value(posterFile),
      mediaType: mediaType == null && nullToAbsent
          ? const Value.absent()
          : Value(mediaType),
      tmdbId: tmdbId == null && nullToAbsent
          ? const Value.absent()
          : Value(tmdbId),
      fetchedAt: Value(fetchedAt),
    );
  }

  factory MetadataCacheRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MetadataCacheRow(
      lookupKey: serializer.fromJson<String>(json['lookupKey']),
      found: serializer.fromJson<bool>(json['found']),
      title: serializer.fromJson<String?>(json['title']),
      year: serializer.fromJson<int?>(json['year']),
      overview: serializer.fromJson<String?>(json['overview']),
      category: serializer.fromJson<String?>(json['category']),
      episodeLabel: serializer.fromJson<String?>(json['episodeLabel']),
      posterFile: serializer.fromJson<String?>(json['posterFile']),
      mediaType: serializer.fromJson<String?>(json['mediaType']),
      tmdbId: serializer.fromJson<int?>(json['tmdbId']),
      fetchedAt: serializer.fromJson<int>(json['fetchedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'lookupKey': serializer.toJson<String>(lookupKey),
      'found': serializer.toJson<bool>(found),
      'title': serializer.toJson<String?>(title),
      'year': serializer.toJson<int?>(year),
      'overview': serializer.toJson<String?>(overview),
      'category': serializer.toJson<String?>(category),
      'episodeLabel': serializer.toJson<String?>(episodeLabel),
      'posterFile': serializer.toJson<String?>(posterFile),
      'mediaType': serializer.toJson<String?>(mediaType),
      'tmdbId': serializer.toJson<int?>(tmdbId),
      'fetchedAt': serializer.toJson<int>(fetchedAt),
    };
  }

  MetadataCacheRow copyWith({
    String? lookupKey,
    bool? found,
    Value<String?> title = const Value.absent(),
    Value<int?> year = const Value.absent(),
    Value<String?> overview = const Value.absent(),
    Value<String?> category = const Value.absent(),
    Value<String?> episodeLabel = const Value.absent(),
    Value<String?> posterFile = const Value.absent(),
    Value<String?> mediaType = const Value.absent(),
    Value<int?> tmdbId = const Value.absent(),
    int? fetchedAt,
  }) => MetadataCacheRow(
    lookupKey: lookupKey ?? this.lookupKey,
    found: found ?? this.found,
    title: title.present ? title.value : this.title,
    year: year.present ? year.value : this.year,
    overview: overview.present ? overview.value : this.overview,
    category: category.present ? category.value : this.category,
    episodeLabel: episodeLabel.present ? episodeLabel.value : this.episodeLabel,
    posterFile: posterFile.present ? posterFile.value : this.posterFile,
    mediaType: mediaType.present ? mediaType.value : this.mediaType,
    tmdbId: tmdbId.present ? tmdbId.value : this.tmdbId,
    fetchedAt: fetchedAt ?? this.fetchedAt,
  );
  MetadataCacheRow copyWithCompanion(MetadataCacheCompanion data) {
    return MetadataCacheRow(
      lookupKey: data.lookupKey.present ? data.lookupKey.value : this.lookupKey,
      found: data.found.present ? data.found.value : this.found,
      title: data.title.present ? data.title.value : this.title,
      year: data.year.present ? data.year.value : this.year,
      overview: data.overview.present ? data.overview.value : this.overview,
      category: data.category.present ? data.category.value : this.category,
      episodeLabel: data.episodeLabel.present
          ? data.episodeLabel.value
          : this.episodeLabel,
      posterFile: data.posterFile.present
          ? data.posterFile.value
          : this.posterFile,
      mediaType: data.mediaType.present ? data.mediaType.value : this.mediaType,
      tmdbId: data.tmdbId.present ? data.tmdbId.value : this.tmdbId,
      fetchedAt: data.fetchedAt.present ? data.fetchedAt.value : this.fetchedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MetadataCacheRow(')
          ..write('lookupKey: $lookupKey, ')
          ..write('found: $found, ')
          ..write('title: $title, ')
          ..write('year: $year, ')
          ..write('overview: $overview, ')
          ..write('category: $category, ')
          ..write('episodeLabel: $episodeLabel, ')
          ..write('posterFile: $posterFile, ')
          ..write('mediaType: $mediaType, ')
          ..write('tmdbId: $tmdbId, ')
          ..write('fetchedAt: $fetchedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    lookupKey,
    found,
    title,
    year,
    overview,
    category,
    episodeLabel,
    posterFile,
    mediaType,
    tmdbId,
    fetchedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MetadataCacheRow &&
          other.lookupKey == this.lookupKey &&
          other.found == this.found &&
          other.title == this.title &&
          other.year == this.year &&
          other.overview == this.overview &&
          other.category == this.category &&
          other.episodeLabel == this.episodeLabel &&
          other.posterFile == this.posterFile &&
          other.mediaType == this.mediaType &&
          other.tmdbId == this.tmdbId &&
          other.fetchedAt == this.fetchedAt);
}

class MetadataCacheCompanion extends UpdateCompanion<MetadataCacheRow> {
  final Value<String> lookupKey;
  final Value<bool> found;
  final Value<String?> title;
  final Value<int?> year;
  final Value<String?> overview;
  final Value<String?> category;
  final Value<String?> episodeLabel;
  final Value<String?> posterFile;
  final Value<String?> mediaType;
  final Value<int?> tmdbId;
  final Value<int> fetchedAt;
  final Value<int> rowid;
  const MetadataCacheCompanion({
    this.lookupKey = const Value.absent(),
    this.found = const Value.absent(),
    this.title = const Value.absent(),
    this.year = const Value.absent(),
    this.overview = const Value.absent(),
    this.category = const Value.absent(),
    this.episodeLabel = const Value.absent(),
    this.posterFile = const Value.absent(),
    this.mediaType = const Value.absent(),
    this.tmdbId = const Value.absent(),
    this.fetchedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MetadataCacheCompanion.insert({
    required String lookupKey,
    required bool found,
    this.title = const Value.absent(),
    this.year = const Value.absent(),
    this.overview = const Value.absent(),
    this.category = const Value.absent(),
    this.episodeLabel = const Value.absent(),
    this.posterFile = const Value.absent(),
    this.mediaType = const Value.absent(),
    this.tmdbId = const Value.absent(),
    required int fetchedAt,
    this.rowid = const Value.absent(),
  }) : lookupKey = Value(lookupKey),
       found = Value(found),
       fetchedAt = Value(fetchedAt);
  static Insertable<MetadataCacheRow> custom({
    Expression<String>? lookupKey,
    Expression<bool>? found,
    Expression<String>? title,
    Expression<int>? year,
    Expression<String>? overview,
    Expression<String>? category,
    Expression<String>? episodeLabel,
    Expression<String>? posterFile,
    Expression<String>? mediaType,
    Expression<int>? tmdbId,
    Expression<int>? fetchedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (lookupKey != null) 'lookup_key': lookupKey,
      if (found != null) 'found': found,
      if (title != null) 'title': title,
      if (year != null) 'year': year,
      if (overview != null) 'overview': overview,
      if (category != null) 'category': category,
      if (episodeLabel != null) 'episode_label': episodeLabel,
      if (posterFile != null) 'poster_file': posterFile,
      if (mediaType != null) 'media_type': mediaType,
      if (tmdbId != null) 'tmdb_id': tmdbId,
      if (fetchedAt != null) 'fetched_at': fetchedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MetadataCacheCompanion copyWith({
    Value<String>? lookupKey,
    Value<bool>? found,
    Value<String?>? title,
    Value<int?>? year,
    Value<String?>? overview,
    Value<String?>? category,
    Value<String?>? episodeLabel,
    Value<String?>? posterFile,
    Value<String?>? mediaType,
    Value<int?>? tmdbId,
    Value<int>? fetchedAt,
    Value<int>? rowid,
  }) {
    return MetadataCacheCompanion(
      lookupKey: lookupKey ?? this.lookupKey,
      found: found ?? this.found,
      title: title ?? this.title,
      year: year ?? this.year,
      overview: overview ?? this.overview,
      category: category ?? this.category,
      episodeLabel: episodeLabel ?? this.episodeLabel,
      posterFile: posterFile ?? this.posterFile,
      mediaType: mediaType ?? this.mediaType,
      tmdbId: tmdbId ?? this.tmdbId,
      fetchedAt: fetchedAt ?? this.fetchedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (lookupKey.present) {
      map['lookup_key'] = Variable<String>(lookupKey.value);
    }
    if (found.present) {
      map['found'] = Variable<bool>(found.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (year.present) {
      map['year'] = Variable<int>(year.value);
    }
    if (overview.present) {
      map['overview'] = Variable<String>(overview.value);
    }
    if (category.present) {
      map['category'] = Variable<String>(category.value);
    }
    if (episodeLabel.present) {
      map['episode_label'] = Variable<String>(episodeLabel.value);
    }
    if (posterFile.present) {
      map['poster_file'] = Variable<String>(posterFile.value);
    }
    if (mediaType.present) {
      map['media_type'] = Variable<String>(mediaType.value);
    }
    if (tmdbId.present) {
      map['tmdb_id'] = Variable<int>(tmdbId.value);
    }
    if (fetchedAt.present) {
      map['fetched_at'] = Variable<int>(fetchedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MetadataCacheCompanion(')
          ..write('lookupKey: $lookupKey, ')
          ..write('found: $found, ')
          ..write('title: $title, ')
          ..write('year: $year, ')
          ..write('overview: $overview, ')
          ..write('category: $category, ')
          ..write('episodeLabel: $episodeLabel, ')
          ..write('posterFile: $posterFile, ')
          ..write('mediaType: $mediaType, ')
          ..write('tmdbId: $tmdbId, ')
          ..write('fetchedAt: $fetchedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $MediaListsTable mediaLists = $MediaListsTable(this);
  late final $MediaEntriesTable mediaEntries = $MediaEntriesTable(this);
  late final $MetadataCacheTable metadataCache = $MetadataCacheTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    mediaLists,
    mediaEntries,
    metadataCache,
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
      Value<bool> enabled,
      Value<int> rowid,
    });
typedef $$MediaListsTableUpdateCompanionBuilder =
    MediaListsCompanion Function({
      Value<String> id,
      Value<String> title,
      Value<int> position,
      Value<bool> enabled,
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

  ColumnFilters<bool> get enabled => $composableBuilder(
    column: $table.enabled,
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

  ColumnOrderings<bool> get enabled => $composableBuilder(
    column: $table.enabled,
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

  GeneratedColumn<bool> get enabled =>
      $composableBuilder(column: $table.enabled, builder: (column) => column);

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
                Value<bool> enabled = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MediaListsCompanion(
                id: id,
                title: title,
                position: position,
                enabled: enabled,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String title,
                required int position,
                Value<bool> enabled = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MediaListsCompanion.insert(
                id: id,
                title: title,
                position: position,
                enabled: enabled,
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
typedef $$MetadataCacheTableCreateCompanionBuilder =
    MetadataCacheCompanion Function({
      required String lookupKey,
      required bool found,
      Value<String?> title,
      Value<int?> year,
      Value<String?> overview,
      Value<String?> category,
      Value<String?> episodeLabel,
      Value<String?> posterFile,
      Value<String?> mediaType,
      Value<int?> tmdbId,
      required int fetchedAt,
      Value<int> rowid,
    });
typedef $$MetadataCacheTableUpdateCompanionBuilder =
    MetadataCacheCompanion Function({
      Value<String> lookupKey,
      Value<bool> found,
      Value<String?> title,
      Value<int?> year,
      Value<String?> overview,
      Value<String?> category,
      Value<String?> episodeLabel,
      Value<String?> posterFile,
      Value<String?> mediaType,
      Value<int?> tmdbId,
      Value<int> fetchedAt,
      Value<int> rowid,
    });

class $$MetadataCacheTableFilterComposer
    extends Composer<_$AppDatabase, $MetadataCacheTable> {
  $$MetadataCacheTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get lookupKey => $composableBuilder(
    column: $table.lookupKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get found => $composableBuilder(
    column: $table.found,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get year => $composableBuilder(
    column: $table.year,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get overview => $composableBuilder(
    column: $table.overview,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get category => $composableBuilder(
    column: $table.category,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get episodeLabel => $composableBuilder(
    column: $table.episodeLabel,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get posterFile => $composableBuilder(
    column: $table.posterFile,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mediaType => $composableBuilder(
    column: $table.mediaType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get tmdbId => $composableBuilder(
    column: $table.tmdbId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get fetchedAt => $composableBuilder(
    column: $table.fetchedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$MetadataCacheTableOrderingComposer
    extends Composer<_$AppDatabase, $MetadataCacheTable> {
  $$MetadataCacheTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get lookupKey => $composableBuilder(
    column: $table.lookupKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get found => $composableBuilder(
    column: $table.found,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get year => $composableBuilder(
    column: $table.year,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get overview => $composableBuilder(
    column: $table.overview,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get category => $composableBuilder(
    column: $table.category,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get episodeLabel => $composableBuilder(
    column: $table.episodeLabel,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get posterFile => $composableBuilder(
    column: $table.posterFile,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mediaType => $composableBuilder(
    column: $table.mediaType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get tmdbId => $composableBuilder(
    column: $table.tmdbId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get fetchedAt => $composableBuilder(
    column: $table.fetchedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$MetadataCacheTableAnnotationComposer
    extends Composer<_$AppDatabase, $MetadataCacheTable> {
  $$MetadataCacheTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get lookupKey =>
      $composableBuilder(column: $table.lookupKey, builder: (column) => column);

  GeneratedColumn<bool> get found =>
      $composableBuilder(column: $table.found, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<int> get year =>
      $composableBuilder(column: $table.year, builder: (column) => column);

  GeneratedColumn<String> get overview =>
      $composableBuilder(column: $table.overview, builder: (column) => column);

  GeneratedColumn<String> get category =>
      $composableBuilder(column: $table.category, builder: (column) => column);

  GeneratedColumn<String> get episodeLabel => $composableBuilder(
    column: $table.episodeLabel,
    builder: (column) => column,
  );

  GeneratedColumn<String> get posterFile => $composableBuilder(
    column: $table.posterFile,
    builder: (column) => column,
  );

  GeneratedColumn<String> get mediaType =>
      $composableBuilder(column: $table.mediaType, builder: (column) => column);

  GeneratedColumn<int> get tmdbId =>
      $composableBuilder(column: $table.tmdbId, builder: (column) => column);

  GeneratedColumn<int> get fetchedAt =>
      $composableBuilder(column: $table.fetchedAt, builder: (column) => column);
}

class $$MetadataCacheTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $MetadataCacheTable,
          MetadataCacheRow,
          $$MetadataCacheTableFilterComposer,
          $$MetadataCacheTableOrderingComposer,
          $$MetadataCacheTableAnnotationComposer,
          $$MetadataCacheTableCreateCompanionBuilder,
          $$MetadataCacheTableUpdateCompanionBuilder,
          (
            MetadataCacheRow,
            BaseReferences<
              _$AppDatabase,
              $MetadataCacheTable,
              MetadataCacheRow
            >,
          ),
          MetadataCacheRow,
          PrefetchHooks Function()
        > {
  $$MetadataCacheTableTableManager(_$AppDatabase db, $MetadataCacheTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MetadataCacheTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MetadataCacheTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MetadataCacheTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> lookupKey = const Value.absent(),
                Value<bool> found = const Value.absent(),
                Value<String?> title = const Value.absent(),
                Value<int?> year = const Value.absent(),
                Value<String?> overview = const Value.absent(),
                Value<String?> category = const Value.absent(),
                Value<String?> episodeLabel = const Value.absent(),
                Value<String?> posterFile = const Value.absent(),
                Value<String?> mediaType = const Value.absent(),
                Value<int?> tmdbId = const Value.absent(),
                Value<int> fetchedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MetadataCacheCompanion(
                lookupKey: lookupKey,
                found: found,
                title: title,
                year: year,
                overview: overview,
                category: category,
                episodeLabel: episodeLabel,
                posterFile: posterFile,
                mediaType: mediaType,
                tmdbId: tmdbId,
                fetchedAt: fetchedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String lookupKey,
                required bool found,
                Value<String?> title = const Value.absent(),
                Value<int?> year = const Value.absent(),
                Value<String?> overview = const Value.absent(),
                Value<String?> category = const Value.absent(),
                Value<String?> episodeLabel = const Value.absent(),
                Value<String?> posterFile = const Value.absent(),
                Value<String?> mediaType = const Value.absent(),
                Value<int?> tmdbId = const Value.absent(),
                required int fetchedAt,
                Value<int> rowid = const Value.absent(),
              }) => MetadataCacheCompanion.insert(
                lookupKey: lookupKey,
                found: found,
                title: title,
                year: year,
                overview: overview,
                category: category,
                episodeLabel: episodeLabel,
                posterFile: posterFile,
                mediaType: mediaType,
                tmdbId: tmdbId,
                fetchedAt: fetchedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$MetadataCacheTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $MetadataCacheTable,
      MetadataCacheRow,
      $$MetadataCacheTableFilterComposer,
      $$MetadataCacheTableOrderingComposer,
      $$MetadataCacheTableAnnotationComposer,
      $$MetadataCacheTableCreateCompanionBuilder,
      $$MetadataCacheTableUpdateCompanionBuilder,
      (
        MetadataCacheRow,
        BaseReferences<_$AppDatabase, $MetadataCacheTable, MetadataCacheRow>,
      ),
      MetadataCacheRow,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$MediaListsTableTableManager get mediaLists =>
      $$MediaListsTableTableManager(_db, _db.mediaLists);
  $$MediaEntriesTableTableManager get mediaEntries =>
      $$MediaEntriesTableTableManager(_db, _db.mediaEntries);
  $$MetadataCacheTableTableManager get metadataCache =>
      $$MetadataCacheTableTableManager(_db, _db.metadataCache);
}
