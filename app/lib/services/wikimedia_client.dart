import 'dart:convert';

import 'package:http/http.dart' as http;

/// Transport failure talking to a Wikimedia service (Wikidata,
/// Wikipedia, Commons). Distinct from "no such entity/page/file", which
/// is a `null` result.
class WikimediaException implements Exception {
  const WikimediaException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'WikimediaException($statusCode): $message';
}

/// The two facts an artist page needs from a Wikidata item.
class WikidataEntity {
  const WikidataEntity({this.imageFile, this.enwikiTitle});

  /// Commons file name of the item's image (property P18), the artist
  /// portrait; null when the item has none.
  final String? imageFile;

  /// English Wikipedia article title (sitelink), the bio source; null
  /// when no English article exists.
  final String? enwikiTitle;
}

/// A Wikipedia article summary — the bio paragraph plus attribution
/// pieces (CC BY-SA requires linking the source article).
class WikipediaSummary {
  const WikipediaSummary({this.extract, this.pageUrl, this.thumbnailUrl});

  final String? extract;
  final String? pageUrl;

  /// The article's lead-image thumbnail — the portrait fallback when
  /// the Wikidata item carries no P18 image.
  final String? thumbnailUrl;
}

/// Minimal keyless client for the three Wikimedia endpoints the artist
/// page chain uses: Wikidata entity data, the Wikipedia page summary,
/// and Commons file bytes. Same shape as [CaaClient]; a real User-Agent
/// is good etiquette here too.
class WikimediaClient {
  WikimediaClient({http.Client? client}) : _http = client ?? http.Client();

  final http.Client _http;

  static const userAgent =
      'Watch-It/alpha (https://github.com/aautonomicc/Watch-It)';

  Future<http.Response?> _get(String url) async {
    final http.Response resp;
    try {
      resp = await _http.get(
        Uri.parse(url),
        headers: const {'User-Agent': userAgent},
      ).timeout(const Duration(seconds: 30));
    } catch (e) {
      throw WikimediaException('$e');
    }
    if (resp.statusCode == 404) return null;
    if (resp.statusCode != 200) {
      throw WikimediaException('fetch failed', statusCode: resp.statusCode);
    }
    return resp;
  }

  /// The Wikidata item [qid] (`Q392`), reduced to the portrait file and
  /// English article title; null when the item does not exist.
  Future<WikidataEntity?> entity(String qid) async {
    final resp =
        await _get('https://www.wikidata.org/wiki/Special:EntityData/$qid.json');
    if (resp == null) return null;
    final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    final entities = decoded is Map ? decoded['entities'] : null;
    final entity = entities is Map ? entities[qid] : null;
    if (entity is! Map) return null;

    String? imageFile;
    final claims = entity['claims'];
    final p18 = claims is Map ? claims['P18'] : null;
    if (p18 is List && p18.isNotEmpty) {
      final first = p18.first;
      final mainsnak = first is Map ? first['mainsnak'] : null;
      final datavalue = mainsnak is Map ? mainsnak['datavalue'] : null;
      final value = datavalue is Map ? datavalue['value'] : null;
      if (value is String && value.isNotEmpty) imageFile = value;
    }

    String? enwikiTitle;
    final sitelinks = entity['sitelinks'];
    final enwiki = sitelinks is Map ? sitelinks['enwiki'] : null;
    final title = enwiki is Map ? enwiki['title'] : null;
    if (title is String && title.isNotEmpty) enwikiTitle = title;

    return WikidataEntity(imageFile: imageFile, enwikiTitle: enwikiTitle);
  }

  /// English Wikipedia summary of [title]; null when no such article.
  Future<WikipediaSummary?> summary(String title) async {
    final resp = await _get(
        'https://en.wikipedia.org/api/rest_v1/page/summary/'
        '${Uri.encodeComponent(title.replaceAll(' ', '_'))}');
    if (resp == null) return null;
    final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    if (decoded is! Map) return null;
    final extract = decoded['extract'];
    final contentUrls = decoded['content_urls'];
    final desktop = contentUrls is Map ? contentUrls['desktop'] : null;
    final page = desktop is Map ? desktop['page'] : null;
    final thumbnail = decoded['thumbnail'];
    final thumbSource = thumbnail is Map ? thumbnail['source'] : null;
    return WikipediaSummary(
      extract: extract is String && extract.isNotEmpty ? extract : null,
      pageUrl: page is String ? page : null,
      thumbnailUrl: thumbSource is String ? thumbSource : null,
    );
  }

  /// Bytes of the Commons file [fileName] scaled to [width] (the
  /// Special:FilePath endpoint redirects to the thumbnail; `http`
  /// follows redirects). Null when the file does not exist.
  Future<List<int>?> commonsFile(String fileName, {int width = 500}) async {
    final resp = await _get(
        'https://commons.wikimedia.org/wiki/Special:FilePath/'
        '${Uri.encodeComponent(fileName.replaceAll(' ', '_'))}?width=$width');
    return resp?.bodyBytes;
  }

  /// Bytes of an image [url] a summary named (the portrait fallback).
  Future<List<int>?> imageBytes(String url) async {
    final resp = await _get(url);
    return resp?.bodyBytes;
  }

  void close() => _http.close();
}
