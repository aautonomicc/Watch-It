import '../models/media_list.dart';

/// Genre helpers for the list pages. (This file once also held the
/// "Auto by type" virtual Movies / TV Shows arrangement — removed
/// 2026-08-28: it hid custom lists whose entries have no TMDB match,
/// so browsing is always the user's own lists now.)

/// Genre-chip label for entries with no matched genres.
const kUncategorised = 'Uncategorised';

/// The lists a drawer/list page can browse: the enabled user lists.
List<MediaList> browsableLists(List<MediaList> lists) => [
      for (final l in lists)
        if (l.enabled) l,
    ];

/// Individual genre names from a [MediaMetadata.category] value
/// (`'Horror · Thriller'` → `['Horror', 'Thriller']`); empty when
/// unmatched.
List<String> genreNames(String? category) {
  if (category == null) return const [];
  return [
    for (final part in category.split('·'))
      if (part.trim().isNotEmpty) part.trim(),
  ];
}
