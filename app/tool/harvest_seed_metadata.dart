// Regenerates the bundled seed-catalog metadata (see docs/SEED-CATALOG.md):
// resolves every kSeedLists entry against TMDB with the app's own matcher
// (identical lookup keys, row shape, and image file names to
// metadata_service.dart) and writes assets/seed_metadata/metadata.json +
// assets/seed_metadata/posters/*.jpg.
//
// Run from app/ with the repo-root .env loaded:
//   set -a; source ../.env; set +a; dart run tool/harvest_seed_metadata.dart
//
// Fails loudly on any unmatched entry — every catalog title is a verified
// TMDB-known film/episode, so a miss means a name regression, not a gap.

import 'dart:convert';
import 'dart:io';

import 'package:watchit/services/metadata.dart';
import 'package:watchit/services/seed_catalog.dart';
import 'package:watchit/services/tmdb_client.dart';

Future<void> main() async {
  final apiKey = Platform.environment['TMDB_API_KEY'] ?? '';
  if (apiKey.isEmpty) {
    stderr.writeln('TMDB_API_KEY is not set — source the repo-root .env');
    exitCode = 1;
    return;
  }

  final outDir = Directory('assets/seed_metadata');
  final postersDir = Directory('${outDir.path}/posters');
  await postersDir.create(recursive: true);

  final client = TmdbClient(apiKey: apiKey);
  final rows = <Map<String, dynamic>>[];
  final failures = <String>[];
  final imagesSaved = <String>{};

  Future<String?> saveImage(String? cdnPath, String file,
      Future<List<int>> Function(String) fetch) async {
    if (cdnPath == null) return null;
    if (!imagesSaved.contains(file)) {
      final bytes = await fetch(cdnPath);
      await File('${postersDir.path}/$file').writeAsBytes(bytes, flush: true);
      imagesSaved.add(file);
    }
    return file;
  }

  try {
    for (final list in kSeedLists) {
      for (final entry in list.entries) {
        final parsed = parseMediaName(entry.name);
        final key = parsed.lookupKey;
        final TmdbMatch? match;
        try {
          match = await client.lookup(parsed);
        } on TmdbException catch (e) {
          failures.add('${entry.name}: $e');
          continue;
        }
        if (match == null) {
          failures.add('${entry.name}: no TMDB match for key $key');
          continue;
        }
        // Image file names exactly as metadata_service.dart caches them,
        // so a user's own later TMDB fetches reuse the seeded files.
        final id = '${match.mediaType}_${match.tmdbId}';
        final poster = await saveImage(
            match.posterPath,
            match.season == null ? '$id.jpg' : '${id}_s${match.season}.jpg',
            client.fetchPoster);
        final showPoster = match.season == null
            ? null
            : await saveImage(
                match.showPosterPath, '$id.jpg', client.fetchPoster);
        final still = match.season == null
            ? null
            : await saveImage(
                match.stillPath,
                '${id}_s${match.season}e${match.episode}_still.jpg',
                client.fetchStill);
        rows.add({
          'lookupKey': key,
          'title': match.title,
          'year': match.year,
          'overview': match.overview,
          'category': match.category,
          'episodeLabel': match.episodeLabel,
          'posterFile': poster,
          'mediaType': match.mediaType,
          'tmdbId': match.tmdbId,
          'rating': match.rating,
          'showOverview': match.showOverview,
          'seasonOverview': match.seasonOverview,
          'airDate': match.airDate,
          'stillFile': still,
          'showPosterFile': showPoster,
        });
        stdout.writeln('OK  ${entry.name} → ${match.title} '
            '(${match.mediaType}/${match.tmdbId})');
      }
    }
  } finally {
    client.close();
  }

  if (failures.isNotEmpty) {
    stderr.writeln('\nFAILED (${failures.length}):');
    failures.forEach(stderr.writeln);
    exitCode = 1;
    return;
  }

  const encoder = JsonEncoder.withIndent('  ');
  await File('${outDir.path}/metadata.json').writeAsString(
    '${encoder.convert({
      'version': 1,
      'attribution': 'This product uses the TMDB API but is not endorsed '
          'or certified by TMDB.',
      'entries': rows,
    })}\n',
  );
  stdout.writeln('\n${rows.length} rows, ${imagesSaved.length} images → '
      '${outDir.path}/');
}
