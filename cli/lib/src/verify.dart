import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Post-upload proof of retrievability (2026-09-01 decision): import the
/// fresh datamap into a running watchit_core devserver (`POST /datamap`
/// derives the address offline and stores the map) and `get_range` the
/// first 64 KB over `GET /xor/<addr>` — a REAL network chunk fetch
/// through ant-core — comparing bytes against the source file.
///
/// Needs `server_base` in config.yaml (or WATCHIT_SERVER), e.g. a
/// `cargo run --release --bin devserver` instance. When no server is
/// reachable the check is skipped, never failed.
class VerifyResult {
  const VerifyResult(this.status, {this.address, this.detail});
  final String status; // verified | failed | skipped
  final String? address;
  final String? detail;
}

Future<bool> serverReachable(String base, {http.Client? client}) async {
  final own = client == null;
  client ??= http.Client();
  try {
    final res = await client
        .get(Uri.parse('$base/health'))
        .timeout(const Duration(seconds: 5));
    return res.statusCode == 200;
  } catch (_) {
    return false;
  } finally {
    if (own) client.close();
  }
}

Future<VerifyResult> verifyRetrievable({
  required String serverBase,
  required Uint8List datamapBytes,
  required File sourceFile,
  http.Client? client,
}) async {
  final own = client == null;
  client ??= http.Client();
  try {
    final imp = await client
        .post(Uri.parse('$serverBase/datamap'), body: datamapBytes)
        .timeout(const Duration(seconds: 60));
    if (imp.statusCode != 200) {
      return VerifyResult('failed',
          detail: 'datamap import: HTTP ${imp.statusCode} ${imp.body}');
    }
    final address = RegExp(r'"address"\s*:\s*"([0-9a-f]{64})"')
        .firstMatch(imp.body)
        ?.group(1);
    if (address == null) {
      return VerifyResult('failed', detail: 'no address in ${imp.body}');
    }
    final size = sourceFile.lengthSync();
    final end = size < 65536 ? size - 1 : 65535;
    final req =
        http.Request('GET', Uri.parse('$serverBase/xor/$address'))
          ..headers['Range'] = 'bytes=0-$end';
    final res = await client.send(req).timeout(const Duration(minutes: 5));
    if (res.statusCode != 200 && res.statusCode != 206) {
      return VerifyResult('failed',
          address: address, detail: 'get_range: HTTP ${res.statusCode}');
    }
    final fetched = BytesBuilder(copy: false);
    await for (final chunk in res.stream) {
      fetched.add(chunk);
      if (fetched.length > end + 1) break;
    }
    final got = fetched.takeBytes();
    final raf = sourceFile.openSync();
    Uint8List want;
    try {
      want = raf.readSync(end + 1);
    } finally {
      raf.closeSync();
    }
    if (got.length < want.length) {
      return VerifyResult('failed',
          address: address,
          detail: 'short read: ${got.length} of ${want.length} bytes');
    }
    for (var i = 0; i < want.length; i++) {
      if (got[i] != want[i]) {
        return VerifyResult('failed',
            address: address, detail: 'byte mismatch at offset $i');
      }
    }
    return VerifyResult('verified', address: address);
  } catch (e) {
    return VerifyResult('failed', detail: '$e');
  } finally {
    if (own) client.close();
  }
}
