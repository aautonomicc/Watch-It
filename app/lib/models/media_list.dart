/// Library model: a user-held list of media entries, each entry a
/// `{XOR public file address, file name}` pair (see docs/ARCHITECTURE.md).
class MediaEntry {
  const MediaEntry({required this.name, required this.address});

  /// File name, e.g. `The.Movie.2024.1080p.mkv` — later fed to the
  /// metadata matcher.
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
  });

  final String id;
  final String title;
  final List<MediaEntry> entries;

  MediaList copyWith({String? title, List<MediaEntry>? entries}) => MediaList(
        id: id,
        title: title ?? this.title,
        entries: entries ?? this.entries,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'entries': entries.map((e) => e.toJson()).toList(),
      };

  factory MediaList.fromJson(Map<String, dynamic> json) => MediaList(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        entries: (json['entries'] as List<dynamic>? ?? [])
            .map((e) => MediaEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// Loose sanity check for an Autonomi XOR address: 64 hex chars,
/// optional 0x prefix. Kept permissive — the network is the real judge.
bool looksLikeXorAddress(String s) {
  final t = s.startsWith('0x') ? s.substring(2) : s;
  return RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(t);
}
