import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'ant.dart';
import 'config.dart';
import 'ledger.dart';
import 'manifest.dart';
import 'match.dart';
import 'musicbrainz.dart';
import 'probe.dart';
import 'sidecar.dart';
import 'acoustid.dart';
import 'tmdb.dart';

/// `prepare` — all the interactive work, none of the paying. Scans the
/// given files/folders, dedupes against the content-hash ledger, matches
/// each file against MusicBrainz/TMDB, regenerates canonical names,
/// fetches artwork for match verification, writes sidecar skeletons for
/// failures, and ends with a manifest + cost estimate + wallet check so
/// `upload` can run unattended.
Future<int> runPrepare(List<String> args) async {
  String manifestPath = 'watchit-manifest.yaml';
  String? listName;
  var yes = false;
  String? forcedType;
  final paths = <String>[];
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--manifest':
        manifestPath = args[++i];
      case '--list-name':
        listName = args[++i];
      case '--yes' || '-y':
        yes = true;
      case '--music':
        forcedType = 'music';
      case '--video':
        forcedType = 'video';
      default:
        if (args[i].startsWith('-')) {
          stderr.writeln('unknown option ${args[i]}');
          return 2;
        }
        paths.add(args[i]);
    }
  }
  if (paths.isEmpty) {
    stderr.writeln('usage: watchit-upload prepare [--manifest PATH] '
        '[--list-name NAME] [--yes] [--music|--video] <files/folders…>');
    return 2;
  }

  final config = CliConfig.load()..ensureDirs();
  final ledger = Ledger.load(config.ledgerFile);
  final files = _collectFiles(paths);
  if (files.isEmpty) {
    stderr.writeln('no media files found under ${paths.join(', ')}');
    return 1;
  }
  stdout.writeln('${files.length} media file(s) found; '
      'ledger knows ${ledger.length} upload(s).');

  final manifestFile = File(manifestPath);
  final manifest = manifestFile.existsSync()
      ? Manifest.load(manifestFile)
      : Manifest(
          file: manifestFile,
          listName: listName ??
              p.basenameWithoutExtension(
                  p.basename(Directory.current.path)),
          created: DateTime.now().toIso8601String(),
          entries: [],
        );
  if (listName != null) manifest.listName = listName;

  final mb = MusicBrainz(cacheDir: config.mbCacheDir);
  final tmdb = config.tmdbKey != null ? Tmdb(config.tmdbKey!) : null;
  final fpcalc = await fpcalcAvailable();
  if (!fpcalc || config.acoustidKey == null) {
    stdout.writeln('note: audio fingerprinting off '
        '(${!fpcalc ? 'fpcalc not installed' : 'no acoustid_key'}) — '
        'using tags + MusicBrainz search for music.');
  }
  if (tmdb == null) {
    stdout.writeln('note: no TMDB key — video files will need sidecars '
        '(set tmdb_key in ${config.homeDir.path}/config.yaml).');
  }
  final matcher =
      Matcher(config: config, mb: mb, tmdb: tmdb, fpcalcPresent: fpcalc);

  var ready = 0, dedup = 0, attention = 0, skipped = 0;
  for (final path in files) {
    final existing = manifest.bySource(path);
    final sidecar = Sidecar.read(path);
    if (existing != null &&
        (existing.status == 'uploaded' ||
            existing.status == 'already-uploaded' ||
            (existing.status == 'ready' && sidecar == null))) {
      if (existing.status == 'ready') ready++;
      continue; // Already prepared; a new sidecar re-opens the entry.
    }

    if (_cueSiblingProblem(path)) {
      stdout.writeln('SKIP  ${p.basename(path)} — cue+single-file album '
          'rip; split into tracks first (e.g. with ffmpeg/shnsplit)');
      _upsert(manifest, existing,
          ManifestEntry(source: path, status: 'skipped')
            ..error = 'cue+single-file rip — split first');
      skipped++;
      continue;
    }

    stdout.write('…     ${p.basename(path)}\r');
    final sha = await _sha256File(path);
    final size = File(path).lengthSync();

    final hit = ledger.lookup(sha);
    if (hit != null) {
      stdout.writeln('HAVE  ${p.basename(path)} → already uploaded as '
          '"${hit.name}" (${hit.date.split('T').first})');
      _upsert(
          manifest,
          existing,
          ManifestEntry(source: path, status: 'already-uploaded')
            ..sha256 = sha
            ..sizeBytes = size
            ..name = hit.name
            ..address = hit.address
            ..datamap = hit.datamapPath);
      dedup++;
      continue;
    }

    final probe = await probeFile(path);
    var outcome = await matcher.matchFile(path, probe,
        sidecar: sidecar, forcedType: forcedType);

    // Interactive review: auto-accept high confidence, one-keystroke
    // confirm the rest; m toggles music/video for ambiguous mp4s.
    if (!yes && outcome.matched) {
      outcome = await _review(path, probe, outcome, matcher, mb, tmdb);
    }

    if (outcome.skip) {
      _upsert(manifest, existing,
          ManifestEntry(source: path, status: 'skipped'));
      skipped++;
      continue;
    }
    if (!outcome.matched ||
        (yes && outcome.confidence == 'confirm')) {
      final note = outcome.matched
          ? 'match needs confirmation (ran with --yes): ${outcome.note}'
          : outcome.note;
      stdout.writeln('????  ${p.basename(path)} — $note');
      final d = outcome.sidecarDefaults;
      Sidecar.writeSkeleton(path,
          type: outcome.type,
          title: d['title']?.toString(),
          year: d['year'] as int?,
          artist: d['artist']?.toString(),
          album: d['album']?.toString(),
          track: d['track'] as int?,
          season: d['season'] as int?,
          episode: d['episode'] as int?,
          note: note);
      _upsert(
          manifest,
          existing,
          ManifestEntry(source: path, status: 'needs-attention')
            ..sha256 = sha
            ..sizeBytes = size
            ..type = outcome.type
            ..error = note);
      attention++;
      continue;
    }

    String? artPath;
    if (outcome.artBytes != null) {
      artPath = p.join(config.artCacheDir.path,
          '${sha256.convert(outcome.artBytes!).toString().substring(0, 12)}.jpg');
      File(artPath).writeAsBytesSync(outcome.artBytes!);
    }
    stdout.writeln('OK    ${p.basename(path)}');
    stdout.writeln('  →   ${outcome.name}'
        '${artPath != null ? '  [art ✓]' : '  [no art]'}');
    _upsert(
        manifest,
        existing,
        ManifestEntry(source: path, status: 'ready')
          ..sha256 = sha
          ..sizeBytes = size
          ..type = outcome.type
          ..name = outcome.name
          ..ids = outcome.ids
          ..matchMethod = outcome.method
          ..confidence = outcome.confidence
          ..art = artPath
          ..description = outcome.description
          ..custom = outcome.custom
          ..customFields = outcome.customFields);
    ready++;
  }
  mb.close();
  tmdb?.close();

  // Cost estimate: one live quote, scaled per-chunk across the batch
  // (4 MiB chunks, 3-chunk floor) + wallet balance so a payment surprise
  // can't kill the overnight run.
  final readyEntries =
      manifest.entries.where((e) => e.status == 'ready').toList();
  if (readyEntries.isNotEmpty) {
    final ant = Ant();
    final quote = await ant.cost(readyEntries.first.source);
    if (quote != null) {
      final perChunkAtto = quote.storageCostAtto ~/
          BigInt.from(quote.chunkCount == 0 ? 1 : quote.chunkCount);
      var totalChunks = 0;
      for (final e in readyEntries) {
        totalChunks += Ant.chunksFor(e.sizeBytes ?? 0);
      }
      final totalAtto = perChunkAtto * BigInt.from(totalChunks);
      final totalAnt = totalAtto / BigInt.from(10).pow(18);
      manifest.cost = {
        'estimated_total_ant': totalAnt.toStringAsFixed(6),
        'total_chunks': totalChunks,
        'per_chunk_atto': '$perChunkAtto',
        'quoted_at': DateTime.now().toIso8601String(),
      };
      stdout.writeln('\nEstimated cost: ~${totalAnt.toStringAsFixed(6)} ANT '
          'for $totalChunks chunks across ${readyEntries.length} file(s) '
          '(+ gas).');
      if (ant.walletConfigured) {
        final balance = await ant.walletBalance();
        if (balance != null) {
          manifest.cost['wallet'] = balance;
          stdout.writeln('Wallet: $balance');
        }
      } else {
        stdout.writeln('SECRET_KEY not set — wallet balance unknown; '
            '`upload` will need it exported.');
      }
    } else {
      stdout.writeln('\nCost estimate unavailable (ant file cost failed — '
          'network?). upload will still work.');
    }
  }

  manifest.save();
  stdout
    ..writeln('\nManifest: ${manifest.file.path}')
    ..writeln('  ready: $ready   already-uploaded: $dedup   '
        'needs-attention: $attention   skipped: $skipped')
    ..writeln(attention > 0
        ? '  → edit the .watchit.yaml sidecars next to the flagged files '
            'and re-run prepare.'
        : '  → review/edit the manifest if you like, then run: '
            'watchit-upload upload --manifest ${manifest.file.path}');
  return 0;
}

void _upsert(Manifest m, ManifestEntry? existing, ManifestEntry entry) {
  if (existing == null) {
    m.entries = [...m.entries, entry];
  } else {
    m.entries[m.entries.indexOf(existing)] = entry;
  }
}

List<String> _collectFiles(List<String> paths) {
  final out = <String>[];
  final exts = {...kAudioExtensions, ...kVideoExtensions};
  for (final path in paths) {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.file) {
      out.add(p.absolute(path));
    } else if (type == FileSystemEntityType.directory) {
      final files = Directory(path)
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((f) =>
              exts.contains(p.extension(f.path).toLowerCase()) &&
              !p.basename(f.path).startsWith('.'))
          .map((f) => p.absolute(f.path))
          .toList();
      files.sort();
      out.addAll(files);
    } else {
      stderr.writeln('warning: $path not found');
    }
  }
  return out;
}

/// A `.cue` sheet beside a lone audio file = an unsplit album rip.
bool _cueSiblingProblem(String path) {
  final ext = p.extension(path).toLowerCase();
  if (!kAudioExtensions.contains(ext)) return false;
  final dir = File(path).parent;
  var cue = false, audio = 0;
  for (final f in dir.listSync().whereType<File>()) {
    final e = p.extension(f.path).toLowerCase();
    if (e == '.cue') cue = true;
    if (kAudioExtensions.contains(e)) audio++;
  }
  return cue && audio == 1;
}

Future<String> _sha256File(String path) async {
  final input = File(path).openRead();
  final digest = await sha256.bind(input).first;
  return digest.toString();
}

/// One-keystroke interactive confirm (beets-style): high-confidence
/// matches print and pass, the rest wait for a key. Also the door to the
/// manual search / paste-id path and the music↔video toggle.
Future<MatchOutcome> _review(String path, MediaProbe? probe,
    MatchOutcome outcome, Matcher matcher, MusicBrainz mb, Tmdb? tmdb) async {
  while (true) {
    if (outcome.confidence == 'high' && outcome.method != 'search') {
      return outcome; // auto-accept: id-backed match
    }
    stdout
      ..writeln('CONFIRM  ${p.basename(path)}')
      ..writeln('  match: ${outcome.note}')
      ..writeln('  name:  ${outcome.name}')
      ..write('  [Y]es  [n]o→sidecar  [s]kip  [m]usic/video toggle  '
          '[e]dit search  [i]d paste ? ');
    final key = (stdin.readLineSync() ?? '').trim().toLowerCase();
    switch (key) {
      case '' || 'y':
        return outcome;
      case 'n':
        return MatchOutcome(
            type: outcome.type,
            note: 'match rejected at confirm',
            sidecarDefaults: outcome.sidecarDefaults);
      case 's':
        return MatchOutcome(type: outcome.type, skip: true);
      case 'm':
        final flipped = outcome.type == 'music' ? 'video' : 'music';
        outcome =
            await matcher.matchFile(path, probe, forcedType: flipped);
        if (!outcome.matched) return outcome;
      case 'e':
        final manual = await _manualSearch(path, probe, outcome.type,
            matcher, mb, tmdb);
        if (manual != null) outcome = manual;
      case 'i':
        final manual =
            await _pasteId(path, probe, outcome.type, matcher);
        if (manual != null) outcome = manual;
      default:
        continue;
    }
    if (outcome.matched && outcome.confidence == 'high' &&
        outcome.method == 'sidecar') {
      return outcome;
    }
  }
}

Future<MatchOutcome?> _manualSearch(String path, MediaProbe? probe,
    String type, Matcher matcher, MusicBrainz mb, Tmdb? tmdb) async {
  if (type == 'music') {
    stdout.write('  artist: ');
    final artist = stdin.readLineSync()?.trim() ?? '';
    stdout.write('  album: ');
    final album = stdin.readLineSync()?.trim() ?? '';
    if (artist.isEmpty || album.isEmpty) return null;
    final hits = await mb.searchReleases(artist, album, limit: 8);
    if (hits.isEmpty) {
      stdout.writeln('  no results.');
      return null;
    }
    for (final (i, h) in hits.indexed) {
      stdout.writeln('   ${i + 1}. ${h.artist} — ${h.title}'
          '${h.year != null ? ' (${h.year})' : ''}  [${h.mbid}]');
    }
    stdout.write('  pick 1-${hits.length} (empty = cancel): ');
    final n = int.tryParse(stdin.readLineSync()?.trim() ?? '');
    if (n == null || n < 1 || n > hits.length) return null;
    return matcher.matchFile(path, probe,
        sidecar: Sidecar(
            type: 'music',
            releaseMbid: hits[n - 1].mbid,
            track: probe?.trackNumber));
  }
  if (tmdb == null) return null;
  stdout.write('  title (add year after a comma, e.g. "Nosferatu, 1922"): ');
  final q = stdin.readLineSync()?.trim() ?? '';
  if (q.isEmpty) return null;
  final parts = q.split(',');
  final year = parts.length > 1 ? int.tryParse(parts.last.trim()) : null;
  final title = parts.first.trim();
  stdout.write('  tv show? [y/N]: ');
  final tv = (stdin.readLineSync() ?? '').trim().toLowerCase() == 'y';
  final hits = await tmdb.search(title, year: year, tv: tv);
  if (hits.isEmpty) {
    stdout.writeln('  no results.');
    return null;
  }
  for (final (i, h) in hits.take(8).indexed) {
    stdout.writeln('   ${i + 1}. ${h.title}'
        '${h.year != null ? ' (${h.year})' : ''}  [${h.mediaType} '
        '${h.tmdbId}]');
  }
  stdout.write('  pick 1-${hits.take(8).length} (empty = cancel): ');
  final n = int.tryParse(stdin.readLineSync()?.trim() ?? '');
  if (n == null || n < 1 || n > hits.take(8).length) return null;
  final pick = hits[n - 1];
  return matcher.matchFile(path, probe,
      sidecar: Sidecar(
          type: 'video', tmdb: pick.tmdbId, tmdbTv: pick.mediaType == 'tv'));
}

Future<MatchOutcome?> _pasteId(
    String path, MediaProbe? probe, String type, Matcher matcher) async {
  stdout.write('  paste an id/URL (MusicBrainz release, IMDb tt…, '
      'tmdb movie:N / tv:N): ');
  final raw = stdin.readLineSync()?.trim() ?? '';
  if (raw.isEmpty) return null;
  final mbid = RegExp(
          r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
          caseSensitive: false)
      .firstMatch(raw);
  final imdb = RegExp(r'tt\d+').firstMatch(raw);
  final tmdbM = RegExp(r'^(movie|tv)\s*[:/]\s*(\d+)$').firstMatch(raw);
  if (mbid != null) {
    return matcher.matchFile(path, probe,
        sidecar: Sidecar(
            type: 'music',
            releaseMbid: mbid.group(0)!.toLowerCase(),
            track: probe?.trackNumber));
  }
  if (imdb != null) {
    return matcher.matchFile(path, probe,
        sidecar: Sidecar(type: 'video', imdb: imdb.group(0)));
  }
  if (tmdbM != null) {
    return matcher.matchFile(path, probe,
        sidecar: Sidecar(
            type: 'video',
            tmdb: int.parse(tmdbM.group(2)!),
            tmdbTv: tmdbM.group(1) == 'tv'));
  }
  stdout.writeln('  not recognized.');
  return null;
}
