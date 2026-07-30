import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import 'embedded_client.dart';
import 'metadata.dart';

/// Seeds the embedded client's root-map store with data maps bundled as
/// Flutter assets, so the default movie plays within seconds on a fresh
/// install instead of paying the 20-30s cold network resolve.
///
/// The server verifies every imported map offline before storing it
/// (verify-then-store on `PUT /rootmap`), so a corrupt or tampered asset
/// is rejected — the address then just resolves over the network as
/// before. Idempotent and fully offline; safe to fire-and-forget at
/// startup.

/// Addresses whose resolved root map ships inside the app. Keep in sync
/// with the bundled catalog: the asset for an address must exist at
/// [bundledRootMapAsset] (a test asserts this, so a default-movie swap
/// cannot silently ship a stale map).
const List<String> kBundledRootMapAddresses = [kDefaultMovieAddress];

/// Asset path of the bundled root map for [address].
String bundledRootMapAsset(String address) => 'assets/rootmaps/$address.map';

Future<void> seedBundledRootMaps({String? baseOverride}) async {
  final base = baseOverride ?? EmbeddedClient.baseUrl();
  if (base == null) return; // no native library (tests, bare desktop)
  final client = HttpClient();
  try {
    for (final address in kBundledRootMapAddresses) {
      await _seedOne(client, base, address);
    }
  } finally {
    client.close(force: true);
  }
}

Future<void> _seedOne(HttpClient client, String base, String address) async {
  try {
    // Already stored (earlier launch, or resolved from the network)?
    final check = await client.getUrl(Uri.parse('$base/rootmap/$address'));
    final checkRes = await check.close();
    await checkRes.drain<void>();
    if (checkRes.statusCode != HttpStatus.notFound) return;

    final bytes = await rootBundle.load(bundledRootMapAsset(address));
    final put = await client.putUrl(Uri.parse('$base/rootmap/$address'));
    put.add(bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes));
    final putRes = await put.close();
    await putRes.drain<void>();
  } catch (_) {
    // Seeding is a fast-path optimization only — any failure (missing
    // asset, rejected map, server not up yet) falls back to the normal
    // network resolve on first play.
  }
}
