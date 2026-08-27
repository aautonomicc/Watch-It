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
  static const VerificationMeta _channelPubkeyMeta = const VerificationMeta(
    'channelPubkey',
  );
  @override
  late final GeneratedColumn<String> channelPubkey = GeneratedColumn<String>(
    'channel_pubkey',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    title,
    position,
    enabled,
    channelPubkey,
  ];
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
    if (data.containsKey('channel_pubkey')) {
      context.handle(
        _channelPubkeyMeta,
        channelPubkey.isAcceptableOrUnknown(
          data['channel_pubkey']!,
          _channelPubkeyMeta,
        ),
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
      channelPubkey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}channel_pubkey'],
      ),
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

  /// Non-null marks this list as a subscribed CHANNEL: a read-only,
  /// auto-updating mirror of that channel's published manifest (the
  /// value is the channel's Ed25519 public key, lowercase hex). Channel
  /// lists are managed by unsubscribing, never by editing.
  final String? channelPubkey;
  const MediaListRow({
    required this.id,
    required this.title,
    required this.position,
    required this.enabled,
    this.channelPubkey,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['title'] = Variable<String>(title);
    map['position'] = Variable<int>(position);
    map['enabled'] = Variable<bool>(enabled);
    if (!nullToAbsent || channelPubkey != null) {
      map['channel_pubkey'] = Variable<String>(channelPubkey);
    }
    return map;
  }

  MediaListsCompanion toCompanion(bool nullToAbsent) {
    return MediaListsCompanion(
      id: Value(id),
      title: Value(title),
      position: Value(position),
      enabled: Value(enabled),
      channelPubkey: channelPubkey == null && nullToAbsent
          ? const Value.absent()
          : Value(channelPubkey),
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
      channelPubkey: serializer.fromJson<String?>(json['channelPubkey']),
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
      'channelPubkey': serializer.toJson<String?>(channelPubkey),
    };
  }

  MediaListRow copyWith({
    String? id,
    String? title,
    int? position,
    bool? enabled,
    Value<String?> channelPubkey = const Value.absent(),
  }) => MediaListRow(
    id: id ?? this.id,
    title: title ?? this.title,
    position: position ?? this.position,
    enabled: enabled ?? this.enabled,
    channelPubkey: channelPubkey.present
        ? channelPubkey.value
        : this.channelPubkey,
  );
  MediaListRow copyWithCompanion(MediaListsCompanion data) {
    return MediaListRow(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      position: data.position.present ? data.position.value : this.position,
      enabled: data.enabled.present ? data.enabled.value : this.enabled,
      channelPubkey: data.channelPubkey.present
          ? data.channelPubkey.value
          : this.channelPubkey,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MediaListRow(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('position: $position, ')
          ..write('enabled: $enabled, ')
          ..write('channelPubkey: $channelPubkey')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, title, position, enabled, channelPubkey);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MediaListRow &&
          other.id == this.id &&
          other.title == this.title &&
          other.position == this.position &&
          other.enabled == this.enabled &&
          other.channelPubkey == this.channelPubkey);
}

class MediaListsCompanion extends UpdateCompanion<MediaListRow> {
  final Value<String> id;
  final Value<String> title;
  final Value<int> position;
  final Value<bool> enabled;
  final Value<String?> channelPubkey;
  final Value<int> rowid;
  const MediaListsCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.position = const Value.absent(),
    this.enabled = const Value.absent(),
    this.channelPubkey = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MediaListsCompanion.insert({
    required String id,
    required String title,
    required int position,
    this.enabled = const Value.absent(),
    this.channelPubkey = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       title = Value(title),
       position = Value(position);
  static Insertable<MediaListRow> custom({
    Expression<String>? id,
    Expression<String>? title,
    Expression<int>? position,
    Expression<bool>? enabled,
    Expression<String>? channelPubkey,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (position != null) 'position': position,
      if (enabled != null) 'enabled': enabled,
      if (channelPubkey != null) 'channel_pubkey': channelPubkey,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MediaListsCompanion copyWith({
    Value<String>? id,
    Value<String>? title,
    Value<int>? position,
    Value<bool>? enabled,
    Value<String?>? channelPubkey,
    Value<int>? rowid,
  }) {
    return MediaListsCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      position: position ?? this.position,
      enabled: enabled ?? this.enabled,
      channelPubkey: channelPubkey ?? this.channelPubkey,
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
    if (channelPubkey.present) {
      map['channel_pubkey'] = Variable<String>(channelPubkey.value);
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
          ..write('channelPubkey: $channelPubkey, ')
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
  static const VerificationMeta _addedAtMeta = const VerificationMeta(
    'addedAt',
  );
  @override
  late final GeneratedColumn<int> addedAt = GeneratedColumn<int>(
    'added_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _sizeBytesMeta = const VerificationMeta(
    'sizeBytes',
  );
  @override
  late final GeneratedColumn<int> sizeBytes = GeneratedColumn<int>(
    'size_bytes',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _videoInfoMeta = const VerificationMeta(
    'videoInfo',
  );
  @override
  late final GeneratedColumn<String> videoInfo = GeneratedColumn<String>(
    'video_info',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    entryId,
    listId,
    name,
    address,
    position,
    addedAt,
    sizeBytes,
    videoInfo,
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
    if (data.containsKey('added_at')) {
      context.handle(
        _addedAtMeta,
        addedAt.isAcceptableOrUnknown(data['added_at']!, _addedAtMeta),
      );
    }
    if (data.containsKey('size_bytes')) {
      context.handle(
        _sizeBytesMeta,
        sizeBytes.isAcceptableOrUnknown(data['size_bytes']!, _sizeBytesMeta),
      );
    }
    if (data.containsKey('video_info')) {
      context.handle(
        _videoInfoMeta,
        videoInfo.isAcceptableOrUnknown(data['video_info']!, _videoInfoMeta),
      );
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
      addedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}added_at'],
      )!,
      sizeBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}size_bytes'],
      ),
      videoInfo: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}video_info'],
      ),
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

  /// When the entry first entered the library (epoch ms) — feeds the
  /// home screen's Recently Added row. 0 for rows that predate the
  /// column (their add time is unknown, so the row skips them).
  final int addedAt;

  /// Exact original file size in bytes from the root data map; null for
  /// rows that predate the column (backfilled lazily from `/resolve`).
  final int? sizeBytes;

  /// Short video-format label (`480p H.264`) — seeded for catalog
  /// entries, learned from playback for imports; null until known.
  final String? videoInfo;
  const MediaEntryRow({
    required this.entryId,
    required this.listId,
    required this.name,
    required this.address,
    required this.position,
    required this.addedAt,
    this.sizeBytes,
    this.videoInfo,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['entry_id'] = Variable<int>(entryId);
    map['list_id'] = Variable<String>(listId);
    map['name'] = Variable<String>(name);
    map['address'] = Variable<String>(address);
    map['position'] = Variable<int>(position);
    map['added_at'] = Variable<int>(addedAt);
    if (!nullToAbsent || sizeBytes != null) {
      map['size_bytes'] = Variable<int>(sizeBytes);
    }
    if (!nullToAbsent || videoInfo != null) {
      map['video_info'] = Variable<String>(videoInfo);
    }
    return map;
  }

  MediaEntriesCompanion toCompanion(bool nullToAbsent) {
    return MediaEntriesCompanion(
      entryId: Value(entryId),
      listId: Value(listId),
      name: Value(name),
      address: Value(address),
      position: Value(position),
      addedAt: Value(addedAt),
      sizeBytes: sizeBytes == null && nullToAbsent
          ? const Value.absent()
          : Value(sizeBytes),
      videoInfo: videoInfo == null && nullToAbsent
          ? const Value.absent()
          : Value(videoInfo),
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
      addedAt: serializer.fromJson<int>(json['addedAt']),
      sizeBytes: serializer.fromJson<int?>(json['sizeBytes']),
      videoInfo: serializer.fromJson<String?>(json['videoInfo']),
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
      'addedAt': serializer.toJson<int>(addedAt),
      'sizeBytes': serializer.toJson<int?>(sizeBytes),
      'videoInfo': serializer.toJson<String?>(videoInfo),
    };
  }

  MediaEntryRow copyWith({
    int? entryId,
    String? listId,
    String? name,
    String? address,
    int? position,
    int? addedAt,
    Value<int?> sizeBytes = const Value.absent(),
    Value<String?> videoInfo = const Value.absent(),
  }) => MediaEntryRow(
    entryId: entryId ?? this.entryId,
    listId: listId ?? this.listId,
    name: name ?? this.name,
    address: address ?? this.address,
    position: position ?? this.position,
    addedAt: addedAt ?? this.addedAt,
    sizeBytes: sizeBytes.present ? sizeBytes.value : this.sizeBytes,
    videoInfo: videoInfo.present ? videoInfo.value : this.videoInfo,
  );
  MediaEntryRow copyWithCompanion(MediaEntriesCompanion data) {
    return MediaEntryRow(
      entryId: data.entryId.present ? data.entryId.value : this.entryId,
      listId: data.listId.present ? data.listId.value : this.listId,
      name: data.name.present ? data.name.value : this.name,
      address: data.address.present ? data.address.value : this.address,
      position: data.position.present ? data.position.value : this.position,
      addedAt: data.addedAt.present ? data.addedAt.value : this.addedAt,
      sizeBytes: data.sizeBytes.present ? data.sizeBytes.value : this.sizeBytes,
      videoInfo: data.videoInfo.present ? data.videoInfo.value : this.videoInfo,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MediaEntryRow(')
          ..write('entryId: $entryId, ')
          ..write('listId: $listId, ')
          ..write('name: $name, ')
          ..write('address: $address, ')
          ..write('position: $position, ')
          ..write('addedAt: $addedAt, ')
          ..write('sizeBytes: $sizeBytes, ')
          ..write('videoInfo: $videoInfo')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    entryId,
    listId,
    name,
    address,
    position,
    addedAt,
    sizeBytes,
    videoInfo,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MediaEntryRow &&
          other.entryId == this.entryId &&
          other.listId == this.listId &&
          other.name == this.name &&
          other.address == this.address &&
          other.position == this.position &&
          other.addedAt == this.addedAt &&
          other.sizeBytes == this.sizeBytes &&
          other.videoInfo == this.videoInfo);
}

class MediaEntriesCompanion extends UpdateCompanion<MediaEntryRow> {
  final Value<int> entryId;
  final Value<String> listId;
  final Value<String> name;
  final Value<String> address;
  final Value<int> position;
  final Value<int> addedAt;
  final Value<int?> sizeBytes;
  final Value<String?> videoInfo;
  const MediaEntriesCompanion({
    this.entryId = const Value.absent(),
    this.listId = const Value.absent(),
    this.name = const Value.absent(),
    this.address = const Value.absent(),
    this.position = const Value.absent(),
    this.addedAt = const Value.absent(),
    this.sizeBytes = const Value.absent(),
    this.videoInfo = const Value.absent(),
  });
  MediaEntriesCompanion.insert({
    this.entryId = const Value.absent(),
    required String listId,
    required String name,
    required String address,
    required int position,
    this.addedAt = const Value.absent(),
    this.sizeBytes = const Value.absent(),
    this.videoInfo = const Value.absent(),
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
    Expression<int>? addedAt,
    Expression<int>? sizeBytes,
    Expression<String>? videoInfo,
  }) {
    return RawValuesInsertable({
      if (entryId != null) 'entry_id': entryId,
      if (listId != null) 'list_id': listId,
      if (name != null) 'name': name,
      if (address != null) 'address': address,
      if (position != null) 'position': position,
      if (addedAt != null) 'added_at': addedAt,
      if (sizeBytes != null) 'size_bytes': sizeBytes,
      if (videoInfo != null) 'video_info': videoInfo,
    });
  }

  MediaEntriesCompanion copyWith({
    Value<int>? entryId,
    Value<String>? listId,
    Value<String>? name,
    Value<String>? address,
    Value<int>? position,
    Value<int>? addedAt,
    Value<int?>? sizeBytes,
    Value<String?>? videoInfo,
  }) {
    return MediaEntriesCompanion(
      entryId: entryId ?? this.entryId,
      listId: listId ?? this.listId,
      name: name ?? this.name,
      address: address ?? this.address,
      position: position ?? this.position,
      addedAt: addedAt ?? this.addedAt,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      videoInfo: videoInfo ?? this.videoInfo,
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
    if (addedAt.present) {
      map['added_at'] = Variable<int>(addedAt.value);
    }
    if (sizeBytes.present) {
      map['size_bytes'] = Variable<int>(sizeBytes.value);
    }
    if (videoInfo.present) {
      map['video_info'] = Variable<String>(videoInfo.value);
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
          ..write('position: $position, ')
          ..write('addedAt: $addedAt, ')
          ..write('sizeBytes: $sizeBytes, ')
          ..write('videoInfo: $videoInfo')
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
  static const VerificationMeta _ratingMeta = const VerificationMeta('rating');
  @override
  late final GeneratedColumn<double> rating = GeneratedColumn<double>(
    'rating',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _showOverviewMeta = const VerificationMeta(
    'showOverview',
  );
  @override
  late final GeneratedColumn<String> showOverview = GeneratedColumn<String>(
    'show_overview',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _seasonOverviewMeta = const VerificationMeta(
    'seasonOverview',
  );
  @override
  late final GeneratedColumn<String> seasonOverview = GeneratedColumn<String>(
    'season_overview',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _airDateMeta = const VerificationMeta(
    'airDate',
  );
  @override
  late final GeneratedColumn<String> airDate = GeneratedColumn<String>(
    'air_date',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _stillFileMeta = const VerificationMeta(
    'stillFile',
  );
  @override
  late final GeneratedColumn<String> stillFile = GeneratedColumn<String>(
    'still_file',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _showPosterFileMeta = const VerificationMeta(
    'showPosterFile',
  );
  @override
  late final GeneratedColumn<String> showPosterFile = GeneratedColumn<String>(
    'show_poster_file',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _userEditedMeta = const VerificationMeta(
    'userEdited',
  );
  @override
  late final GeneratedColumn<bool> userEdited = GeneratedColumn<bool>(
    'user_edited',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("user_edited" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
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
    rating,
    showOverview,
    seasonOverview,
    airDate,
    stillFile,
    showPosterFile,
    userEdited,
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
    if (data.containsKey('rating')) {
      context.handle(
        _ratingMeta,
        rating.isAcceptableOrUnknown(data['rating']!, _ratingMeta),
      );
    }
    if (data.containsKey('show_overview')) {
      context.handle(
        _showOverviewMeta,
        showOverview.isAcceptableOrUnknown(
          data['show_overview']!,
          _showOverviewMeta,
        ),
      );
    }
    if (data.containsKey('season_overview')) {
      context.handle(
        _seasonOverviewMeta,
        seasonOverview.isAcceptableOrUnknown(
          data['season_overview']!,
          _seasonOverviewMeta,
        ),
      );
    }
    if (data.containsKey('air_date')) {
      context.handle(
        _airDateMeta,
        airDate.isAcceptableOrUnknown(data['air_date']!, _airDateMeta),
      );
    }
    if (data.containsKey('still_file')) {
      context.handle(
        _stillFileMeta,
        stillFile.isAcceptableOrUnknown(data['still_file']!, _stillFileMeta),
      );
    }
    if (data.containsKey('show_poster_file')) {
      context.handle(
        _showPosterFileMeta,
        showPosterFile.isAcceptableOrUnknown(
          data['show_poster_file']!,
          _showPosterFileMeta,
        ),
      );
    }
    if (data.containsKey('user_edited')) {
      context.handle(
        _userEditedMeta,
        userEdited.isAcceptableOrUnknown(data['user_edited']!, _userEditedMeta),
      );
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
      rating: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}rating'],
      ),
      showOverview: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}show_overview'],
      ),
      seasonOverview: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}season_overview'],
      ),
      airDate: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}air_date'],
      ),
      stillFile: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}still_file'],
      ),
      showPosterFile: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}show_poster_file'],
      ),
      userEdited: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}user_edited'],
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

  /// TMDB community score out of 10; null when unrated.
  final double? rating;

  /// Show/season synopses for episode rows ([overview] holds the
  /// episode's own synopsis there).
  final String? showOverview;
  final String? seasonOverview;

  /// Episode air date (`2008-01-20`); the release date for movies.
  final String? airDate;

  /// Episode screenshot / show poster file names in the posters dir.
  final String? stillFile;
  final String? showPosterFile;

  /// Row written by the user through Edit details rather than matched
  /// from TMDB. User rows are never replaced by a TMDB match (a found
  /// row already short-circuits the fetch) and survive key changes.
  final bool userEdited;
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
    this.rating,
    this.showOverview,
    this.seasonOverview,
    this.airDate,
    this.stillFile,
    this.showPosterFile,
    required this.userEdited,
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
    if (!nullToAbsent || rating != null) {
      map['rating'] = Variable<double>(rating);
    }
    if (!nullToAbsent || showOverview != null) {
      map['show_overview'] = Variable<String>(showOverview);
    }
    if (!nullToAbsent || seasonOverview != null) {
      map['season_overview'] = Variable<String>(seasonOverview);
    }
    if (!nullToAbsent || airDate != null) {
      map['air_date'] = Variable<String>(airDate);
    }
    if (!nullToAbsent || stillFile != null) {
      map['still_file'] = Variable<String>(stillFile);
    }
    if (!nullToAbsent || showPosterFile != null) {
      map['show_poster_file'] = Variable<String>(showPosterFile);
    }
    map['user_edited'] = Variable<bool>(userEdited);
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
      rating: rating == null && nullToAbsent
          ? const Value.absent()
          : Value(rating),
      showOverview: showOverview == null && nullToAbsent
          ? const Value.absent()
          : Value(showOverview),
      seasonOverview: seasonOverview == null && nullToAbsent
          ? const Value.absent()
          : Value(seasonOverview),
      airDate: airDate == null && nullToAbsent
          ? const Value.absent()
          : Value(airDate),
      stillFile: stillFile == null && nullToAbsent
          ? const Value.absent()
          : Value(stillFile),
      showPosterFile: showPosterFile == null && nullToAbsent
          ? const Value.absent()
          : Value(showPosterFile),
      userEdited: Value(userEdited),
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
      rating: serializer.fromJson<double?>(json['rating']),
      showOverview: serializer.fromJson<String?>(json['showOverview']),
      seasonOverview: serializer.fromJson<String?>(json['seasonOverview']),
      airDate: serializer.fromJson<String?>(json['airDate']),
      stillFile: serializer.fromJson<String?>(json['stillFile']),
      showPosterFile: serializer.fromJson<String?>(json['showPosterFile']),
      userEdited: serializer.fromJson<bool>(json['userEdited']),
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
      'rating': serializer.toJson<double?>(rating),
      'showOverview': serializer.toJson<String?>(showOverview),
      'seasonOverview': serializer.toJson<String?>(seasonOverview),
      'airDate': serializer.toJson<String?>(airDate),
      'stillFile': serializer.toJson<String?>(stillFile),
      'showPosterFile': serializer.toJson<String?>(showPosterFile),
      'userEdited': serializer.toJson<bool>(userEdited),
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
    Value<double?> rating = const Value.absent(),
    Value<String?> showOverview = const Value.absent(),
    Value<String?> seasonOverview = const Value.absent(),
    Value<String?> airDate = const Value.absent(),
    Value<String?> stillFile = const Value.absent(),
    Value<String?> showPosterFile = const Value.absent(),
    bool? userEdited,
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
    rating: rating.present ? rating.value : this.rating,
    showOverview: showOverview.present ? showOverview.value : this.showOverview,
    seasonOverview: seasonOverview.present
        ? seasonOverview.value
        : this.seasonOverview,
    airDate: airDate.present ? airDate.value : this.airDate,
    stillFile: stillFile.present ? stillFile.value : this.stillFile,
    showPosterFile: showPosterFile.present
        ? showPosterFile.value
        : this.showPosterFile,
    userEdited: userEdited ?? this.userEdited,
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
      rating: data.rating.present ? data.rating.value : this.rating,
      showOverview: data.showOverview.present
          ? data.showOverview.value
          : this.showOverview,
      seasonOverview: data.seasonOverview.present
          ? data.seasonOverview.value
          : this.seasonOverview,
      airDate: data.airDate.present ? data.airDate.value : this.airDate,
      stillFile: data.stillFile.present ? data.stillFile.value : this.stillFile,
      showPosterFile: data.showPosterFile.present
          ? data.showPosterFile.value
          : this.showPosterFile,
      userEdited: data.userEdited.present
          ? data.userEdited.value
          : this.userEdited,
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
          ..write('fetchedAt: $fetchedAt, ')
          ..write('rating: $rating, ')
          ..write('showOverview: $showOverview, ')
          ..write('seasonOverview: $seasonOverview, ')
          ..write('airDate: $airDate, ')
          ..write('stillFile: $stillFile, ')
          ..write('showPosterFile: $showPosterFile, ')
          ..write('userEdited: $userEdited')
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
    rating,
    showOverview,
    seasonOverview,
    airDate,
    stillFile,
    showPosterFile,
    userEdited,
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
          other.fetchedAt == this.fetchedAt &&
          other.rating == this.rating &&
          other.showOverview == this.showOverview &&
          other.seasonOverview == this.seasonOverview &&
          other.airDate == this.airDate &&
          other.stillFile == this.stillFile &&
          other.showPosterFile == this.showPosterFile &&
          other.userEdited == this.userEdited);
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
  final Value<double?> rating;
  final Value<String?> showOverview;
  final Value<String?> seasonOverview;
  final Value<String?> airDate;
  final Value<String?> stillFile;
  final Value<String?> showPosterFile;
  final Value<bool> userEdited;
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
    this.rating = const Value.absent(),
    this.showOverview = const Value.absent(),
    this.seasonOverview = const Value.absent(),
    this.airDate = const Value.absent(),
    this.stillFile = const Value.absent(),
    this.showPosterFile = const Value.absent(),
    this.userEdited = const Value.absent(),
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
    this.rating = const Value.absent(),
    this.showOverview = const Value.absent(),
    this.seasonOverview = const Value.absent(),
    this.airDate = const Value.absent(),
    this.stillFile = const Value.absent(),
    this.showPosterFile = const Value.absent(),
    this.userEdited = const Value.absent(),
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
    Expression<double>? rating,
    Expression<String>? showOverview,
    Expression<String>? seasonOverview,
    Expression<String>? airDate,
    Expression<String>? stillFile,
    Expression<String>? showPosterFile,
    Expression<bool>? userEdited,
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
      if (rating != null) 'rating': rating,
      if (showOverview != null) 'show_overview': showOverview,
      if (seasonOverview != null) 'season_overview': seasonOverview,
      if (airDate != null) 'air_date': airDate,
      if (stillFile != null) 'still_file': stillFile,
      if (showPosterFile != null) 'show_poster_file': showPosterFile,
      if (userEdited != null) 'user_edited': userEdited,
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
    Value<double?>? rating,
    Value<String?>? showOverview,
    Value<String?>? seasonOverview,
    Value<String?>? airDate,
    Value<String?>? stillFile,
    Value<String?>? showPosterFile,
    Value<bool>? userEdited,
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
      rating: rating ?? this.rating,
      showOverview: showOverview ?? this.showOverview,
      seasonOverview: seasonOverview ?? this.seasonOverview,
      airDate: airDate ?? this.airDate,
      stillFile: stillFile ?? this.stillFile,
      showPosterFile: showPosterFile ?? this.showPosterFile,
      userEdited: userEdited ?? this.userEdited,
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
    if (rating.present) {
      map['rating'] = Variable<double>(rating.value);
    }
    if (showOverview.present) {
      map['show_overview'] = Variable<String>(showOverview.value);
    }
    if (seasonOverview.present) {
      map['season_overview'] = Variable<String>(seasonOverview.value);
    }
    if (airDate.present) {
      map['air_date'] = Variable<String>(airDate.value);
    }
    if (stillFile.present) {
      map['still_file'] = Variable<String>(stillFile.value);
    }
    if (showPosterFile.present) {
      map['show_poster_file'] = Variable<String>(showPosterFile.value);
    }
    if (userEdited.present) {
      map['user_edited'] = Variable<bool>(userEdited.value);
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
          ..write('rating: $rating, ')
          ..write('showOverview: $showOverview, ')
          ..write('seasonOverview: $seasonOverview, ')
          ..write('airDate: $airDate, ')
          ..write('stillFile: $stillFile, ')
          ..write('showPosterFile: $showPosterFile, ')
          ..write('userEdited: $userEdited, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $WatchStatesTable extends WatchStates
    with TableInfo<$WatchStatesTable, WatchStateRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $WatchStatesTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _positionMsMeta = const VerificationMeta(
    'positionMs',
  );
  @override
  late final GeneratedColumn<int> positionMs = GeneratedColumn<int>(
    'position_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _durationMsMeta = const VerificationMeta(
    'durationMs',
  );
  @override
  late final GeneratedColumn<int> durationMs = GeneratedColumn<int>(
    'duration_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _completedMeta = const VerificationMeta(
    'completed',
  );
  @override
  late final GeneratedColumn<bool> completed = GeneratedColumn<bool>(
    'completed',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("completed" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    address,
    positionMs,
    durationMs,
    completed,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'watch_states';
  @override
  VerificationContext validateIntegrity(
    Insertable<WatchStateRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('address')) {
      context.handle(
        _addressMeta,
        address.isAcceptableOrUnknown(data['address']!, _addressMeta),
      );
    } else if (isInserting) {
      context.missing(_addressMeta);
    }
    if (data.containsKey('position_ms')) {
      context.handle(
        _positionMsMeta,
        positionMs.isAcceptableOrUnknown(data['position_ms']!, _positionMsMeta),
      );
    } else if (isInserting) {
      context.missing(_positionMsMeta);
    }
    if (data.containsKey('duration_ms')) {
      context.handle(
        _durationMsMeta,
        durationMs.isAcceptableOrUnknown(data['duration_ms']!, _durationMsMeta),
      );
    } else if (isInserting) {
      context.missing(_durationMsMeta);
    }
    if (data.containsKey('completed')) {
      context.handle(
        _completedMeta,
        completed.isAcceptableOrUnknown(data['completed']!, _completedMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {address};
  @override
  WatchStateRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return WatchStateRow(
      address: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}address'],
      )!,
      positionMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}position_ms'],
      )!,
      durationMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}duration_ms'],
      )!,
      completed: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}completed'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $WatchStatesTable createAlias(String alias) {
    return $WatchStatesTable(attachedDatabase, alias);
  }
}

class WatchStateRow extends DataClass implements Insertable<WatchStateRow> {
  /// Normalized XOR address (lowercase, no 0x prefix).
  final String address;
  final int positionMs;

  /// 0 while the player has not reported a duration yet.
  final int durationMs;

  /// Played to (near) the end — drops out of Continue Watching and, for
  /// episodes, promotes the show's next episode instead.
  final bool completed;
  final int updatedAt;
  const WatchStateRow({
    required this.address,
    required this.positionMs,
    required this.durationMs,
    required this.completed,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['address'] = Variable<String>(address);
    map['position_ms'] = Variable<int>(positionMs);
    map['duration_ms'] = Variable<int>(durationMs);
    map['completed'] = Variable<bool>(completed);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  WatchStatesCompanion toCompanion(bool nullToAbsent) {
    return WatchStatesCompanion(
      address: Value(address),
      positionMs: Value(positionMs),
      durationMs: Value(durationMs),
      completed: Value(completed),
      updatedAt: Value(updatedAt),
    );
  }

  factory WatchStateRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return WatchStateRow(
      address: serializer.fromJson<String>(json['address']),
      positionMs: serializer.fromJson<int>(json['positionMs']),
      durationMs: serializer.fromJson<int>(json['durationMs']),
      completed: serializer.fromJson<bool>(json['completed']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'address': serializer.toJson<String>(address),
      'positionMs': serializer.toJson<int>(positionMs),
      'durationMs': serializer.toJson<int>(durationMs),
      'completed': serializer.toJson<bool>(completed),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  WatchStateRow copyWith({
    String? address,
    int? positionMs,
    int? durationMs,
    bool? completed,
    int? updatedAt,
  }) => WatchStateRow(
    address: address ?? this.address,
    positionMs: positionMs ?? this.positionMs,
    durationMs: durationMs ?? this.durationMs,
    completed: completed ?? this.completed,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  WatchStateRow copyWithCompanion(WatchStatesCompanion data) {
    return WatchStateRow(
      address: data.address.present ? data.address.value : this.address,
      positionMs: data.positionMs.present
          ? data.positionMs.value
          : this.positionMs,
      durationMs: data.durationMs.present
          ? data.durationMs.value
          : this.durationMs,
      completed: data.completed.present ? data.completed.value : this.completed,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('WatchStateRow(')
          ..write('address: $address, ')
          ..write('positionMs: $positionMs, ')
          ..write('durationMs: $durationMs, ')
          ..write('completed: $completed, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(address, positionMs, durationMs, completed, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is WatchStateRow &&
          other.address == this.address &&
          other.positionMs == this.positionMs &&
          other.durationMs == this.durationMs &&
          other.completed == this.completed &&
          other.updatedAt == this.updatedAt);
}

class WatchStatesCompanion extends UpdateCompanion<WatchStateRow> {
  final Value<String> address;
  final Value<int> positionMs;
  final Value<int> durationMs;
  final Value<bool> completed;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const WatchStatesCompanion({
    this.address = const Value.absent(),
    this.positionMs = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.completed = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  WatchStatesCompanion.insert({
    required String address,
    required int positionMs,
    required int durationMs,
    this.completed = const Value.absent(),
    required int updatedAt,
    this.rowid = const Value.absent(),
  }) : address = Value(address),
       positionMs = Value(positionMs),
       durationMs = Value(durationMs),
       updatedAt = Value(updatedAt);
  static Insertable<WatchStateRow> custom({
    Expression<String>? address,
    Expression<int>? positionMs,
    Expression<int>? durationMs,
    Expression<bool>? completed,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (address != null) 'address': address,
      if (positionMs != null) 'position_ms': positionMs,
      if (durationMs != null) 'duration_ms': durationMs,
      if (completed != null) 'completed': completed,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  WatchStatesCompanion copyWith({
    Value<String>? address,
    Value<int>? positionMs,
    Value<int>? durationMs,
    Value<bool>? completed,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return WatchStatesCompanion(
      address: address ?? this.address,
      positionMs: positionMs ?? this.positionMs,
      durationMs: durationMs ?? this.durationMs,
      completed: completed ?? this.completed,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (address.present) {
      map['address'] = Variable<String>(address.value);
    }
    if (positionMs.present) {
      map['position_ms'] = Variable<int>(positionMs.value);
    }
    if (durationMs.present) {
      map['duration_ms'] = Variable<int>(durationMs.value);
    }
    if (completed.present) {
      map['completed'] = Variable<bool>(completed.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('WatchStatesCompanion(')
          ..write('address: $address, ')
          ..write('positionMs: $positionMs, ')
          ..write('durationMs: $durationMs, ')
          ..write('completed: $completed, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $DownloadsTable extends Downloads
    with TableInfo<$DownloadsTable, DownloadRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DownloadsTable(this.attachedDatabase, [this._alias]);
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
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _filePathMeta = const VerificationMeta(
    'filePath',
  );
  @override
  late final GeneratedColumn<String> filePath = GeneratedColumn<String>(
    'file_path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _totalBytesMeta = const VerificationMeta(
    'totalBytes',
  );
  @override
  late final GeneratedColumn<int> totalBytes = GeneratedColumn<int>(
    'total_bytes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _downloadedBytesMeta = const VerificationMeta(
    'downloadedBytes',
  );
  @override
  late final GeneratedColumn<int> downloadedBytes = GeneratedColumn<int>(
    'downloaded_bytes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _errorMeta = const VerificationMeta('error');
  @override
  late final GeneratedColumn<String> error = GeneratedColumn<String>(
    'error',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _pausedBySystemMeta = const VerificationMeta(
    'pausedBySystem',
  );
  @override
  late final GeneratedColumn<bool> pausedBySystem = GeneratedColumn<bool>(
    'paused_by_system',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("paused_by_system" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    address,
    name,
    filePath,
    totalBytes,
    downloadedBytes,
    status,
    error,
    pausedBySystem,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'downloads';
  @override
  VerificationContext validateIntegrity(
    Insertable<DownloadRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('address')) {
      context.handle(
        _addressMeta,
        address.isAcceptableOrUnknown(data['address']!, _addressMeta),
      );
    } else if (isInserting) {
      context.missing(_addressMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('file_path')) {
      context.handle(
        _filePathMeta,
        filePath.isAcceptableOrUnknown(data['file_path']!, _filePathMeta),
      );
    } else if (isInserting) {
      context.missing(_filePathMeta);
    }
    if (data.containsKey('total_bytes')) {
      context.handle(
        _totalBytesMeta,
        totalBytes.isAcceptableOrUnknown(data['total_bytes']!, _totalBytesMeta),
      );
    }
    if (data.containsKey('downloaded_bytes')) {
      context.handle(
        _downloadedBytesMeta,
        downloadedBytes.isAcceptableOrUnknown(
          data['downloaded_bytes']!,
          _downloadedBytesMeta,
        ),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    if (data.containsKey('error')) {
      context.handle(
        _errorMeta,
        error.isAcceptableOrUnknown(data['error']!, _errorMeta),
      );
    }
    if (data.containsKey('paused_by_system')) {
      context.handle(
        _pausedBySystemMeta,
        pausedBySystem.isAcceptableOrUnknown(
          data['paused_by_system']!,
          _pausedBySystemMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {address};
  @override
  DownloadRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DownloadRow(
      address: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}address'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      filePath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}file_path'],
      )!,
      totalBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}total_bytes'],
      )!,
      downloadedBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}downloaded_bytes'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      error: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}error'],
      ),
      pausedBySystem: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}paused_by_system'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $DownloadsTable createAlias(String alias) {
    return $DownloadsTable(attachedDatabase, alias);
  }
}

class DownloadRow extends DataClass implements Insertable<DownloadRow> {
  /// Normalized XOR address (lowercase, no 0x prefix).
  final String address;

  /// File name at enqueue time (shown in the downloads queue).
  final String name;

  /// Absolute path of the (possibly partial) file on disk.
  final String filePath;

  /// 0 until the size is known (from /resolve or the response headers).
  final int totalBytes;
  final int downloadedBytes;

  /// `queued` | `downloading` | `paused` | `done` | `error`.
  final String status;
  final String? error;

  /// Paused by the app (connection loss, waiting for Wi-Fi), not by the
  /// user — these auto-resume when the blocking condition clears, also
  /// across an app restart. Any user action clears the flag.
  final bool pausedBySystem;
  final int createdAt;
  final int updatedAt;
  const DownloadRow({
    required this.address,
    required this.name,
    required this.filePath,
    required this.totalBytes,
    required this.downloadedBytes,
    required this.status,
    this.error,
    required this.pausedBySystem,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['address'] = Variable<String>(address);
    map['name'] = Variable<String>(name);
    map['file_path'] = Variable<String>(filePath);
    map['total_bytes'] = Variable<int>(totalBytes);
    map['downloaded_bytes'] = Variable<int>(downloadedBytes);
    map['status'] = Variable<String>(status);
    if (!nullToAbsent || error != null) {
      map['error'] = Variable<String>(error);
    }
    map['paused_by_system'] = Variable<bool>(pausedBySystem);
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  DownloadsCompanion toCompanion(bool nullToAbsent) {
    return DownloadsCompanion(
      address: Value(address),
      name: Value(name),
      filePath: Value(filePath),
      totalBytes: Value(totalBytes),
      downloadedBytes: Value(downloadedBytes),
      status: Value(status),
      error: error == null && nullToAbsent
          ? const Value.absent()
          : Value(error),
      pausedBySystem: Value(pausedBySystem),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory DownloadRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DownloadRow(
      address: serializer.fromJson<String>(json['address']),
      name: serializer.fromJson<String>(json['name']),
      filePath: serializer.fromJson<String>(json['filePath']),
      totalBytes: serializer.fromJson<int>(json['totalBytes']),
      downloadedBytes: serializer.fromJson<int>(json['downloadedBytes']),
      status: serializer.fromJson<String>(json['status']),
      error: serializer.fromJson<String?>(json['error']),
      pausedBySystem: serializer.fromJson<bool>(json['pausedBySystem']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'address': serializer.toJson<String>(address),
      'name': serializer.toJson<String>(name),
      'filePath': serializer.toJson<String>(filePath),
      'totalBytes': serializer.toJson<int>(totalBytes),
      'downloadedBytes': serializer.toJson<int>(downloadedBytes),
      'status': serializer.toJson<String>(status),
      'error': serializer.toJson<String?>(error),
      'pausedBySystem': serializer.toJson<bool>(pausedBySystem),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  DownloadRow copyWith({
    String? address,
    String? name,
    String? filePath,
    int? totalBytes,
    int? downloadedBytes,
    String? status,
    Value<String?> error = const Value.absent(),
    bool? pausedBySystem,
    int? createdAt,
    int? updatedAt,
  }) => DownloadRow(
    address: address ?? this.address,
    name: name ?? this.name,
    filePath: filePath ?? this.filePath,
    totalBytes: totalBytes ?? this.totalBytes,
    downloadedBytes: downloadedBytes ?? this.downloadedBytes,
    status: status ?? this.status,
    error: error.present ? error.value : this.error,
    pausedBySystem: pausedBySystem ?? this.pausedBySystem,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  DownloadRow copyWithCompanion(DownloadsCompanion data) {
    return DownloadRow(
      address: data.address.present ? data.address.value : this.address,
      name: data.name.present ? data.name.value : this.name,
      filePath: data.filePath.present ? data.filePath.value : this.filePath,
      totalBytes: data.totalBytes.present
          ? data.totalBytes.value
          : this.totalBytes,
      downloadedBytes: data.downloadedBytes.present
          ? data.downloadedBytes.value
          : this.downloadedBytes,
      status: data.status.present ? data.status.value : this.status,
      error: data.error.present ? data.error.value : this.error,
      pausedBySystem: data.pausedBySystem.present
          ? data.pausedBySystem.value
          : this.pausedBySystem,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DownloadRow(')
          ..write('address: $address, ')
          ..write('name: $name, ')
          ..write('filePath: $filePath, ')
          ..write('totalBytes: $totalBytes, ')
          ..write('downloadedBytes: $downloadedBytes, ')
          ..write('status: $status, ')
          ..write('error: $error, ')
          ..write('pausedBySystem: $pausedBySystem, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    address,
    name,
    filePath,
    totalBytes,
    downloadedBytes,
    status,
    error,
    pausedBySystem,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DownloadRow &&
          other.address == this.address &&
          other.name == this.name &&
          other.filePath == this.filePath &&
          other.totalBytes == this.totalBytes &&
          other.downloadedBytes == this.downloadedBytes &&
          other.status == this.status &&
          other.error == this.error &&
          other.pausedBySystem == this.pausedBySystem &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class DownloadsCompanion extends UpdateCompanion<DownloadRow> {
  final Value<String> address;
  final Value<String> name;
  final Value<String> filePath;
  final Value<int> totalBytes;
  final Value<int> downloadedBytes;
  final Value<String> status;
  final Value<String?> error;
  final Value<bool> pausedBySystem;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const DownloadsCompanion({
    this.address = const Value.absent(),
    this.name = const Value.absent(),
    this.filePath = const Value.absent(),
    this.totalBytes = const Value.absent(),
    this.downloadedBytes = const Value.absent(),
    this.status = const Value.absent(),
    this.error = const Value.absent(),
    this.pausedBySystem = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  DownloadsCompanion.insert({
    required String address,
    required String name,
    required String filePath,
    this.totalBytes = const Value.absent(),
    this.downloadedBytes = const Value.absent(),
    required String status,
    this.error = const Value.absent(),
    this.pausedBySystem = const Value.absent(),
    required int createdAt,
    required int updatedAt,
    this.rowid = const Value.absent(),
  }) : address = Value(address),
       name = Value(name),
       filePath = Value(filePath),
       status = Value(status),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<DownloadRow> custom({
    Expression<String>? address,
    Expression<String>? name,
    Expression<String>? filePath,
    Expression<int>? totalBytes,
    Expression<int>? downloadedBytes,
    Expression<String>? status,
    Expression<String>? error,
    Expression<bool>? pausedBySystem,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (address != null) 'address': address,
      if (name != null) 'name': name,
      if (filePath != null) 'file_path': filePath,
      if (totalBytes != null) 'total_bytes': totalBytes,
      if (downloadedBytes != null) 'downloaded_bytes': downloadedBytes,
      if (status != null) 'status': status,
      if (error != null) 'error': error,
      if (pausedBySystem != null) 'paused_by_system': pausedBySystem,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  DownloadsCompanion copyWith({
    Value<String>? address,
    Value<String>? name,
    Value<String>? filePath,
    Value<int>? totalBytes,
    Value<int>? downloadedBytes,
    Value<String>? status,
    Value<String?>? error,
    Value<bool>? pausedBySystem,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return DownloadsCompanion(
      address: address ?? this.address,
      name: name ?? this.name,
      filePath: filePath ?? this.filePath,
      totalBytes: totalBytes ?? this.totalBytes,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      status: status ?? this.status,
      error: error ?? this.error,
      pausedBySystem: pausedBySystem ?? this.pausedBySystem,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (address.present) {
      map['address'] = Variable<String>(address.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (filePath.present) {
      map['file_path'] = Variable<String>(filePath.value);
    }
    if (totalBytes.present) {
      map['total_bytes'] = Variable<int>(totalBytes.value);
    }
    if (downloadedBytes.present) {
      map['downloaded_bytes'] = Variable<int>(downloadedBytes.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (error.present) {
      map['error'] = Variable<String>(error.value);
    }
    if (pausedBySystem.present) {
      map['paused_by_system'] = Variable<bool>(pausedBySystem.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DownloadsCompanion(')
          ..write('address: $address, ')
          ..write('name: $name, ')
          ..write('filePath: $filePath, ')
          ..write('totalBytes: $totalBytes, ')
          ..write('downloadedBytes: $downloadedBytes, ')
          ..write('status: $status, ')
          ..write('error: $error, ')
          ..write('pausedBySystem: $pausedBySystem, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
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
  late final $WatchStatesTable watchStates = $WatchStatesTable(this);
  late final $DownloadsTable downloads = $DownloadsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    mediaLists,
    mediaEntries,
    metadataCache,
    watchStates,
    downloads,
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
      Value<String?> channelPubkey,
      Value<int> rowid,
    });
typedef $$MediaListsTableUpdateCompanionBuilder =
    MediaListsCompanion Function({
      Value<String> id,
      Value<String> title,
      Value<int> position,
      Value<bool> enabled,
      Value<String?> channelPubkey,
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

  ColumnFilters<String> get channelPubkey => $composableBuilder(
    column: $table.channelPubkey,
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

  ColumnOrderings<String> get channelPubkey => $composableBuilder(
    column: $table.channelPubkey,
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

  GeneratedColumn<String> get channelPubkey => $composableBuilder(
    column: $table.channelPubkey,
    builder: (column) => column,
  );

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
                Value<String?> channelPubkey = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MediaListsCompanion(
                id: id,
                title: title,
                position: position,
                enabled: enabled,
                channelPubkey: channelPubkey,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String title,
                required int position,
                Value<bool> enabled = const Value.absent(),
                Value<String?> channelPubkey = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MediaListsCompanion.insert(
                id: id,
                title: title,
                position: position,
                enabled: enabled,
                channelPubkey: channelPubkey,
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
      Value<int> addedAt,
      Value<int?> sizeBytes,
      Value<String?> videoInfo,
    });
typedef $$MediaEntriesTableUpdateCompanionBuilder =
    MediaEntriesCompanion Function({
      Value<int> entryId,
      Value<String> listId,
      Value<String> name,
      Value<String> address,
      Value<int> position,
      Value<int> addedAt,
      Value<int?> sizeBytes,
      Value<String?> videoInfo,
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

  ColumnFilters<int> get addedAt => $composableBuilder(
    column: $table.addedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sizeBytes => $composableBuilder(
    column: $table.sizeBytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get videoInfo => $composableBuilder(
    column: $table.videoInfo,
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

  ColumnOrderings<int> get addedAt => $composableBuilder(
    column: $table.addedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sizeBytes => $composableBuilder(
    column: $table.sizeBytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get videoInfo => $composableBuilder(
    column: $table.videoInfo,
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

  GeneratedColumn<int> get addedAt =>
      $composableBuilder(column: $table.addedAt, builder: (column) => column);

  GeneratedColumn<int> get sizeBytes =>
      $composableBuilder(column: $table.sizeBytes, builder: (column) => column);

  GeneratedColumn<String> get videoInfo =>
      $composableBuilder(column: $table.videoInfo, builder: (column) => column);

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
                Value<int> addedAt = const Value.absent(),
                Value<int?> sizeBytes = const Value.absent(),
                Value<String?> videoInfo = const Value.absent(),
              }) => MediaEntriesCompanion(
                entryId: entryId,
                listId: listId,
                name: name,
                address: address,
                position: position,
                addedAt: addedAt,
                sizeBytes: sizeBytes,
                videoInfo: videoInfo,
              ),
          createCompanionCallback:
              ({
                Value<int> entryId = const Value.absent(),
                required String listId,
                required String name,
                required String address,
                required int position,
                Value<int> addedAt = const Value.absent(),
                Value<int?> sizeBytes = const Value.absent(),
                Value<String?> videoInfo = const Value.absent(),
              }) => MediaEntriesCompanion.insert(
                entryId: entryId,
                listId: listId,
                name: name,
                address: address,
                position: position,
                addedAt: addedAt,
                sizeBytes: sizeBytes,
                videoInfo: videoInfo,
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
      Value<double?> rating,
      Value<String?> showOverview,
      Value<String?> seasonOverview,
      Value<String?> airDate,
      Value<String?> stillFile,
      Value<String?> showPosterFile,
      Value<bool> userEdited,
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
      Value<double?> rating,
      Value<String?> showOverview,
      Value<String?> seasonOverview,
      Value<String?> airDate,
      Value<String?> stillFile,
      Value<String?> showPosterFile,
      Value<bool> userEdited,
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

  ColumnFilters<double> get rating => $composableBuilder(
    column: $table.rating,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get showOverview => $composableBuilder(
    column: $table.showOverview,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get seasonOverview => $composableBuilder(
    column: $table.seasonOverview,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get airDate => $composableBuilder(
    column: $table.airDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get stillFile => $composableBuilder(
    column: $table.stillFile,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get showPosterFile => $composableBuilder(
    column: $table.showPosterFile,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get userEdited => $composableBuilder(
    column: $table.userEdited,
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

  ColumnOrderings<double> get rating => $composableBuilder(
    column: $table.rating,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get showOverview => $composableBuilder(
    column: $table.showOverview,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get seasonOverview => $composableBuilder(
    column: $table.seasonOverview,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get airDate => $composableBuilder(
    column: $table.airDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get stillFile => $composableBuilder(
    column: $table.stillFile,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get showPosterFile => $composableBuilder(
    column: $table.showPosterFile,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get userEdited => $composableBuilder(
    column: $table.userEdited,
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

  GeneratedColumn<double> get rating =>
      $composableBuilder(column: $table.rating, builder: (column) => column);

  GeneratedColumn<String> get showOverview => $composableBuilder(
    column: $table.showOverview,
    builder: (column) => column,
  );

  GeneratedColumn<String> get seasonOverview => $composableBuilder(
    column: $table.seasonOverview,
    builder: (column) => column,
  );

  GeneratedColumn<String> get airDate =>
      $composableBuilder(column: $table.airDate, builder: (column) => column);

  GeneratedColumn<String> get stillFile =>
      $composableBuilder(column: $table.stillFile, builder: (column) => column);

  GeneratedColumn<String> get showPosterFile => $composableBuilder(
    column: $table.showPosterFile,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get userEdited => $composableBuilder(
    column: $table.userEdited,
    builder: (column) => column,
  );
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
                Value<double?> rating = const Value.absent(),
                Value<String?> showOverview = const Value.absent(),
                Value<String?> seasonOverview = const Value.absent(),
                Value<String?> airDate = const Value.absent(),
                Value<String?> stillFile = const Value.absent(),
                Value<String?> showPosterFile = const Value.absent(),
                Value<bool> userEdited = const Value.absent(),
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
                rating: rating,
                showOverview: showOverview,
                seasonOverview: seasonOverview,
                airDate: airDate,
                stillFile: stillFile,
                showPosterFile: showPosterFile,
                userEdited: userEdited,
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
                Value<double?> rating = const Value.absent(),
                Value<String?> showOverview = const Value.absent(),
                Value<String?> seasonOverview = const Value.absent(),
                Value<String?> airDate = const Value.absent(),
                Value<String?> stillFile = const Value.absent(),
                Value<String?> showPosterFile = const Value.absent(),
                Value<bool> userEdited = const Value.absent(),
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
                rating: rating,
                showOverview: showOverview,
                seasonOverview: seasonOverview,
                airDate: airDate,
                stillFile: stillFile,
                showPosterFile: showPosterFile,
                userEdited: userEdited,
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
typedef $$WatchStatesTableCreateCompanionBuilder =
    WatchStatesCompanion Function({
      required String address,
      required int positionMs,
      required int durationMs,
      Value<bool> completed,
      required int updatedAt,
      Value<int> rowid,
    });
typedef $$WatchStatesTableUpdateCompanionBuilder =
    WatchStatesCompanion Function({
      Value<String> address,
      Value<int> positionMs,
      Value<int> durationMs,
      Value<bool> completed,
      Value<int> updatedAt,
      Value<int> rowid,
    });

class $$WatchStatesTableFilterComposer
    extends Composer<_$AppDatabase, $WatchStatesTable> {
  $$WatchStatesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get address => $composableBuilder(
    column: $table.address,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get positionMs => $composableBuilder(
    column: $table.positionMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get completed => $composableBuilder(
    column: $table.completed,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$WatchStatesTableOrderingComposer
    extends Composer<_$AppDatabase, $WatchStatesTable> {
  $$WatchStatesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get address => $composableBuilder(
    column: $table.address,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get positionMs => $composableBuilder(
    column: $table.positionMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get completed => $composableBuilder(
    column: $table.completed,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$WatchStatesTableAnnotationComposer
    extends Composer<_$AppDatabase, $WatchStatesTable> {
  $$WatchStatesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get address =>
      $composableBuilder(column: $table.address, builder: (column) => column);

  GeneratedColumn<int> get positionMs => $composableBuilder(
    column: $table.positionMs,
    builder: (column) => column,
  );

  GeneratedColumn<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get completed =>
      $composableBuilder(column: $table.completed, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$WatchStatesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $WatchStatesTable,
          WatchStateRow,
          $$WatchStatesTableFilterComposer,
          $$WatchStatesTableOrderingComposer,
          $$WatchStatesTableAnnotationComposer,
          $$WatchStatesTableCreateCompanionBuilder,
          $$WatchStatesTableUpdateCompanionBuilder,
          (
            WatchStateRow,
            BaseReferences<_$AppDatabase, $WatchStatesTable, WatchStateRow>,
          ),
          WatchStateRow,
          PrefetchHooks Function()
        > {
  $$WatchStatesTableTableManager(_$AppDatabase db, $WatchStatesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$WatchStatesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$WatchStatesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$WatchStatesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> address = const Value.absent(),
                Value<int> positionMs = const Value.absent(),
                Value<int> durationMs = const Value.absent(),
                Value<bool> completed = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => WatchStatesCompanion(
                address: address,
                positionMs: positionMs,
                durationMs: durationMs,
                completed: completed,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String address,
                required int positionMs,
                required int durationMs,
                Value<bool> completed = const Value.absent(),
                required int updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => WatchStatesCompanion.insert(
                address: address,
                positionMs: positionMs,
                durationMs: durationMs,
                completed: completed,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$WatchStatesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $WatchStatesTable,
      WatchStateRow,
      $$WatchStatesTableFilterComposer,
      $$WatchStatesTableOrderingComposer,
      $$WatchStatesTableAnnotationComposer,
      $$WatchStatesTableCreateCompanionBuilder,
      $$WatchStatesTableUpdateCompanionBuilder,
      (
        WatchStateRow,
        BaseReferences<_$AppDatabase, $WatchStatesTable, WatchStateRow>,
      ),
      WatchStateRow,
      PrefetchHooks Function()
    >;
typedef $$DownloadsTableCreateCompanionBuilder =
    DownloadsCompanion Function({
      required String address,
      required String name,
      required String filePath,
      Value<int> totalBytes,
      Value<int> downloadedBytes,
      required String status,
      Value<String?> error,
      Value<bool> pausedBySystem,
      required int createdAt,
      required int updatedAt,
      Value<int> rowid,
    });
typedef $$DownloadsTableUpdateCompanionBuilder =
    DownloadsCompanion Function({
      Value<String> address,
      Value<String> name,
      Value<String> filePath,
      Value<int> totalBytes,
      Value<int> downloadedBytes,
      Value<String> status,
      Value<String?> error,
      Value<bool> pausedBySystem,
      Value<int> createdAt,
      Value<int> updatedAt,
      Value<int> rowid,
    });

class $$DownloadsTableFilterComposer
    extends Composer<_$AppDatabase, $DownloadsTable> {
  $$DownloadsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get address => $composableBuilder(
    column: $table.address,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get filePath => $composableBuilder(
    column: $table.filePath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get totalBytes => $composableBuilder(
    column: $table.totalBytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get downloadedBytes => $composableBuilder(
    column: $table.downloadedBytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get error => $composableBuilder(
    column: $table.error,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get pausedBySystem => $composableBuilder(
    column: $table.pausedBySystem,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$DownloadsTableOrderingComposer
    extends Composer<_$AppDatabase, $DownloadsTable> {
  $$DownloadsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get address => $composableBuilder(
    column: $table.address,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get filePath => $composableBuilder(
    column: $table.filePath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get totalBytes => $composableBuilder(
    column: $table.totalBytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get downloadedBytes => $composableBuilder(
    column: $table.downloadedBytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get error => $composableBuilder(
    column: $table.error,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get pausedBySystem => $composableBuilder(
    column: $table.pausedBySystem,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$DownloadsTableAnnotationComposer
    extends Composer<_$AppDatabase, $DownloadsTable> {
  $$DownloadsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get address =>
      $composableBuilder(column: $table.address, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get filePath =>
      $composableBuilder(column: $table.filePath, builder: (column) => column);

  GeneratedColumn<int> get totalBytes => $composableBuilder(
    column: $table.totalBytes,
    builder: (column) => column,
  );

  GeneratedColumn<int> get downloadedBytes => $composableBuilder(
    column: $table.downloadedBytes,
    builder: (column) => column,
  );

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<String> get error =>
      $composableBuilder(column: $table.error, builder: (column) => column);

  GeneratedColumn<bool> get pausedBySystem => $composableBuilder(
    column: $table.pausedBySystem,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$DownloadsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $DownloadsTable,
          DownloadRow,
          $$DownloadsTableFilterComposer,
          $$DownloadsTableOrderingComposer,
          $$DownloadsTableAnnotationComposer,
          $$DownloadsTableCreateCompanionBuilder,
          $$DownloadsTableUpdateCompanionBuilder,
          (
            DownloadRow,
            BaseReferences<_$AppDatabase, $DownloadsTable, DownloadRow>,
          ),
          DownloadRow,
          PrefetchHooks Function()
        > {
  $$DownloadsTableTableManager(_$AppDatabase db, $DownloadsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DownloadsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DownloadsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DownloadsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> address = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> filePath = const Value.absent(),
                Value<int> totalBytes = const Value.absent(),
                Value<int> downloadedBytes = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<String?> error = const Value.absent(),
                Value<bool> pausedBySystem = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => DownloadsCompanion(
                address: address,
                name: name,
                filePath: filePath,
                totalBytes: totalBytes,
                downloadedBytes: downloadedBytes,
                status: status,
                error: error,
                pausedBySystem: pausedBySystem,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String address,
                required String name,
                required String filePath,
                Value<int> totalBytes = const Value.absent(),
                Value<int> downloadedBytes = const Value.absent(),
                required String status,
                Value<String?> error = const Value.absent(),
                Value<bool> pausedBySystem = const Value.absent(),
                required int createdAt,
                required int updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => DownloadsCompanion.insert(
                address: address,
                name: name,
                filePath: filePath,
                totalBytes: totalBytes,
                downloadedBytes: downloadedBytes,
                status: status,
                error: error,
                pausedBySystem: pausedBySystem,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$DownloadsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $DownloadsTable,
      DownloadRow,
      $$DownloadsTableFilterComposer,
      $$DownloadsTableOrderingComposer,
      $$DownloadsTableAnnotationComposer,
      $$DownloadsTableCreateCompanionBuilder,
      $$DownloadsTableUpdateCompanionBuilder,
      (
        DownloadRow,
        BaseReferences<_$AppDatabase, $DownloadsTable, DownloadRow>,
      ),
      DownloadRow,
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
  $$WatchStatesTableTableManager get watchStates =>
      $$WatchStatesTableTableManager(_db, _db.watchStates);
  $$DownloadsTableTableManager get downloads =>
      $$DownloadsTableTableManager(_db, _db.downloads);
}
