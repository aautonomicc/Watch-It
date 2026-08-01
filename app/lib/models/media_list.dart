/// Library model: a user-held list of media entries, each entry a
/// `{derived address, file name}` pair whose root data map lives in the
/// embedded client's local store (see docs/ARCHITECTURE.md). Entries are
/// created by importing `.datamap` files or `.watch-list` bundles — an
/// entry whose map is missing (interrupted upgrade migration) cannot
/// play until re-imported.
class MediaEntry {
  const MediaEntry({required this.name, required this.address, this.addedAt});

  /// File name, preferably Plex/Jellyfin style
  /// (`Title (Year) {imdb-ttXXXXXXX} - [1080p].mkv`); release-style names
  /// (`The.Movie.2024.1080p.mkv`) also parse. Fed to the metadata matcher.
  final String name;

  /// Derived address (64 hex chars): blake3 of the serialized shrunk root
  /// data map, computed offline at import. For a file that was uploaded
  /// publicly this equals its public XOR address, which is why entries
  /// created by pre-alpha.40 versions keep working unchanged.
  final String address;

  /// When the entry entered the library (epoch ms). Null while unsaved
  /// ([LibraryStore.save] stamps the current time); 0 for entries that
  /// predate the column (add time unknown — excluded from the Recently
  /// Added row).
  final int? addedAt;

  Map<String, dynamic> toJson() => {
        'name': name,
        'address': address,
        if (addedAt != null) 'addedAt': addedAt,
      };

  factory MediaEntry.fromJson(Map<String, dynamic> json) => MediaEntry(
        name: json['name'] as String? ?? '',
        address: json['address'] as String? ?? '',
        addedAt: json['addedAt'] as int?,
      );
}

class MediaList {
  const MediaList({
    required this.id,
    required this.title,
    this.entries = const [],
    this.enabled = true,
  });

  final String id;
  final String title;
  final List<MediaEntry> entries;

  /// Disabled lists stay in the library but are hidden from the home
  /// screen (toggled in Settings → Media Lists).
  final bool enabled;

  MediaList copyWith({
    String? title,
    List<MediaEntry>? entries,
    bool? enabled,
  }) =>
      MediaList(
        id: id,
        title: title ?? this.title,
        entries: entries ?? this.entries,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'entries': entries.map((e) => e.toJson()).toList(),
        'enabled': enabled,
      };

  factory MediaList.fromJson(Map<String, dynamic> json) => MediaList(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        entries: (json['entries'] as List<dynamic>? ?? [])
            .map((e) => MediaEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
        enabled: json['enabled'] as bool? ?? true,
      );
}

/// Loose sanity check for a content address (derived or public XOR —
/// same shape): 64 hex chars, optional 0x prefix.
bool looksLikeXorAddress(String s) {
  final t = s.startsWith('0x') ? s.substring(2) : s;
  return RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(t);
}
