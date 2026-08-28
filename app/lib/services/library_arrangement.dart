import '../models/media_list.dart';
import 'home_sections.dart';

/// Genre helpers for the list pages. (This file once also held the
/// "Auto by type" virtual Movies / TV Shows arrangement — removed
/// 2026-08-28: it hid custom lists whose entries have no TMDB match,
/// so browsing is always the user's own lists now.)

/// Genre-chip label for entries with no matched genres.
const kUncategorised = 'Uncategorised';

/// The lists a drawer/list page can browse: the enabled user lists, in
/// the home screen's row order. [stored] is the raw persisted order from
/// AppSettings.homeSections; it's reconciled here so the drawer always
/// mirrors the wall — same order, same visibility, fresh channels on
/// top. With nothing stored the reconcile yields library order, the
/// pre-customization behaviour.
List<MediaList> browsableLists(
  List<MediaList> lists, [
  List<HomeSection> stored = const [],
]) {
  final byId = {for (final l in lists) l.id: l};
  return [
    for (final s in reconcileHomeSections(stored, lists))
      if (s.visible && byId.containsKey(s.listId)) byId[s.listId]!,
  ];
}

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
