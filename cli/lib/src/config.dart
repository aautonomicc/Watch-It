import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// CLI configuration. Everything lives under `~/.watchit-upload/`
/// (2026-09-01 decision: API keys are CLI-side, never app settings):
///
/// - `config.yaml` — `acoustid_key`, `tmdb_key`, `server_base`
/// - `ledger.jsonl` — the content-hash upload ledger
/// - `cache/mb/`, `cache/art/` — MusicBrainz responses + fetched artwork
///
/// Environment overrides: `ACOUSTID_API_KEY`, `TMDB_API_KEY`,
/// `WATCHIT_SERVER` (a running watchit_core devserver base URL for the
/// post-upload get_range retrievability check).
class CliConfig {
  CliConfig({
    required this.homeDir,
    this.acoustidKey,
    this.tmdbKey,
    this.serverBase,
  });

  final Directory homeDir;
  final String? acoustidKey;
  final String? tmdbKey;
  final String? serverBase;

  File get ledgerFile => File(p.join(homeDir.path, 'ledger.jsonl'));
  Directory get mbCacheDir => Directory(p.join(homeDir.path, 'cache', 'mb'));
  Directory get artCacheDir => Directory(p.join(homeDir.path, 'cache', 'art'));

  static CliConfig load({Directory? home, Map<String, String>? env}) {
    env ??= Platform.environment;
    home ??= Directory(
        p.join(env['HOME'] ?? Directory.current.path, '.watchit-upload'));
    String? acoustid, tmdb, server;
    final configFile = File(p.join(home.path, 'config.yaml'));
    if (configFile.existsSync()) {
      try {
        final doc = loadYaml(configFile.readAsStringSync());
        if (doc is YamlMap) {
          acoustid = doc['acoustid_key']?.toString();
          tmdb = doc['tmdb_key']?.toString();
          server = doc['server_base']?.toString();
        }
      } catch (e) {
        stderr.writeln('warning: could not read ${configFile.path}: $e');
      }
    }
    String? blankAsNull(String? s) =>
        (s == null || s.trim().isEmpty) ? null : s.trim();
    return CliConfig(
      homeDir: home,
      acoustidKey: blankAsNull(env['ACOUSTID_API_KEY']) ?? blankAsNull(acoustid),
      tmdbKey: blankAsNull(env['TMDB_API_KEY']) ?? blankAsNull(tmdb),
      serverBase: blankAsNull(env['WATCHIT_SERVER']) ?? blankAsNull(server),
    );
  }

  void ensureDirs() {
    homeDir.createSync(recursive: true);
    mbCacheDir.createSync(recursive: true);
    artCacheDir.createSync(recursive: true);
  }
}
