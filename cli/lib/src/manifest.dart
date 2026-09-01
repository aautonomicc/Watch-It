import 'dart:io';

import 'package:yaml/yaml.dart';

import 'yaml_write.dart';

/// Entry lifecycle: `prepare` writes `ready` / `already-uploaded` /
/// `needs-attention` / `skipped`; `upload` moves `ready` → `uploaded` or
/// `failed` (retried on the end-of-run retry pass and on re-runs).
/// Editing the manifest between phases is a supported override point —
/// fix a name, change a status, point `art` at a better cover.
class ManifestEntry {
  ManifestEntry({
    required this.source,
    required this.status,
    this.sha256,
    this.sizeBytes,
    this.type,
    this.name,
    this.ids = const {},
    this.matchMethod,
    this.confidence,
    this.art,
    this.description,
    this.custom = false,
    this.customFields = const {},
    this.address,
    this.datamap,
    this.uploadedAt,
    this.verified,
    this.error,
  });

  final String source;
  String status;
  String? sha256;
  int? sizeBytes;

  /// `music` or `video`.
  String? type;

  /// Final canonical W@tch name (upload name = datamap member name).
  String? name;

  /// Database ids backing the name: `release_mbid`, `recording_mbid`,
  /// `imdb`, `tmdb`.
  Map<String, String> ids;
  String? matchMethod;
  String? confidence;

  /// Local path of fetched artwork (cover/poster) — match verification
  /// during prepare, bundle poster for custom items.
  String? art;

  /// Case-B description (rides the bundle as a userEdited metadata row).
  String? description;

  /// Case B: not in any database — no id tag in the name, metadata baked
  /// into the bundle instead.
  bool custom;

  /// Case-B row fields (title/year/artist/album/season/episode …).
  Map<String, Object?> customFields;

  String? address;
  String? datamap;
  String? uploadedAt;
  bool? verified;
  String? error;

  Map<String, Object?> toMap() => {
        'source': source,
        'status': status,
        if (sha256 != null) 'sha256': sha256,
        if (sizeBytes != null) 'size_bytes': sizeBytes,
        if (type != null) 'type': type,
        if (name != null) 'name': name,
        if (ids.isNotEmpty) 'ids': ids,
        if (matchMethod != null) 'match_method': matchMethod,
        if (confidence != null) 'confidence': confidence,
        if (art != null) 'art': art,
        if (description != null) 'description': description,
        if (custom) 'custom': true,
        if (customFields.isNotEmpty) 'custom_fields': customFields,
        if (address != null) 'address': address,
        if (datamap != null) 'datamap': datamap,
        if (uploadedAt != null) 'uploaded_at': uploadedAt,
        if (verified != null) 'verified': verified,
        if (error != null) 'error': error,
      };

  static ManifestEntry fromMap(Map<Object?, Object?> m) => ManifestEntry(
        source: '${m['source']}',
        status: '${m['status'] ?? 'needs-attention'}',
        sha256: m['sha256']?.toString(),
        sizeBytes: (m['size_bytes'] as num?)?.toInt(),
        type: m['type']?.toString(),
        name: m['name']?.toString(),
        ids: {
          if (m['ids'] is Map)
            for (final e in (m['ids'] as Map).entries)
              '${e.key}': '${e.value}',
        },
        matchMethod: m['match_method']?.toString(),
        confidence: m['confidence']?.toString(),
        art: m['art']?.toString(),
        description: m['description']?.toString(),
        custom: m['custom'] == true,
        customFields: {
          if (m['custom_fields'] is Map)
            for (final e in (m['custom_fields'] as Map).entries)
              '${e.key}': e.value,
        },
        address: m['address']?.toString(),
        datamap: m['datamap']?.toString(),
        uploadedAt: m['uploaded_at']?.toString(),
        verified: m['verified'] as bool?,
        error: m['error']?.toString(),
      );
}

class Manifest {
  Manifest({
    required this.file,
    required this.listName,
    this.created,
    this.entries = const [],
    this.cost = const {},
  });

  final File file;
  String listName;
  String? created;
  List<ManifestEntry> entries;

  /// Cost block from prepare: estimated totals + wallet state at the
  /// time, so payment surprises can't kill an overnight run.
  Map<String, Object?> cost;

  ManifestEntry? bySource(String source) {
    for (final e in entries) {
      if (e.source == source) return e;
    }
    return null;
  }

  static Manifest load(File file) {
    final doc = loadYaml(file.readAsStringSync());
    if (doc is! YamlMap) {
      throw FormatException('not a manifest: ${file.path}');
    }
    return Manifest(
      file: file,
      listName: '${doc['list_name'] ?? 'Uploads'}',
      created: doc['created']?.toString(),
      cost: {
        if (doc['cost'] is Map)
          for (final e in (doc['cost'] as Map).entries) '${e.key}': e.value,
      },
      entries: [
        for (final raw in doc['entries'] as YamlList? ?? const [])
          if (raw is Map) ManifestEntry.fromMap(raw.cast<Object?, Object?>()),
      ],
    );
  }

  /// Saved after every state change during upload — the manifest on disk
  /// is the resume point after a crash or network drop.
  void save() {
    file.writeAsStringSync(yamlDocument({
      'version': 1,
      'list_name': listName,
      if (created != null) 'created': created,
      if (cost.isNotEmpty) 'cost': cost,
      'entries': [for (final e in entries) e.toMap()],
    }));
  }
}
