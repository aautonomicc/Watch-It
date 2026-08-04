import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/media_list.dart';
import 'embedded_client.dart';
import 'list_import.dart' show ListImportException;

/// Import of `.datamap` files — the output of a private `ant file upload`
/// and the only way content enters the library (datamap-first entry
/// model, docs/PLAN-datamap-privacy.md). The embedded client parses the
/// file (msgpack, or legacy ant-gui JSON), derives the entry's address
/// offline from the map itself, and stores the map; the entry's name is
/// the file name minus `.datamap`, which ant-cli preserves verbatim from
/// the uploaded file — so NAMING.md conventions flow through to the
/// metadata matcher untouched.

/// A parsed root data map is ~100 bytes per content chunk; anything
/// bigger than this is not a data map.
const int kMaxDatamapBytes = 32 * 1024 * 1024;

/// The file name a `.datamap` file's media entry gets: the base name
/// minus the `.datamap` suffix. Null when [fileName] does not end in
/// `.datamap` (case-insensitive) or nothing would remain.
///
/// `.bin` is accepted as an alias: Android's file picker plugin copies
/// every picked file into cache and renames unknown extensions to the
/// MIME-derived one, so `X.datamap` reaches Dart as `X.bin` — stripping
/// `.bin` recovers the exact original media name. The name is only a
/// routing hint; the embedded client's content verification is what
/// actually gates the import.
String? mediaNameFromDatamapFileName(String fileName) {
  final base = fileName.split(RegExp(r'[/\\]')).last;
  final lower = base.toLowerCase();
  final suffix = lower.endsWith('.datamap')
      ? '.datamap'
      : lower.endsWith('.bin')
          ? '.bin'
          : null;
  if (suffix == null) return null;
  final name = base.substring(0, base.length - suffix.length);
  return name.isEmpty ? null : name;
}

/// True when [fileName] names the data map OF a `.watch-list` bundle
/// stored on the network — `ant file upload lib.watch-list` writes
/// `lib.watch-list.datamap`, so the convention survives the upload
/// round-trip on its own. Import routes such a file to the network
/// bundle fetch instead of making a media entry of it. Android's picker
/// rename to `lib.watch-list.bin` is caught too, via the `.bin` alias
/// in [mediaNameFromDatamapFileName].
bool isBundleDatamapName(String fileName) {
  final media = mediaNameFromDatamapFileName(fileName);
  return media != null && media.toLowerCase().endsWith('.watch-list');
}

/// What `POST /datamap` returned for one imported map.
class ImportedDatamap {
  const ImportedDatamap({
    required this.address,
    required this.size,
    required this.chunks,
  });

  /// Derived address (64 hex) — the entry's identity everywhere. For a
  /// file that was uploaded publicly this equals its public XOR address.
  final String address;
  final int size;
  final int chunks;
}

/// Send raw `.datamap` bytes to the embedded client, which verifies the
/// format, derives the address offline, and stores the map. Throws
/// [ListImportException] with a user-facing message on any failure.
Future<ImportedDatamap> importDatamapBytes(
  Uint8List bytes, {
  String? base,
}) async {
  base ??= EmbeddedClient.baseUrl();
  if (base == null) {
    throw const ListImportException(
        'The built-in Autonomi client is not available on this platform.');
  }
  if (bytes.isEmpty || bytes.length > kMaxDatamapBytes) {
    throw const ListImportException('That file is not a data map.');
  }
  final client = http.Client();
  try {
    final res = await client.post(Uri.parse('$base/datamap'), body: bytes);
    if (res.statusCode != 200) {
      // The embedded client's error text says what actually went wrong
      // (shrunk-map expansion needs the network, decode failure, …) —
      // show it rather than a generic guess.
      final detail = res.body.trim();
      if (detail.isEmpty || detail.length > 300) {
        throw const ListImportException(
            'That file could not be read as a data map.');
      }
      throw ListImportException(
          'That data map could not be imported — $detail.');
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final address = json['address'] as String?;
    if (address == null || !looksLikeXorAddress(address)) {
      throw const ListImportException(
          'The data map import returned no address.');
    }
    return ImportedDatamap(
      address: address,
      size: json['size'] as int? ?? 0,
      chunks: json['chunks'] as int? ?? 0,
    );
  } on ListImportException {
    rethrow;
  } catch (e) {
    throw ListImportException('Data map import failed: $e');
  } finally {
    client.close();
  }
}

/// Import one `.datamap` file as a media entry: derive its address via
/// the embedded client and name it after the file. Throws
/// [ListImportException] when the name or content is unusable.
Future<MediaEntry> entryFromDatamapFile(
  String fileName,
  Uint8List bytes, {
  String? base,
}) async {
  final name = mediaNameFromDatamapFileName(fileName);
  if (name == null) {
    throw ListImportException(
        '"$fileName" is not a .datamap file — expected the '
        '"<media file name>.datamap" a private upload produces.');
  }
  final imported = await importDatamapBytes(bytes, base: base);
  return MediaEntry(name: name, address: imported.address);
}
