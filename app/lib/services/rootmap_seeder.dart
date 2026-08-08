import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import 'embedded_client.dart';
import 'seed_catalog.dart';

/// Seeds the embedded client's root-map store with data maps bundled as
/// Flutter assets, so every seeded catalog title plays within seconds on
/// a fresh install — required for offline first runs, since the play
/// path serves locally stored maps only (no network resolve).
///
/// The server verifies every imported map offline before storing it
/// (verify-then-store on `PUT /rootmap`), so a corrupt or tampered asset
/// is rejected — that entry then needs its `.datamap` imported once
/// while connected before it can play. Idempotent and fully offline;
/// safe to fire-and-forget at startup.

/// Addresses whose resolved root map ships inside the app: every entry
/// of the seeded catalog. The asset for an address must exist at
/// [bundledRootMapAsset] (a test asserts this, so a catalog change
/// cannot silently ship a stale or missing map).
final List<String> kBundledRootMapAddresses = [
  for (final list in kSeedLists)
    for (final entry in list.entries) entry.address,
];

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
    // Best-effort: any failure (missing asset, rejected map, server not
    // up yet) leaves that entry unplayable until its .datamap is
    // imported; the next launch retries the seed.
  }
}
