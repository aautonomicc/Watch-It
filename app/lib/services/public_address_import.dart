import 'package:http/http.dart' as http;

import '../models/media_list.dart';
import 'embedded_client.dart';
import 'list_import.dart' show ListImportException;

/// Result of the explicit public-address probe. A probe is read-only: it
/// verifies the address shape, asks the embedded client for the public data
/// map, and returns the immutable file size from the response headers.
class PublicAddressInspection {
  const PublicAddressInspection({required this.address, this.sizeBytes});

  final String address;
  final int? sizeBytes;
}

String normalizePublicAddress(String input) {
  final trimmed = input.trim();
  final hex = trimmed.toLowerCase().startsWith('0x')
      ? trimmed.substring(2)
      : trimmed;
  return hex.toLowerCase();
}

Future<PublicAddressInspection> inspectPublicAddress(
  String input, {
  String? base,
}) async {
  final address = normalizePublicAddress(input);
  if (!looksLikeXorAddress(address)) {
    throw const ListImportException(
        'Enter a public Autonomi address: 64 hexadecimal characters.');
  }
  base ??= EmbeddedClient.baseUrl();
  if (base == null) {
    throw const ListImportException(
        'The built-in Autonomi client is not available on this platform.');
  }
  final client = http.Client();
  try {
    final res = await client
        .head(Uri.parse('${base.replaceFirst(RegExp(r'/+$'), '')}/public/$address'))
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      final detail = res.body.trim();
      throw ListImportException(detail.isEmpty
          ? 'That public address could not be resolved (${res.statusCode}).'
          : 'That public address could not be resolved — $detail.');
    }
    final rawSize = res.headers['content-length'];
    final size = rawSize == null ? null : int.tryParse(rawSize);
    return PublicAddressInspection(address: address, sizeBytes: size);
  } on ListImportException {
    rethrow;
  } catch (e) {
    throw ListImportException(humanPublicAddressError(e));
  } finally {
    client.close();
  }
}

/// New-bee / Raver error line. Never dumps a stack or exception type.
/// Cypherpunk surfaces the original [ListImportException] at the dialog.
String humanPublicAddressError(Object error) {
  final raw = error is ListImportException ? error.message : error.toString();
  final lower = raw.toLowerCase();
  if (lower.contains('64 hexadecimal') ||
      lower.contains('hexadecimal character')) {
    return 'That doesn’t look like an address yet. Paste the whole code they sent.';
  }
  if (lower.contains('not available on this platform') ||
      lower.contains('client is not available')) {
    return 'W@tch isn’t connected on this device yet.';
  }
  if (lower.contains('not connected') ||
      lower.contains('network is paused') ||
      lower.contains('503')) {
    return 'W@tch can’t reach Autonomi right now. Wait until it says Connected, then try again.';
  }
  if (lower.contains('could not be resolved') ||
      lower.contains('not found') ||
      lower.contains('404')) {
    return 'We couldn’t find that piece. Try again, or paste a different address.';
  }
  if (lower.contains('timeout') || lower.contains('timed out')) {
    return 'That took too long. Try again when you’re connected.';
  }
  if (lower.contains('exception') ||
      lower.contains('error:') ||
      lower.contains('failed:')) {
    return 'We couldn’t look that up. Try again, or paste a different address.';
  }
  return raw;
}
