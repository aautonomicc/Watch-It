import 'dart:math' as math;

import 'media_credits.dart';

/// One Add to W@tch intake draft: media that is not on the network yet.
///
/// A `link` draft is a reference record for a pasted source URL — W@tch
/// never downloads from it. A `file` draft remembers a picked local file
/// (path kept on desktop only) together with the review card's details.
/// Drafts have no Autonomi address: they are not library entries, never
/// playable on TV, and never leave this device. When a real upload
/// succeeds, the credits are re-keyed onto the resulting file address and
/// the draft is consumed.
class IntakeDraft {
  IntakeDraft({
    required this.id,
    required this.kind,
    required this.label,
    this.sourceUrl,
    this.localPath,
    this.sizeBytes,
    this.language,
    this.listTitle,
    this.artworkFile,
    MediaCredits? credits,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : credits = credits ?? const MediaCredits(),
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  static const kindFile = 'file';
  static const kindLink = 'link';
  static const knownKinds = {kindFile, kindLink};

  final String id;
  final String kind;
  String label;
  String? sourceUrl;
  String? localPath;
  int? sizeBytes;
  String? language;
  String? listTitle;

  /// File name inside the app's posters dir (`intake_<sha8>.img`).
  String? artworkFile;

  MediaCredits credits;
  DateTime createdAt;
  DateTime updatedAt;

  bool get isFile => kind == kindFile;
  bool get isLink => kind == kindLink;

  static const labelLimit = 512;
  static const languageLimit = 64;
  static const listTitleLimit = 128;
  static const idPrefix = 'intake_';

  /// Fresh id for a new draft — unique within this install without a
  /// uuid dependency (microsecond clock + a random tail).
  static String newId() {
    final r = math.Random();
    return '$idPrefix${DateTime.now().microsecondsSinceEpoch}'
        '_${r.nextInt(0x7FFFFFFF)}';
  }

  /// Where a link draft's display name is suggested from when the user
  /// hasn't typed one: the last meaningful path segment of the URL.
  static String? suggestLabel(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.path.isEmpty) return null;
    final segs = [
      for (final s in uri.pathSegments)
        if (s.trim().isNotEmpty) s,
    ];
    if (segs.isEmpty) return null;
    var label = Uri.decodeComponent(segs.last);
    final dot = label.lastIndexOf('.');
    if (dot > 0 && label.length - dot <= 5) {
      label = label.substring(0, dot);
    }
    return label.trim().isEmpty ? null : label.trim();
  }

  /// Validate and normalize in place. Throws [FormatException] with a
  /// user-presentable message on the first problem found — the same
  /// contract [MediaCredits.fromJson] uses.
  void validate() {
    final trimmedLabel = label.trim();
    if (trimmedLabel.isEmpty) {
      throw const FormatException('A title is required.');
    }
    if (trimmedLabel.length > labelLimit || trimmedLabel.contains('\u0000')) {
      throw const FormatException('That title is too long.');
    }
    label = trimmedLabel;

    if (!knownKinds.contains(kind)) {
      throw const FormatException('Unknown draft kind.');
    }
    if (isLink && (sourceUrl == null || sourceUrl!.trim().isEmpty)) {
      throw const FormatException('A source link needs its URL.');
    }
    final url = sourceUrl?.trim() ?? '';
    if (url.isNotEmpty && !MediaCredits.isWebUrl(url)) {
      throw const FormatException(
        'The source link must be an HTTP or HTTPS address.',
      );
    }
    sourceUrl = url.isEmpty ? null : url;

    if (isFile && (localPath == null || localPath!.trim().isEmpty)) {
      // A mobile pick records no durable path on purpose — the draft is
      // still valid as a record; only desktop drafts carry one.
      localPath = null;
    }
    final path = localPath?.trim() ?? '';
    localPath = path.isEmpty ? null : path;

    final lang = language?.trim() ?? '';
    if (lang.length > languageLimit || lang.contains('\u0000')) {
      throw const FormatException('That language entry is too long.');
    }
    language = lang.isEmpty ? null : lang;

    final list = listTitle?.trim() ?? '';
    if (list.length > listTitleLimit || list.contains('\u0000')) {
      throw const FormatException('That collection name is too long.');
    }
    listTitle = list.isEmpty ? null : list;

    // Re-validate the credits through their own strict parser so a draft
    // can never hold a record the credits screens would reject. The
    // card's single "Original source URL" field is the authority: when
    // set, it overrides the credits record's own source URL so the two
    // can never diverge.
    final map = credits.toJson();
    if (sourceUrl != null) map['sourceUrl'] = sourceUrl!;
    credits = MediaCredits.fromJson(map);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'label': label,
        'sourceUrl': sourceUrl,
        'localPath': localPath,
        'sizeBytes': sizeBytes,
        'language': language,
        'listTitle': listTitle,
        'artworkFile': artworkFile,
        'credits': credits.toJson(),
        'createdAt': createdAt.millisecondsSinceEpoch,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
      };
}
