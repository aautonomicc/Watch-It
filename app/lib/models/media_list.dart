/// Library model: a user-held list of media entries, each entry a
/// `{XOR public file address, file name}` pair (see docs/ARCHITECTURE.md).
class MediaEntry {
  const MediaEntry({required this.name, required this.address});

  /// File name, preferably Plex/Jellyfin style
  /// (`Title (Year) {imdb-ttXXXXXXX} - [1080p].mkv`); release-style names
  /// (`The.Movie.2024.1080p.mkv`) also parse. Fed to the metadata matcher.
  final String name;

  /// XOR public file address on Autonomi (64 hex chars).
  final String address;

  Map<String, dynamic> toJson() => {'name': name, 'address': address};

  factory MediaEntry.fromJson(Map<String, dynamic> json) => MediaEntry(
        name: json['name'] as String? ?? '',
        address: json['address'] as String? ?? '',
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

/// Loose sanity check for an Autonomi XOR address: 64 hex chars,
/// optional 0x prefix. Kept permissive — the network is the real judge.
bool looksLikeXorAddress(String s) {
  final t = s.startsWith('0x') ? s.substring(2) : s;
  return RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(t);
}
