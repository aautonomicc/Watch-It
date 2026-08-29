/// Library model: a user-held list of media entries, each entry a
/// `{derived address, file name}` pair whose root data map lives in the
/// embedded client's local store (see docs/ARCHITECTURE.md). Entries are
/// created by importing `.datamap` files or `.watch-list` bundles — an
/// entry whose map is missing (interrupted upgrade migration) cannot
/// play until re-imported.
class MediaEntry {
  const MediaEntry({
    required this.name,
    required this.address,
    this.addedAt,
    this.sizeBytes,
    this.videoInfo,
  });

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

  /// Exact size of the original file in bytes, read off the root data
  /// map at import (`original_file_size`) or backfilled from the local
  /// store via `GET /resolve`. Null for entries that predate the column.
  final int? sizeBytes;

  /// Short video-format label (`480p H.264`, `1080p`) — baked in for
  /// seed-catalog entries (probed from the source files), learned from
  /// the player's video parameters on first playback for imports.
  /// Together with [sizeBytes] this is what tells two uploads of the
  /// same title in different formats apart.
  final String? videoInfo;

  Map<String, dynamic> toJson() => {
        'name': name,
        'address': address,
        if (addedAt != null) 'addedAt': addedAt,
        if (sizeBytes != null) 'sizeBytes': sizeBytes,
        if (videoInfo != null) 'videoInfo': videoInfo,
      };

  factory MediaEntry.fromJson(Map<String, dynamic> json) => MediaEntry(
        name: json['name'] as String? ?? '',
        address: json['address'] as String? ?? '',
        addedAt: json['addedAt'] as int?,
        sizeBytes: json['sizeBytes'] as int?,
        videoInfo: json['videoInfo'] as String?,
      );
}

class MediaList {
  const MediaList({
    required this.id,
    required this.title,
    this.entries = const [],
    this.enabled = true,
    this.channelPubkey,
    this.channelAuthor,
    this.channelAvatar,
  });

  final String id;
  final String title;
  final List<MediaEntry> entries;

  /// Disabled lists stay in the library but are hidden from the home
  /// screen (toggled in Settings → Media Lists).
  final bool enabled;

  /// Non-null marks a subscribed CHANNEL list (the channel's public key,
  /// lowercase hex): read-only, badged amber, mirrors the channel's
  /// published manifest and updates when a newer signed head arrives.
  final String? channelPubkey;

  /// Channel lists only — the profile from the last imported manifest:
  /// the optional "by `<author>`" name/handle…
  final String? channelAuthor;

  /// …and the avatar's file name in the posters dir
  /// (`channel_avatar_<sha8>.img`), null when the channel has none.
  final String? channelAvatar;

  bool get isChannel => channelPubkey != null;

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
        channelPubkey: channelPubkey,
        channelAuthor: channelAuthor,
        channelAvatar: channelAvatar,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'entries': entries.map((e) => e.toJson()).toList(),
        'enabled': enabled,
        if (channelPubkey != null) 'channelPubkey': channelPubkey,
        if (channelAuthor != null) 'channelAuthor': channelAuthor,
        if (channelAvatar != null) 'channelAvatar': channelAvatar,
      };

  factory MediaList.fromJson(Map<String, dynamic> json) => MediaList(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        entries: (json['entries'] as List<dynamic>? ?? [])
            .map((e) => MediaEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
        enabled: json['enabled'] as bool? ?? true,
        channelPubkey: json['channelPubkey'] as String?,
        channelAuthor: json['channelAuthor'] as String?,
        channelAvatar: json['channelAvatar'] as String?,
      );
}

/// `812 KB`, `64.2 MB`, `1.38 GB` — shared byte formatter (size-on-disk
/// tile, download queue rows, entry format lines).
String formatBytes(int bytes) {
  const kb = 1024, mb = kb * 1024, gb = mb * 1024;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(2)} GB';
  if (bytes >= mb) {
    final v = bytes / mb;
    return v >= 100 ? '${v.round()} MB' : '${v.toStringAsFixed(1)} MB';
  }
  if (bytes >= kb) return '${(bytes / kb).round()} KB';
  return '$bytes B';
}

/// `480p H.264 · 570 MB` — the entry's format/size line, or null when
/// neither is known yet. What visually tells two uploads of the same
/// title apart on cards and detail pages.
String? formatInfoLine(MediaEntry entry) {
  final parts = [
    if (entry.videoInfo != null && entry.videoInfo!.isNotEmpty)
      entry.videoInfo!,
    if ((entry.sizeBytes ?? 0) > 0) formatBytes(entry.sizeBytes!),
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// Standard-ladder label for a video height in pixels: `1072 → 1080p`,
/// `480 → 480p`. Buckets are generous because encodes rarely land on
/// exact ladder heights (crops, anamorphic sources).
String resolutionLabel(int height) {
  if (height >= 2000) return '2160p';
  if (height >= 1000) return '1080p';
  if (height >= 700) return '720p';
  if (height >= 560) return '576p';
  if (height >= 440) return '480p';
  if (height >= 340) return '360p';
  return '${height}p';
}

/// Loose sanity check for a content address (derived or public XOR —
/// same shape): 64 hex chars, optional 0x prefix.
bool looksLikeXorAddress(String s) {
  final t = s.startsWith('0x') ? s.substring(2) : s;
  return RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(t);
}
