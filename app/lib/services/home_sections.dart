import 'dart:convert';

import '../models/media_list.dart';

/// Stable ids for the four built-in home rows. Media-list rows use
/// [listSectionId] so the one ordered sequence can interleave both kinds.
const kSectionContinue = 'continue';
const kSectionFavourites = 'favourites';
const kSectionDownloads = 'downloads';
const kSectionRecent = 'recent';
const kSpecialSectionIds = [
  kSectionContinue,
  kSectionFavourites,
  kSectionDownloads,
  kSectionRecent,
];

String listSectionId(String listId) => 'list:$listId';

/// One home row in the user's configured order.
///
/// Visibility of the three special rows lives here (persisted under
/// `home_sections_v1`); visibility of list rows stays on
/// [MediaList.enabled] — the single source of truth shared with the
/// Media Lists screen — and is only mirrored into [visible] by
/// [reconcileHomeSections] for uniform rendering.
class HomeSection {
  const HomeSection({required this.id, this.visible = true});

  final String id;
  final bool visible;

  bool get isSpecial => kSpecialSectionIds.contains(id);

  /// The media-list id for `list:<id>` sections, null for special rows.
  String? get listId => id.startsWith('list:') ? id.substring(5) : null;

  HomeSection copyWith({bool? visible}) =>
      HomeSection(id: id, visible: visible ?? this.visible);

  String get title => switch (id) {
        kSectionContinue => 'Continue Watching',
        kSectionFavourites => 'Favourites',
        kSectionDownloads => 'Downloads',
        kSectionRecent => 'Recently Added',
        _ => id,
      };
}

String encodeHomeSections(List<HomeSection> sections) => jsonEncode([
      for (final s in sections) {'id': s.id, 'visible': s.visible},
    ]);

/// Tolerant decode: a corrupt or empty blob yields [] (= use defaults).
List<HomeSection> decodeHomeSections(String raw) {
  if (raw.trim().isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return [
      for (final e in decoded)
        if (e is Map<String, dynamic> && e['id'] is String)
          HomeSection(
            id: e['id'] as String,
            visible: e['visible'] as bool? ?? true,
          ),
    ];
  } on FormatException {
    return const [];
  }
}

/// Reconciles a stored order against the current lists:
/// - stored ids whose list no longer exists are dropped;
/// - lists not in the stored order are appended at the end (in their
///   library position order), as are special rows a stale blob lacks;
/// - nothing stored → default order: continue, favourites, downloads,
///   recent, then lists — exactly the pre-customization layout;
/// - list rows always report [MediaList.enabled] as their visibility.
List<HomeSection> reconcileHomeSections(
  List<HomeSection> stored,
  List<MediaList> lists,
) {
  final listsById = {for (final l in lists) listSectionId(l.id): l};
  final out = <HomeSection>[];
  final seen = <String>{};
  for (final s in stored) {
    if (!seen.add(s.id)) continue;
    if (s.isSpecial) {
      out.add(s);
    } else {
      final list = listsById[s.id];
      if (list != null) out.add(HomeSection(id: s.id, visible: list.enabled));
    }
  }
  for (final id in kSpecialSectionIds) {
    if (seen.add(id)) out.add(HomeSection(id: id));
  }
  for (final l in lists) {
    final id = listSectionId(l.id);
    if (seen.add(id)) out.add(HomeSection(id: id, visible: l.enabled));
  }
  return out;
}
