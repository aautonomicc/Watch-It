/// Portable, user-supplied attribution for one exact media file. These fields
/// record a claim and its source; they do not verify identity or grant rights.
class MediaCredits {
  const MediaCredits({
    this.title = '',
    this.creator = '',
    this.sourceUrl = '',
    this.licenseName = '',
    this.licenseUrl = '',
    this.attribution = '',
    this.changes = '',
  });

  final String title;
  final String creator;
  final String sourceUrl;
  final String licenseName;
  final String licenseUrl;
  final String attribution;
  final String changes;

  static const fields = {
    'title': ('Source title', 512),
    'creator': ('Creator / performers', 512),
    'sourceUrl': ('Original source URL', 2048),
    'licenseName': ('Licence name', 256),
    'licenseUrl': ('Licence URL', 2048),
    'attribution': ('Attribution / copyright notice', 4096),
    'changes': ('Changes to the original', 4096),
  };

  Map<String, String> toJson() => {
    'title': title,
    'creator': creator,
    'sourceUrl': sourceUrl,
    'licenseName': licenseName,
    'licenseUrl': licenseUrl,
    'attribution': attribution,
    'changes': changes,
  };

  bool get isEmpty => toJson().values.every((v) => v.trim().isEmpty);

  /// Strict per-row validation: a malformed optional bundle row is skipped,
  /// without throwing away the media or the other valid credit records.
  factory MediaCredits.fromJson(Map<String, dynamic> json) {
    final values = <String, String>{};
    for (final field in fields.entries) {
      final value = json[field.key] ?? '';
      if (value is! String) {
        throw FormatException('${field.value.$1} must be text.');
      }
      final text = value.trim();
      if (text.length > field.value.$2 || text.contains('\u0000')) {
        throw FormatException('${field.value.$1} is too long or invalid.');
      }
      if (field.key.endsWith('Url') && text.isNotEmpty && !isWebUrl(text)) {
        throw FormatException(
          '${field.value.$1} must be an HTTP or HTTPS link.',
        );
      }
      values[field.key] = text;
    }
    return MediaCredits(
      title: values['title']!,
      creator: values['creator']!,
      sourceUrl: values['sourceUrl']!,
      licenseName: values['licenseName']!,
      licenseUrl: values['licenseUrl']!,
      attribution: values['attribution']!,
      changes: values['changes']!,
    );
  }

  static bool isWebUrl(String text) {
    final uri = Uri.tryParse(text);
    return uri != null &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        !RegExp(r'\s').hasMatch(text);
  }

  String get creditText => [
    for (final field in toJson().entries)
      if (field.value.isNotEmpty) '${fields[field.key]!.$1}: ${field.value}',
  ].join('\n\n');
}
