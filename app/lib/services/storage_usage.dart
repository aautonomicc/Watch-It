import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'library_store.dart';

/// Size on disk and factory reset for everything W@tch stores: the
/// media-list database, cached artwork and metadata, imported data
/// maps, settings, and the embedded client's network state — all of it
/// lives under the app support directory.

/// Total bytes under the app data directory, or null when the platform
/// directory cannot be resolved (tests, bare desktop builds).
Future<int?> appDataSizeBytes({Directory? dir}) async {
  final root = dir ?? await _appDataDir();
  if (root == null || !await root.exists()) return null;
  return directorySizeBytes(root);
}

/// Recursive size of [root]; entries that vanish or refuse stat mid-walk
/// are skipped.
Future<int> directorySizeBytes(Directory root) async {
  var total = 0;
  try {
    await for (final entity
        in root.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        try {
          total += await entity.length();
        } catch (_) {}
      }
    }
  } catch (_) {}
  return total;
}

/// Delete everything inside [root] (the directory itself stays). Errors
/// on individual entries are skipped so one locked file doesn't block the
/// rest of the wipe.
Future<void> wipeDirectory(Directory root) async {
  final List<FileSystemEntity> entries;
  try {
    entries = await root.list(followLinks: false).toList();
  } catch (_) {
    return;
  }
  for (final entity in entries) {
    try {
      await entity.delete(recursive: true);
    } catch (_) {}
  }
}

/// Factory reset: close the database, clear preferences, and delete the
/// app data directory's contents. The caller must exit the app right
/// after — open SQLite handles (ours and the embedded client's) still
/// point at the deleted files until the process ends.
Future<void> factoryReset({Directory? dir}) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  } catch (_) {}
  try {
    await LibraryStore.close();
  } catch (_) {}
  final root = dir ?? await _appDataDir();
  if (root != null && await root.exists()) await wipeDirectory(root);
}

/// Test hook: when set, size measurement and factory reset use this
/// directory instead of the platform app-support directory.
Directory? debugAppDataDirOverride;

Future<Directory?> _appDataDir() async {
  if (debugAppDataDirOverride != null) return debugAppDataDirOverride;
  try {
    return await getApplicationSupportDirectory();
  } catch (_) {
    return null;
  }
}

/// `812 KB`, `64.2 MB`, `1.38 GB` — for the size-on-disk tile.
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
