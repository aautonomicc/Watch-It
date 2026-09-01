import 'dart:io';

import 'package:path/path.dart' as p;

import 'ant.dart';
import 'bundle_out.dart';
import 'config.dart';
import 'ledger.dart';
import 'manifest.dart';
import 'telegram.dart';
import 'verify.dart';

/// `upload` — zero prompts, walk-away. Every `ready` entry is uploaded
/// under its final W@tch name (via a staging symlink, so ant names the
/// datamap correctly), the manifest is saved after every state change
/// (crash/network drop → re-run skips `uploaded` and resumes), failures
/// are logged and retried once at the end, the ledger line is appended
/// the moment an entry flips to `uploaded`, and the run ends with a
/// `.watch-list` bundle + Telegram ping.
Future<int> runUpload(List<String> args) async {
  String manifestPath = 'watchit-manifest.yaml';
  var doVerify = true, doTelegram = true, doBundle = true;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--manifest':
        manifestPath = args[++i];
      case '--no-verify':
        doVerify = false;
      case '--no-telegram':
        doTelegram = false;
      case '--no-bundle':
        doBundle = false;
      default:
        stderr.writeln('unknown option ${args[i]}');
        return 2;
    }
  }
  final manifestFile = File(manifestPath);
  if (!manifestFile.existsSync()) {
    stderr.writeln('no manifest at $manifestPath — run prepare first.');
    return 2;
  }
  final config = CliConfig.load()..ensureDirs();
  final ledger = Ledger.load(config.ledgerFile);
  final manifest = Manifest.load(manifestFile);
  final ant = Ant();

  final pending =
      manifest.entries.where((e) => e.status == 'ready').toList();
  final blocked = manifest.entries
      .where((e) => e.status == 'needs-attention')
      .length;
  if (blocked > 0) {
    stdout.writeln('note: $blocked entr(y/ies) still need attention — '
        'they will be left out of this run.');
  }
  if (pending.isEmpty) {
    stdout.writeln('nothing to upload (no `ready` entries).');
  } else if (!ant.walletConfigured) {
    stderr.writeln('SECRET_KEY is not set — ant cannot pay for uploads. '
        'Export the wallet key and re-run.');
    return 1;
  }

  var serverBase = config.serverBase;
  if (doVerify && serverBase != null) {
    if (!await serverReachable(serverBase)) {
      stdout.writeln('note: devserver at $serverBase unreachable — '
          'retrievability checks will be skipped.');
      serverBase = null;
    }
  } else {
    serverBase = null;
  }

  final datamapsDir =
      Directory(p.join(manifestFile.absolute.parent.path, 'datamaps'))
        ..createSync(recursive: true);
  final stagingDir =
      Directory(p.join(manifestFile.absolute.parent.path, '.staging'));

  Future<void> uploadOne(ManifestEntry entry, int index) async {
    final name = entry.name;
    if (name == null) {
      entry.status = 'failed';
      entry.error = 'no final name in manifest';
      manifest.save();
      return;
    }
    stdout.writeln('[${index + 1}/${pending.length}] $name');
    final entryStaging = Directory(p.join(stagingDir.path, '$index'))
      ..createSync(recursive: true);
    final staged = p.join(entryStaging.path, name);
    final link = Link(staged);
    try {
      if (link.existsSync()) link.deleteSync();
      link.createSync(File(entry.source).absolute.path);

      final result = await ant.upload(staged,
          onLine: (l) => stdout.writeln('    $l'));
      final datamapDest = p.join(datamapsDir.path, '$name.datamap');
      File(result.datamapPath).copySync(datamapDest);
      File(result.datamapPath).deleteSync();

      entry.datamap = datamapDest;
      entry.address = result.address;
      entry.uploadedAt = DateTime.now().toIso8601String();

      if (serverBase != null) {
        final vr = await verifyRetrievable(
          serverBase: serverBase,
          datamapBytes: File(datamapDest).readAsBytesSync(),
          sourceFile: File(entry.source),
        );
        entry.verified = vr.status == 'verified';
        entry.address ??= vr.address;
        stdout.writeln(vr.status == 'verified'
            ? '    retrievability ✓ (get_range, addr ${vr.address})'
            : '    retrievability check FAILED: ${vr.detail} — the upload '
                'may still be propagating; re-check later');
      }

      entry.status = 'uploaded';
      entry.error = null;
      manifest.save();
      // The ledger line lands at the same moment the entry flips.
      ledger.append(LedgerEntry(
        sha256: entry.sha256 ?? '',
        name: name,
        sizeBytes: entry.sizeBytes ?? File(entry.source).lengthSync(),
        date: entry.uploadedAt!,
        address: entry.address,
        datamapPath: datamapDest,
        manifestPath: manifestFile.absolute.path,
      ));
    } catch (e) {
      entry.status = 'failed';
      entry.error = '$e';
      manifest.save();
      stdout.writeln('    FAILED: $e (run continues; retry pass at end)');
    } finally {
      try {
        if (link.existsSync()) link.deleteSync();
        if (entryStaging.existsSync()) {
          entryStaging.deleteSync(recursive: true);
        }
      } catch (_) {}
    }
  }

  for (final (i, entry) in pending.indexed) {
    await uploadOne(entry, i);
  }
  // Retry pass: one more attempt for anything that failed this run.
  final retries = pending.where((e) => e.status == 'failed').toList();
  if (retries.isNotEmpty) {
    stdout.writeln('\nretry pass: ${retries.length} failed upload(s)…');
    for (final entry in retries) {
      entry.status = 'ready';
      await uploadOne(entry, pending.indexOf(entry));
    }
  }
  if (stagingDir.existsSync()) {
    try {
      stagingDir.deleteSync(recursive: true);
    } catch (_) {}
  }

  // Bundle: every entry with a datamap on disk (fresh uploads + ledger
  // dedup hits) becomes a .watch-list member; custom items carry their
  // userEdited metadata row + poster.
  final uploaded = manifest.entries
      .where((e) =>
          (e.status == 'uploaded' || e.status == 'already-uploaded') &&
          e.name != null)
      .toList();
  File? bundleFile;
  if (doBundle && uploaded.isNotEmpty) {
    final bundleEntries = <BundleOutEntry>[];
    for (final e in uploaded) {
      final mapPath = e.datamap;
      if (mapPath == null || !File(mapPath).existsSync()) {
        stdout.writeln('note: no datamap on disk for "${e.name}" — left '
            'out of the bundle (ledger export can rebuild once found).');
        continue;
      }
      bundleEntries.add(BundleOutEntry(
        name: e.name!,
        datamapBytes: File(mapPath).readAsBytesSync(),
        custom: e.custom,
        description: e.description,
        artBytes: e.custom && e.art != null && File(e.art!).existsSync()
            ? File(e.art!).readAsBytesSync()
            : null,
        customTitle: e.customFields['title']?.toString() ??
            ((e.customFields['artist'] != null &&
                    e.customFields['album'] != null)
                ? '${e.customFields['artist']} - ${e.customFields['album']}'
                : null),
        customYear: e.customFields['year'] as int?,
        mediaType: e.custom ? (e.type == 'music' ? 'music' : null) : null,
      ));
    }
    if (bundleEntries.isNotEmpty) {
      bundleFile = File(p.join(manifestFile.absolute.parent.path,
          '${manifest.listName}.watch-list'));
      writeBundle(bundleFile, manifest.listName, bundleEntries);
      stdout.writeln('\nbundle: ${bundleFile.path} '
          '(${bundleEntries.length} entr(y/ies))');
    }
  }

  final ok = manifest.entries.where((e) => e.status == 'uploaded').length;
  final dedup =
      manifest.entries.where((e) => e.status == 'already-uploaded').length;
  final failed =
      manifest.entries.where((e) => e.status == 'failed').toList();
  final summary = StringBuffer()
    ..writeln('W@tch upload "${manifest.listName}": '
        '$ok uploaded, $dedup deduped'
        '${failed.isNotEmpty ? ', ${failed.length} FAILED' : ''}'
        '${blocked > 0 ? ', $blocked needing attention' : ''}.');
  for (final f in failed) {
    summary.writeln('  ✗ ${p.basename(f.source)}: ${f.error}');
  }
  if (bundleFile != null) summary.writeln('bundle: ${bundleFile.path}');
  stdout.writeln('\n${summary.toString().trim()}');
  if (doTelegram) {
    await telegramPing(summary.toString().trim());
  }
  manifest.save();
  return failed.isEmpty ? 0 : 1;
}
