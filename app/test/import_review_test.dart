import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/screens/import_review_screen.dart';
import 'package:watchit/services/import_review.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/match_review.dart';
import 'package:watchit/theme/tokens.dart';
import 'package:watchit_upload/watchit_upload.dart' as cli;

/// The datamap import match/review flow (import_review.dart): the
/// uploader's carousel semantics driven by names alone — auto-accept
/// for id-backed matches, cards for search results and no-matches,
/// album grouping from canonical names, the canonical rename on apply,
/// and the userEdited metadata seed for manual (case-B) details.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory configDir;
  late AppDatabase db;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await LibraryStore.useForTesting(db);
    ImportReviewSession.resetForTesting();
    configDir = Directory.systemTemp.createTempSync('wi-import-test');
  });

  tearDown(() {
    ImportReviewSession.resetForTesting();
    try {
      configDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  ImportCandidate cand(String name, [String? addr]) => ImportCandidate(
      name: name,
      address: addr ?? name.hashCode.toRadixString(16).padLeft(64, '0'),
      sizeBytes: 100);

  /// A matcher stub keyed by name; unknown names return no-match. A
  /// manual-entry sidecar answers like the real matcher (custom case-B
  /// outcome); a release-mbid sidecar like the id-backed path.
  Future<cli.MatchOutcome> Function(String, cli.MediaProbe?,
      {cli.Sidecar? sidecar, String? forcedType}) scripted(
          Map<String, cli.MatchOutcome> byName) =>
      (path, probe, {sidecar, forcedType}) async {
        if (sidecar != null && sidecar.isManualEntry) {
          return cli.MatchOutcome(
            type: sidecar.type ?? 'video',
            name: '${sidecar.title}'
                '${sidecar.year != null ? ' (${sidecar.year})' : ''}.mp4',
            method: 'sidecar',
            confidence: 'high',
            custom: true,
            customFields: {
              'title': sidecar.title,
              if (sidecar.year != null) 'year': sidecar.year,
            },
            description: sidecar.description,
          );
        }
        return byName[path] ??
            cli.MatchOutcome(type: 'video', note: 'no match for $path');
      };

  Future<void> waitFor(ImportReviewSession s, bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(done(), isTrue);
  }

  test('auto-accept, confirm card, reject-as-is and skip land right',
      () async {
    final session = ImportReviewSession.instance;
    session.matchOverride = scripted({
      'Auto.mkv': cli.MatchOutcome(
        type: 'video',
        name: 'Auto Movie (1968) {imdb-tt0063350}.mkv',
        ids: {'imdb': 'tt0063350'},
        method: 'tags',
        confidence: 'high',
        note: 'Auto Movie (1968)',
      ),
      'Confirm.mkv': cli.MatchOutcome(
        type: 'video',
        name: 'Confirm Movie (1970).mkv',
        method: 'search',
        confidence: 'confirm',
        note: 'Confirm Movie (1970)',
      ),
      // NoMatch.mkv and Skip.mkv fall through to no-match.
    });
    List<MediaEntry>? added;
    List<String>? lists;
    session.addOverride = (entries, chosen) async {
      added = entries;
      lists = chosen;
    };

    final decisions = <String>[];
    session.addListener(() {
      final c = session.pendingConfirm;
      if (c == null || decisions.contains(c.path)) return;
      decisions.add(c.path);
      switch (c.path) {
        case 'Confirm.mkv':
          session.confirmAccept();
        case 'NoMatch.mkv':
          session.confirmReject();
        case 'Skip.mkv':
          session.confirmSkip();
      }
    });

    await session.start(
      files: [
        cand('Auto.mkv', 'aa' * 32),
        cand('Confirm.mkv', 'bb' * 32),
        cand('NoMatch.mkv', 'cc' * 32),
        cand('Skip.mkv', 'dd' * 32),
      ],
      lists: ['Films'],
      configDir: configDir,
    );
    await waitFor(session, () => session.stage == ImportReviewStage.done);

    // The tags match never paused the flow but still has a decided card.
    expect(session.confirmables, hasLength(4));
    expect(decisions, ['Confirm.mkv', 'NoMatch.mkv', 'Skip.mkv']);
    expect(session.matchedCount, 2);
    expect(session.asIsCount, 1);
    expect(session.skippedCount, 1);
    expect(session.addedCount, 3);
    expect(lists, ['Films']);
    expect(added!.map((e) => e.name), [
      'Auto Movie (1968) {imdb-tt0063350}.mkv',
      'Confirm Movie (1970).mkv',
      'NoMatch.mkv', // rejected → original name kept
    ]);
    expect(added!.map((e) => e.address),
        ['aa' * 32, 'bb' * 32, 'cc' * 32]);
  });

  test('a {mbid-…} name goes through an id-backed sidecar (auto-accept)',
      () async {
    const mbid = '499485cb-1a2b-3c4d-5e6f-708192a3b4c5';
    final session = ImportReviewSession.instance;
    cli.Sidecar? seen;
    session.matchOverride = (path, probe, {sidecar, forcedType}) async {
      seen = sidecar;
      return cli.MatchOutcome(
        type: 'music',
        name: path,
        ids: {'release_mbid': mbid},
        method: 'sidecar',
        confidence: 'high',
        note: 'Artist — Album (1969), track 1 "Song"',
      );
    };
    session.addOverride = (entries, chosen) async {};

    await session.start(
      files: [
        cand('Artist - Album (1969) - 01 Song {mbid-$mbid}.flac'),
      ],
      lists: ['Music'],
      configDir: configDir,
    );
    await waitFor(session, () => session.stage == ImportReviewStage.done);

    expect(seen, isNotNull);
    expect(seen!.releaseMbid, mbid);
    expect(seen!.track, 1);
    expect(session.matchedCount, 1);
  });

  test('canonical track names group into ONE album card and auto-accept '
      'whole', () async {
    const mbid = '11111111-2222-3333-4444-555555555555';
    final session = ImportReviewSession.instance;
    session.matchOverride = (path, probe, {sidecar, forcedType}) async =>
        cli.MatchOutcome(
          type: 'music',
          name: path,
          ids: {'release_mbid': mbid},
          method: sidecar?.releaseMbid != null ? 'sidecar' : 'tags',
          confidence: 'high',
          note: 'Artist — Album (1969), track 1 "A"',
        );
    List<MediaEntry>? added;
    session.addOverride = (entries, chosen) async => added = entries;

    await session.start(
      files: [
        // Deliberately out of order — the album card sorts by track.
        cand('Artist - Album (1969) - 02 B.flac'),
        cand('Artist - Album (1969) - 01 A.flac'),
      ],
      lists: ['Music'],
      configDir: configDir,
    );
    await waitFor(session, () => session.stage == ImportReviewStage.done);

    expect(session.confirmables, hasLength(1));
    final album = session.confirmables.single as AlbumConfirm;
    expect(album.decided, isTrue);
    expect(album.tracks, [
      'Artist - Album (1969) - 01 A.flac',
      'Artist - Album (1969) - 02 B.flac',
    ]);
    expect(added, hasLength(2));
    expect(session.matchedCount, 2);
  });

  test('manual details (case B) seed a userEdited metadata row + poster',
      () async {
    final session = ImportReviewSession.instance;
    session.matchOverride = scripted({}); // everything no-match
    session.addOverride = (entries, chosen) async {};
    final postersDir =
        Directory('${configDir.path}/posters')..createSync();
    session.postersDirProvider = () async => postersDir;

    var entered = false;
    session.addListener(() {
      final c = session.pendingConfirm;
      if (c == null || entered) return;
      entered = true;
      session.confirmManual(cli.Sidecar(
        type: 'video',
        title: 'Holiday 2020',
        year: 2020,
        description: 'Our trip.',
      ));
    });

    await session.start(
      files: [cand('VID_1234.mp4')],
      lists: ['Home videos'],
      configDir: configDir,
    );
    await waitFor(session, () => session.stage == ImportReviewStage.done);

    expect(session.customCount, 1);
    expect(session.items.single.finalName, 'Holiday 2020 (2020).mp4');
    final row = await db.select(db.metadataCache).getSingle();
    expect(row.lookupKey, 'movie:holiday 2020:2020');
    expect(row.title, 'Holiday 2020');
    expect(row.year, 2020);
    expect(row.overview, 'Our trip.');
    expect(row.userEdited, isTrue);
  });

  test('finishRemainingAsIs adds undecided entries under their original '
      'names', () async {
    final session = ImportReviewSession.instance;
    session.matchOverride = scripted({}); // both wait for eyes
    List<MediaEntry>? added;
    session.addOverride = (entries, chosen) async => added = entries;

    await session.start(
      files: [cand('One.mkv', 'aa' * 32), cand('Two.mkv', 'bb' * 32)],
      lists: ['Films'],
      configDir: configDir,
    );
    await waitFor(
        session, () => session.stage == ImportReviewStage.reviewing);
    await session.finishRemainingAsIs();

    expect(session.stage, ImportReviewStage.done);
    expect(added!.map((e) => e.name), ['One.mkv', 'Two.mkv']);
    expect(session.asIsCount, 2);
  });

  test('cancelAll adds nothing and frees the session', () async {
    final session = ImportReviewSession.instance;
    session.matchOverride = scripted({});
    var addCalls = 0;
    session.addOverride = (entries, chosen) async => addCalls++;

    await session.start(
      files: [cand('One.mkv')],
      lists: ['Films'],
      configDir: configDir,
    );
    await waitFor(
        session, () => session.stage == ImportReviewStage.reviewing);
    session.cancelAll();

    expect(session.stage, ImportReviewStage.idle);
    expect(addCalls, 0);
  });

  group('importAlbumKey', () {
    test('groups by embedded mbid, then parsed artist/album, then guess;'
        ' bare and non-audio names never group', () {
      const mbid = '499485cb-1a2b-3c4d-5e6f-708192a3b4c5';
      expect(
        importAlbumKey('Artist - Album (1969) - 01 A {mbid-$mbid}.flac'),
        'mbid:$mbid',
      );
      expect(
        importAlbumKey('Artist - Album (1969) - 01 A.flac'),
        importAlbumKey('ARTIST - Album (1969) - 02 B.flac'),
      );
      // No track number → canonical parse fails, the `Artist - Album -
      // Title` guess still groups.
      expect(
        importAlbumKey('Artist - Album - Some Song.mp3'),
        importAlbumKey('Artist - Album - Other Song.mp3'),
      );
      expect(importAlbumKey('Loose Song.mp3'), isNull);
      expect(importAlbumKey('A Movie (2020).mkv'), isNull);
    });
  });

  testWidgets('review screen: confirm card → accept → done summary',
      (tester) async {
    final session = ImportReviewSession.instance;
    session.matchOverride = scripted({
      'Confirm.mkv': cli.MatchOutcome(
        type: 'video',
        name: 'Confirm Movie (1970).mkv',
        method: 'search',
        confidence: 'confirm',
        note: 'Confirm Movie (1970)',
      ),
    });
    List<MediaEntry>? added;
    session.addOverride = (entries, chosen) async => added = entries;

    await session.start(
      files: [cand('Confirm.mkv')],
      lists: ['Films'],
      configDir: configDir,
    );
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: const ImportReviewScreen(),
    ));
    await tester.pumpAndSettle();

    // The uncertain search match raised its card.
    expect(find.text('CONFIRM MATCH'), findsOneWidget);
    expect(find.text('Confirm Movie (1970)'), findsOneWidget);
    // Import wording, not upload wording.
    expect(find.text('Keep name as-is'), findsOneWidget);
    expect(find.text('Don\'t add'), findsOneWidget);

    await tester.tap(find.text('Use this match'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Added 1 entry to Films'), findsOneWidget);
    expect(find.text('Confirm Movie (1970).mkv'), findsOneWidget);
    expect(added!.single.name, 'Confirm Movie (1970).mkv');
  });
}
