import 'dart:convert';

import 'package:flutter/services.dart';

/// Documented public atlas — https://skaists.dev/surfaces/
/// Registry source of truth: https://skaists.dev/estate.json (v1).
const kSkaistsAtlasUrl = 'https://skaists.dev/surfaces/';
const kSkaistsEstateJsonUrl = 'https://skaists.dev/estate.json';
const kSkaistsEstateAsset = 'assets/skaists_estate.json';
const kSkaistsPublicOrigin = 'https://skaists.dev/';

/// One LIVE card from the skaists.dev/surfaces atlas.
class SkaistsSurface {
  const SkaistsSurface({
    required this.id,
    required this.family,
    required this.org,
    required this.path,
    required this.state,
    this.home,
    this.gloss,
    this.label,
  });

  final String id;
  final String family;
  final String org;
  final String path;
  final String state;
  final String? home;
  final String? gloss;
  final String? label;

  /// Title on the card — atlas `label` when present, else the id.
  String get title => (label != null && label!.isNotEmpty) ? label! : id;

  /// Documented public URL on skaists.dev, never a guessed shortlist host.
  Uri get publicUrl => Uri.parse('$kSkaistsPublicOrigin$path');

  bool get isLive => state == 'LIVE';

  factory SkaistsSurface.fromJson(Map<String, dynamic> json) {
    return SkaistsSurface(
      id: json['id'] as String,
      family: json['family'] as String,
      org: json['org'] as String? ?? '',
      path: json['path'] as String,
      state: json['state'] as String? ?? '',
      home: json['home'] as String?,
      gloss: json['gloss'] as String?,
      label: json['label'] as String?,
    );
  }
}

/// Full estate atlas. Families and cards come from the committed
/// [kSkaistsEstateAsset] snapshot of estate.json v1 — not a hand list.
class SkaistsEstate {
  const SkaistsEstate({
    required this.families,
    required this.surfaces,
    required this.generated,
  });

  final List<String> families;
  final List<SkaistsSurface> surfaces;
  final String generated;

  static SkaistsEstate? _cached;

  /// Atlas family slugs in hub order (beehive-nature / biomass / bnr…).
  static const familyOrder = [
    'beehivenature',
    'plur',
    'skaists',
    'bnature',
    'beehivebiomass',
    'beehivebuds',
    'midi',
    'bnr',
  ];

  static String familyLabel(String family) => switch (family) {
        'beehivenature' => 'beehive-nature',
        'beehivebiomass' => 'beehive-biomass',
        'beehivebuds' => 'beehive-buds',
        _ => family,
      };

  List<SkaistsSurface> ofFamily(String family) =>
      surfaces.where((s) => s.family == family).toList(growable: false);

  static SkaistsEstate parse(String source) {
    final json = jsonDecode(source) as Map<String, dynamic>;
    final familyList = (json['families'] as List<dynamic>? ?? const [])
        .map((e) => e as String)
        .toList(growable: false);
    final listed = (json['surfaces'] as List<dynamic>? ?? const [])
        .map((e) => SkaistsSurface.fromJson(e as Map<String, dynamic>))
        .where((s) => s.isLive && s.path.startsWith('surfaces/'))
        .toList(growable: false);
    return SkaistsEstate(
      families: familyList.isEmpty ? familyOrder : familyList,
      surfaces: listed,
      generated: json['generated'] as String? ?? '',
    );
  }

  static Future<SkaistsEstate> load() async {
    if (_cached != null) return _cached!;
    final raw = await rootBundle.loadString(kSkaistsEstateAsset);
    return _cached = parse(raw);
  }

  /// Test hook — drop the process-wide cache.
  static void resetCache() => _cached = null;
}
