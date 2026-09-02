import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchit/db/app_database.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/screens/batch_upload_screen.dart';
import 'package:watchit/screens/publish_screen.dart';
import 'package:watchit/services/batch_upload.dart';
import 'package:watchit/services/bundle.dart';
import 'package:watchit/services/ffmpeg.dart';
import 'package:watchit/services/publish_api.dart';
import 'package:watchit/services/publish_plan.dart'
    show MediaProbe, PublishTier;
import 'package:watchit/services/user_metadata.dart' show metadataRowFor;
import 'package:watchit/services/terms.dart';
import 'package:watchit/theme/tokens.dart';
import 'package:watchit_upload/watchit_upload.dart' as cli;

/// The in-app batch uploader (the CLI pipeline behind a screen):
/// prepare/confirm/upload against the fake embedded server, shared
/// ledger dedup, and the .watch-list bundle output.
import 'fake_embedded_http.dart';

class _NoFfmpeg extends FfmpegService {
  @override
  Future<bool> get available async => false;
}

/// App-side probe/encode without real processes: probes come from a
/// canned map by base name, encodes write a small real file (the
/// session hashes and uploads it) and report completion.
class _FakeFfmpeg extends FfmpegService {
  _FakeFfmpeg(this.probes);
  final Map<String, MediaProbe?> probes;
  final List<String> encodes = [];

  @override
  Future<bool> get available async => true;

  @override
  Future<MediaProbe?> probe(String path) async =>
      probes[path.split('/').last];

  @override
  Future<void> encode({
    required String input,
    required String output,
    required PublishTier tier,
    MediaProbe? probe,
    void Function(double? fraction)? onProgress,
  }) async {
    encodes.add(output.split('/').last);
    File(output).writeAsBytesSync(List.filled(32, encodes.length));
    onProgress?.call(1);
  }

  @override
  void cancel() {}
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late FakeEmbeddedHttp fake;
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(
        {'terms_accepted_version_v1': kTermsVersion});
    BatchUploadSession.resetForTesting();
    // The done-stage seed + auto-add touch the library database.
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    fake = FakeEmbeddedHttp();
    HttpOverrides.global = fake;
    tempDir = Directory.systemTemp.createTempSync('wi-batch-test');
  });

  tearDown(() {
    BatchUploadSession.resetForTesting();
    HttpOverrides.global = null;
    tempDir.deleteSync(recursive: true);
  });

  File mediaFile(String name, [int fill = 1]) =>
      File('${tempDir.path}/$name')
        ..writeAsBytesSync(List.filled(64, fill));

  Directory dirIn(String name) =>
      Directory('${tempDir.path}/$name')..createSync(recursive: true);

  PublishApi api() => PublishApi(base: FakeEmbeddedHttp.base);

  /// A matcher stub keyed by base name; unknown files return no-match.
  Future<cli.MatchOutcome> Function(String, cli.MediaProbe?,
      {cli.Sidecar? sidecar, String? forcedType}) scriptedMatcher(
          Map<String, cli.MatchOutcome> byName) =>
      (path, probe, {sidecar, forcedType}) async {
        // A manual-entry sidecar answers like the real matcher: custom
        // case-B outcome with the manual fields.
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
        final name = path.split('/').last;
        return byName[name] ??
            cli.MatchOutcome(type: 'video', note: 'no match for $name');
      };

  test('prepare→confirm→upload: statuses, ledger, bundle', () async {
    fake.wallet = {'configured': true, 'address': '0xabc', 'storage': 'file'};
    final auto = mediaFile('auto.mp4', 1);
    final confirmMe = mediaFile('confirm.mp4', 2);
    final noMatch = mediaFile('nomatch.mp4', 3);
    final addrA = 'aa' * 32, addrB = 'bb' * 32;
    fake.uploadResults = [
      {
        'address': addrA,
        'size': 64,
        'chunks': 3,
        'cost_atto': '1000',
        'gas_wei': '1',
      },
      {
        'address': addrB,
        'size': 64,
        'chunks': 3,
        'cost_atto': '1000',
        'gas_wei': '1',
      },
    ];
    fake.datamaps[addrA] = [1, 2, 3];
    fake.datamaps[addrB] = [4, 5, 6];

    final session = BatchUploadSession.instance;
    session.matchOverride = scriptedMatcher({
      'auto.mp4': cli.MatchOutcome(
        type: 'video',
        name: 'Auto Movie (1968) {imdb-tt0063350}.mp4',
        ids: {'imdb': 'tt0063350'},
        method: 'tags',
        confidence: 'high',
        note: 'Auto Movie (1968)',
      ),
      'confirm.mp4': cli.MatchOutcome(
        type: 'video',
        name: 'Confirm Movie (1970).mp4',
        method: 'search',
        confidence: 'confirm',
        note: 'Confirm Movie (1970)',
      ),
    });
    session.probeOverride = (path) async => null;

    final confirmSeen = <String>[];
    session.addListener(() {
      final c = session.pendingConfirm;
      if (c != null && !confirmSeen.contains(c.path)) {
        confirmSeen.add(c.path);
        session.confirmAccept();
      }
    });

    await session.startPrepare(
      api: api(),
      paths: [tempDir.path],
      listName: 'Batch Test',
      workDir: dirIn('work'),
      configDir: dirIn('config'),
    );
    while (session.stage == BatchStage.preparing) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    // The search match AND the no-match file waited for eyes (the
    // no-match card is where manual details/artwork can be entered);
    // the tags match auto-accepted. Accepting the unmatched outcome
    // lands it needs-attention.
    expect(confirmSeen, [confirmMe.path, noMatch.path]);
    // The auto-accepted file never paused the flow, but its match is
    // not silent either: a decided card, reopenable from the summary.
    expect(session.confirmables.length, 3);
    expect(session.canReopen(auto.path), isTrue);
    expect(session.readyCount, 2);
    expect(session.attentionCount, 1);
    expect(session.stage, BatchStage.review);

    // Estimate scaled from the fake's quote (3 chunks · both files).
    while (session.costEstimate == null && session.estimateError == null) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(session.estimatedTotalAtto, isNotNull);

    await session.startUpload();
    while (session.stage == BatchStage.uploading) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(session.stage, BatchStage.done);
    expect(session.uploadedCount, 2);
    expect(session.failedCount, 0);

    final byName = {
      for (final e in session.entries)
        if (e.status == 'uploaded') e.name!: e,
    };
    expect(byName['Auto Movie (1968) {imdb-tt0063350}.mp4']!.address, addrA);

    // Ledger lines landed in the injected config dir.
    final ledger = File('${tempDir.path}/config/ledger.jsonl');
    expect(ledger.existsSync(), isTrue);
    expect(ledger.readAsLinesSync().length, 2);

    // The bundle parses with the app's own importer and carries both
    // datamap members.
    expect(session.bundlePath, isNotNull);
    final parsed = parseBundle(
        Uint8List.fromList(File(session.bundlePath!).readAsBytesSync()));
    expect(parsed.datamapMembers.keys, containsAll([
      'Auto Movie (1968) {imdb-tt0063350}.mp4.datamap',
      'Confirm Movie (1970).mp4.datamap',
    ]));

    // The auto file's un-uploaded sibling stays needs-attention.
    expect(session.attentionCount, 1);
    expect(auto.existsSync(), isTrue);
  });

  test('ledger dedup: a re-prepared file never re-uploads', () async {
    fake.wallet = {'configured': true, 'address': '0xabc', 'storage': 'file'};
    final file = mediaFile('dedup.mp4', 7);
    final addr = 'cc' * 32;
    fake.uploadResult = {
      'address': addr,
      'size': 64,
      'chunks': 3,
      'cost_atto': '1000',
      'gas_wei': '1',
    };
    fake.datamaps[addr] = [9, 9, 9];

    final config = dirIn('config');
    var session = BatchUploadSession.instance;
    session.matchOverride = scriptedMatcher({
      'dedup.mp4': cli.MatchOutcome(
        type: 'video',
        name: 'Dedup Movie (1980).mp4',
        method: 'tags',
        confidence: 'high',
      ),
    });
    session.probeOverride = (path) async => null;
    await session.startPrepare(
      api: api(),
      paths: [file.path],
      listName: 'First',
      workDir: dirIn('work1'),
      configDir: config,
    );
    while (session.stage == BatchStage.preparing) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await session.startUpload();
    while (session.stage == BatchStage.uploading) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(session.uploadedCount, 1);

    // Second pass, fresh session, same config dir: the matcher must not
    // even run — the content hash is already in the ledger.
    BatchUploadSession.resetForTesting();
    session = BatchUploadSession.instance;
    session.matchOverride = (path, probe, {sidecar, forcedType}) async =>
        throw StateError('matcher must not run for a ledger hit');
    session.probeOverride =
        (path) async => throw StateError('probe must not run');
    await session.startPrepare(
      api: api(),
      paths: [file.path],
      listName: 'Second',
      workDir: dirIn('work2'),
      configDir: config,
    );
    while (session.stage == BatchStage.preparing) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(session.dedupCount, 1);
    expect(session.readyCount, 0);
    expect(session.entries.single.name, 'Dedup Movie (1980).mp4');
    expect(session.entries.single.address, addr);
  });

  test('confirm actions: skip and reject land the CLI statuses', () async {
    final session = BatchUploadSession.instance;
    mediaFile('skipme.mp4', 4);
    mediaFile('rejectme.mp4', 5);
    session.matchOverride = scriptedMatcher({
      'skipme.mp4': cli.MatchOutcome(
          type: 'video',
          name: 'Skip (2000).mp4',
          method: 'search',
          confidence: 'confirm'),
      'rejectme.mp4': cli.MatchOutcome(
          type: 'video',
          name: 'Reject (2001).mp4',
          method: 'search',
          confidence: 'confirm'),
    });
    session.probeOverride = (path) async => null;
    session.addListener(() {
      final c = session.pendingConfirm;
      if (c == null) return;
      if (c.path.endsWith('skipme.mp4')) session.confirmSkip();
      if (c.path.endsWith('rejectme.mp4')) session.confirmReject();
    });
    await session.startPrepare(
      api: api(),
      paths: [tempDir.path],
      listName: 'Choices',
      workDir: dirIn('work'),
      configDir: dirIn('config'),
    );
    while (session.stage == BatchStage.preparing) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(session.skippedCount, 1);
    expect(session.attentionCount, 1);
    expect(session.readyCount, 0);
  });

  test('manual entry: case-B outcome becomes a userEdited bundle row',
      () async {
    fake.wallet = {'configured': true, 'address': '0xabc', 'storage': 'file'};
    mediaFile('home-video.mp4', 6);
    final addr = 'dd' * 32;
    fake.uploadResult = {
      'address': addr,
      'size': 64,
      'chunks': 3,
      'cost_atto': '1000',
      'gas_wei': '1',
    };
    fake.datamaps[addr] = [7, 7, 7];

    final session = BatchUploadSession.instance;
    session.matchOverride = scriptedMatcher({});
    session.probeOverride = (path) async => null;
    var manualSent = false;
    session.addListener(() {
      final c = session.pendingConfirm;
      if (c != null && !manualSent) {
        manualSent = true;
        session.confirmManual(cli.Sidecar(
          type: 'video',
          title: 'Our Wedding',
          year: 2019,
          description: 'The big day.',
        ));
      }
    });
    // An unmatched file raises the confirm card too (that IS the
    // manual-entry entry point) — the listener answers it with the
    // manual form's sidecar.
    await session.startPrepare(
      api: api(),
      paths: [tempDir.path],
      listName: 'Home',
      workDir: dirIn('work'),
      configDir: dirIn('config'),
    );
    while (session.stage == BatchStage.preparing) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final entry = session.entries.single;
    expect(entry.status, 'ready');
    expect(entry.custom, isTrue);
    expect(entry.name, 'Our Wedding (2019).mp4');

    await session.startUpload();
    while (session.stage != BatchStage.done) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final parsed = parseBundle(
        Uint8List.fromList(File(session.bundlePath!).readAsBytesSync()));
    expect(parsed.metadataRows.length, 1);
    final row = parsed.metadataRows.values.single;
    expect(row['userEdited'], isTrue);
    expect(row['title'], 'Our Wedding');
    expect(row['overview'], 'The big day.');
  });

  group('album-at-a-time review', () {
    cli.MediaProbe albumProbe(int n, {String? mbid}) => cli.MediaProbe(
          hasAudio: true,
          hasRealVideo: false,
          tags: {
            'musicbrainz_albumid': ?mbid,
            'artist': 'Band',
            'album': 'Alb',
            'title': 'Song $n',
            'track': '$n',
          },
        );

    /// Matcher stub for a 3-track release [mbid]: plain matches answer
    /// with [method]/[confidence]; a release-mbid sidecar answers like
    /// the real matcher's high-confidence sidecar path.
    Future<cli.MatchOutcome> Function(String, cli.MediaProbe?,
        {cli.Sidecar? sidecar, String? forcedType}) releaseMatcher(
            String mbid,
            {required String method,
            required String confidence}) =>
        (path, probe, {sidecar, forcedType}) async {
          final n = probe?.trackNumber ??
              cli.guessMusicName(path.split('/').last).track ??
              0;
          if (sidecar != null && sidecar.releaseMbid != mbid) {
            throw StateError('unexpected release ${sidecar.releaseMbid}');
          }
          return cli.MatchOutcome(
            type: 'music',
            name: 'Band - Alb (1990) - 0$n Song $n {mbid-$mbid}.mp3',
            ids: {'release_mbid': mbid},
            method: sidecar != null ? 'sidecar' : method,
            confidence: sidecar != null ? 'high' : confidence,
            note: 'Band — Alb (1990), track $n "Song $n"',
          );
        };

    test('tagged album auto-accepts whole — no cards at all', () async {
      mediaFile('t1.mp3', 11);
      mediaFile('t2.mp3', 12);
      mediaFile('t3.mp3', 13);
      final session = BatchUploadSession.instance;
      session.probeOverride = (path) async {
        final n = int.parse(path.split('/').last[1]);
        return albumProbe(n, mbid: 'r1');
      };
      session.matchOverride =
          releaseMatcher('r1', method: 'tags', confidence: 'high');
      var cards = 0;
      session.addListener(() {
        if (session.pendingConfirm != null ||
            session.pendingAlbumConfirm != null) {
          cards++;
        }
      });
      await session.startPrepare(
        api: api(),
        paths: [tempDir.path],
        listName: 'Music',
        workDir: dirIn('work'),
        configDir: dirIn('config'),
      );
      while (session.stage == BatchStage.preparing) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(cards, 0);
      expect(session.readyCount, 3);
      for (final e in session.entries) {
        expect(e.ids['release_mbid'], 'r1');
        expect(e.type, 'music');
      }
      // The silent auto-accept still left a visible trace: one decided
      // album card, reopenable from the summary for any of its tracks.
      expect(session.confirmables.length, 1);
      final card = session.confirmables.single as AlbumConfirm;
      expect(card.decided, isTrue);
      expect(session.canReopen(card.tracks.first), isTrue);
    });

    test('search match raises ONE album card, not track by track',
        () async {
      mediaFile('b1.mp3', 21);
      mediaFile('b2.mp3', 22);
      mediaFile('b3.mp3', 23);
      final session = BatchUploadSession.instance;
      session.probeOverride = (path) async {
        final n = int.parse(path.split('/').last[1]);
        return albumProbe(n);
      };
      session.matchOverride =
          releaseMatcher('r2', method: 'search', confidence: 'confirm');
      final albumCards = <AlbumConfirm>{};
      session.addListener(() {
        final c = session.pendingAlbumConfirm;
        expect(session.pendingConfirm, isNull);
        if (c != null && albumCards.add(c)) {
          expect(c.tracks.length, 3);
          // Every track already resolved against the one release.
          expect(c.outcomes.every((o) => o?.matched ?? false), isTrue);
          expect(c.albumLine, 'Band — Alb (1990)');
          session.albumAccept();
        }
      });
      await session.startPrepare(
        api: api(),
        paths: [tempDir.path],
        listName: 'Music',
        workDir: dirIn('work'),
        configDir: dirIn('config'),
      );
      while (session.stage == BatchStage.preparing) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(albumCards.length, 1);
      expect(session.readyCount, 3);
      // Album order: track numbers 1..3 regardless of scan order.
      final names = [
        for (final e in session.entries)
          if (e.status == 'ready') e.name,
      ];
      expect(names, [
        'Band - Alb (1990) - 01 Song 1 {mbid-r2}.mp3',
        'Band - Alb (1990) - 02 Song 2 {mbid-r2}.mp3',
        'Band - Alb (1990) - 03 Song 3 {mbid-r2}.mp3',
      ]);
    });

    test('album reject and skip land whole-album statuses', () async {
      mediaFile('c1.mp3', 31);
      mediaFile('c2.mp3', 32);
      final session = BatchUploadSession.instance;
      session.probeOverride = (path) async =>
          albumProbe(int.parse(path.split('/').last[1]));
      session.matchOverride =
          releaseMatcher('r3', method: 'search', confidence: 'confirm');
      final seen = <AlbumConfirm>{};
      session.addListener(() {
        final c = session.pendingAlbumConfirm;
        if (c != null && seen.add(c)) session.albumReject();
      });
      await session.startPrepare(
        api: api(),
        paths: [tempDir.path],
        listName: 'Music',
        workDir: dirIn('work'),
        configDir: dirIn('config'),
      );
      while (session.stage == BatchStage.preparing) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(seen.length, 1);
      expect(session.attentionCount, 2);
      expect(session.readyCount, 0);
    });

    test('no-match album: pick a searched release re-resolves all tracks',
        () async {
      mediaFile('Band - Tape - 01 One.mp3', 41);
      mediaFile('Band - Tape - 02 Two.mp3', 42);
      final session = BatchUploadSession.instance;
      session.probeOverride = (path) async => null;
      session.matchOverride = (path, probe, {sidecar, forcedType}) async {
        if (sidecar?.releaseMbid == 'r9') {
          final n = sidecar!.track!;
          return cli.MatchOutcome(
            type: 'music',
            name: 'Band - Tape (1999) - 0$n T$n {mbid-r9}.mp3',
            ids: {'release_mbid': 'r9'},
            method: 'sidecar',
            confidence: 'high',
            note: 'Band — Tape (1999), track $n "T$n"',
          );
        }
        return cli.MatchOutcome(type: 'music', note: 'no MB match');
      };
      var picked = false;
      session.addListener(() {
        final c = session.pendingAlbumConfirm;
        if (c == null || picked) return;
        picked = true;
        expect(c.album, isNull); // NO ALBUM MATCH state
        expect(c.defaults['artist'], 'Band');
        expect(c.defaults['album'], 'Tape');
        session.albumPickMb('r9').then((_) => session.albumAccept());
      });
      await session.startPrepare(
        api: api(),
        paths: [tempDir.path],
        listName: 'Music',
        workDir: dirIn('work'),
        configDir: dirIn('config'),
      );
      while (session.stage == BatchStage.preparing) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(session.readyCount, 2);
      final names = [for (final e in session.entries) e.name]..sort();
      expect(names, [
        'Band - Tape (1999) - 01 T1 {mbid-r9}.mp3',
        'Band - Tape (1999) - 02 T2 {mbid-r9}.mp3',
      ]);
    });
  });

  testWidgets(
      'unmatched album shows ONE card; album manual entry covers every '
      'track', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    final tape = dirIn('tape');
    File('${tape.path}/side-a.mp3').writeAsBytesSync(List.filled(64, 51));
    File('${tape.path}/side-b.mp3').writeAsBytesSync(List.filled(64, 52));
    final session = BatchUploadSession.instance;
    session.probeOverride = (path) async => null;
    session.matchOverride = (path, probe, {sidecar, forcedType}) async {
      if (sidecar != null && sidecar.isManualEntry) {
        return cli.MatchOutcome(
          type: 'music',
          name: '${sidecar.artist} - ${sidecar.album}'
              '${sidecar.year != null ? ' (${sidecar.year})' : ''}'
              ' - 0${sidecar.track} ${sidecar.title}.mp3',
          method: 'sidecar',
          confidence: 'high',
          custom: true,
          customFields: {
            'artist': sidecar.artist,
            'album': sidecar.album,
            'title': sidecar.title,
            'track': sidecar.track,
          },
        );
      }
      return cli.MatchOutcome(type: 'music', note: 'no MB match');
    };

    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: BatchUploadScreen(apiBase: FakeEmbeddedHttp.base),
    ));
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      await session.startPrepare(
        api: api(),
        paths: [tape.path],
        listName: 'Music',
        workDir: dirIn('work-alb'),
        configDir: dirIn('config-alb'),
      );
      while (session.pendingAlbumConfirm == null) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();

    // One card for the whole folder, both tracks on it, no per-file card.
    expect(find.text('NO ALBUM MATCH'), findsOneWidget);
    expect(find.text('NO MATCH FOUND'), findsNothing);
    expect(find.textContaining('side-a.mp3'), findsOneWidget);
    expect(find.textContaining('side-b.mp3'), findsOneWidget);
    expect(find.text('Skip album'), findsOneWidget);

    await tester.tap(find.text('Enter details…'));
    await tester.pumpAndSettle();
    expect(find.text('Enter album details'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'Artist'), 'Band');
    await tester.enterText(find.widgetWithText(TextField, 'Album'), 'Tape');
    await tester.enterText(
        find.widgetWithText(TextField, 'Year (optional)'), '1999');
    await tester.tap(find.text('Save'));
    await tester.pump();

    await tester.runAsync(() async {
      while (session.stage == BatchStage.preparing) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    expect(session.readyCount, 2);
    for (final e in session.entries) {
      expect(e.status, 'ready');
      expect(e.type, 'music');
      expect(e.custom, isTrue);
      expect(e.name, contains('Band - Tape (1999)'));
    }
  });

  test('defaultBatchList: mostly-audio batches default to Music', () {
    final dir = dirIn('music-batch');
    File('${dir.path}/a.mp3').writeAsBytesSync([1]);
    File('${dir.path}/b.flac').writeAsBytesSync([1]);
    File('${dir.path}/c.mp4').writeAsBytesSync([1]);
    expect(defaultBatchList([dir.path]), 'Music');

    final vids = dirIn('video-batch');
    File('${vids.path}/a.mp4').writeAsBytesSync([1]);
    File('${vids.path}/b.mkv').writeAsBytesSync([1]);
    expect(defaultBatchList([vids.path]), 'My uploads');

    expect(defaultBatchList(const [], fallback: 'Kept'), 'Kept');
    expect(defaultBatchList(['/no/such/path'], fallback: 'Kept'), 'Kept');
  });

  testWidgets(
      'no-match file raises the confirm card; manual form has type '
      'toggle and artwork picker', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // The screen's list dropdown reads the library on open.
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    final mystery = mediaFile('mystery.mp4', 8);
    final session = BatchUploadSession.instance;
    session.matchOverride = scriptedMatcher({});
    session.probeOverride = (path) async => null;

    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: BatchUploadScreen(apiBase: FakeEmbeddedHttp.base),
    ));
    await tester.pumpAndSettle();

    // Prepare runs real file IO — drive it outside the fake-async zone.
    await tester.runAsync(() async {
      await session.startPrepare(
        api: api(),
        paths: [mystery.path],
        listName: 'Mystery',
        workDir: dirIn('work-nm'),
        configDir: dirIn('config-nm'),
      );
      while (session.pendingConfirm == null) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();

    // The unmatched file waits for eyes instead of silently landing in
    // needs-attention; there is no match to accept.
    expect(find.text('NO MATCH FOUND'), findsOneWidget);
    expect(find.text('Use this match'), findsNothing);
    expect(find.text('Enter details…'), findsOneWidget);

    await tester.tap(find.text('Enter details…'));
    await tester.pumpAndSettle();
    expect(find.text('Video'), findsOneWidget);
    expect(find.text('Music'), findsOneWidget);
    expect(find.text('Artwork from file…'), findsOneWidget);

    // Flip to music — the manual fields follow.
    await tester.tap(find.text('Music'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Artist'), 'Ella');
    await tester.enterText(
        find.widgetWithText(TextField, 'Album'), 'Home Tapes');
    await tester.enterText(
        find.widgetWithText(TextField, 'Track title'), 'Song One');
    await tester.enterText(
        find.widgetWithText(TextField, 'Track number'), '1');
    await tester.tap(find.text('Save'));
    await tester.pump();

    await tester.runAsync(() async {
      while (session.stage == BatchStage.preparing) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    final entry = session.entries.single;
    expect(entry.status, 'ready');
    expect(entry.type, 'music');
    expect(entry.custom, isTrue);
  });

  testWidgets('Upload screen links to the batch uploader', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: PublishScreen(
          apiBase: FakeEmbeddedHttp.base, ffmpeg: _NoFfmpeg()),
    ));
    await tester.pumpAndSettle();
    // One way in — the tier flow lives on the batch review page now.
    expect(find.text('Upload files or folders'), findsOneWidget);
    expect(find.text('Encode quality versions…'), findsNothing);
    await tester.tap(find.text('Upload files or folders'));
    await tester.pumpAndSettle();
    expect(find.byType(BatchUploadScreen), findsOneWidget);
    expect(find.text('Add files'), findsOneWidget);
    expect(find.text('Add a folder'), findsOneWidget);
  });

  test('carousel: an earlier answer can be revisited and replaced',
      () async {
    final a = mediaFile('a.mp4', 61);
    mediaFile('b.mp4', 62);
    final session = BatchUploadSession.instance;
    session.probeOverride = (path) async => null;
    session.matchOverride = scriptedMatcher({
      'a.mp4': cli.MatchOutcome(
          type: 'video',
          name: 'Alpha (2000).mp4',
          method: 'search',
          confidence: 'confirm'),
      'b.mp4': cli.MatchOutcome(
          type: 'video',
          name: 'Beta (2001).mp4',
          method: 'search',
          confidence: 'confirm'),
    });
    await session.startPrepare(
      api: api(),
      paths: [tempDir.path],
      listName: 'Carousel',
      workDir: dirIn('work-car'),
      configDir: dirIn('config-car'),
    );
    while (!session.reviewingMatches) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    // Both cards queued during the scan; answered one at a time.
    expect(session.confirmables.length, 2);
    expect(session.pendingConfirm!.path, a.path);
    session.confirmAccept();
    expect(session.pendingConfirm!.path, endsWith('b.mp4'));
    // Back/forward navigation reaches the answered card.
    session.confirmPrevious();
    expect(session.pendingConfirm!.path, a.path);
    expect(session.pendingConfirm!.decided, isTrue);
    session.confirmNext();
    session.confirmAccept();
    while (session.stage == BatchStage.preparing) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(session.stage, BatchStage.review);
    expect(session.readyCount, 2);

    // Reopen the first decision from the summary and change it: the
    // manifest record is replaced, not duplicated.
    expect(session.canReopen(a.path), isTrue);
    session.reopenConfirmForSource(a.path);
    expect(session.stage, BatchStage.preparing);
    expect(session.pendingConfirm!.path, a.path);
    session.confirmSkip();
    while (session.stage == BatchStage.preparing) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(session.stage, BatchStage.review);
    expect(session.readyCount, 1);
    expect(session.skippedCount, 1);
    expect(session.entries.length, 2);
  });

  test('auto-accepted match gets a decided, reopenable card', () async {
    final auto = mediaFile('quiet.mp4', 69);
    final session = BatchUploadSession.instance;
    session.probeOverride = (path) async => null;
    session.matchOverride = scriptedMatcher({
      'quiet.mp4': cli.MatchOutcome(
          type: 'video',
          name: 'Quiet Movie (1999).mp4',
          method: 'tags',
          confidence: 'high',
          note: 'Quiet Movie (1999)'),
    });
    await session.startPrepare(
      api: api(),
      paths: [auto.path],
      listName: 'Quiet',
      workDir: dirIn('work-quiet'),
      configDir: dirIn('config-quiet'),
    );
    while (session.stage == BatchStage.preparing) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    // Straight to the summary — the flow never paused…
    expect(session.stage, BatchStage.review);
    expect(session.readyCount, 1);
    // …but the match is inspectable and replaceable, not silent.
    final card = session.confirmables.single as BatchConfirm;
    expect(card.decided, isTrue);
    expect(session.canReopen(auto.path), isTrue);
    session.reopenConfirmForSource(auto.path);
    expect(session.pendingConfirm!.outcome.name, 'Quiet Movie (1999).mp4');
    session.confirmSkip();
    while (session.stage == BatchStage.preparing) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(session.stage, BatchStage.review);
    expect(session.readyCount, 0);
    expect(session.skippedCount, 1);
    expect(session.entries.length, 1);
  });

  test('done: batch auto-adds to the chosen list and seeds local '
      'metadata from its own bundle', () async {
    fake.wallet = {'configured': true, 'address': '0xabc', 'storage': 'file'};
    mediaFile('home-movie.mp4', 63);
    final addr = 'ee' * 32;
    fake.uploadResult = {
      'address': addr,
      'size': 64,
      'chunks': 3,
      'cost_atto': '1000',
      'gas_wei': '1',
    };
    fake.datamaps[addr] = [8, 8, 8];
    final session = BatchUploadSession.instance;
    session.matchOverride = scriptedMatcher({});
    session.probeOverride = (path) async => null;
    var manualSent = false;
    session.addListener(() {
      final c = session.pendingConfirm;
      if (c != null && !manualSent) {
        manualSent = true;
        session.confirmManual(cli.Sidecar(
          type: 'video',
          title: 'Garden Party',
          year: 2021,
          description: 'Backyard afternoon.',
        ));
      }
    });
    await session.startPrepare(
      api: api(),
      paths: [tempDir.path],
      listName: 'Family',
      workDir: dirIn('work-seed'),
      configDir: dirIn('config-seed'),
    );
    while (session.stage != BatchStage.review) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await session.startUpload();
    while (session.stage != BatchStage.done) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    // Auto-added to the setup page's list — the done page reports it.
    expect(session.autoAddedList, 'Family');
    expect(session.autoAddedCount, 1);
    final lists = await LibraryStore.load();
    final family = lists.singleWhere((l) => l.title == 'Family');
    expect(family.entries.single.name, 'Garden Party (2021).mp4');
    expect(family.entries.single.address, addr);

    // The manual-entry details reached the LOCAL metadata cache (the
    // old bug: they only travelled in the bundle).
    final row = await metadataRowFor('movie:garden party:2021');
    expect(row, isNotNull);
    expect(row!.userEdited, isTrue);
    expect(row.title, 'Garden Party');
    expect(row.overview, 'Backyard afternoon.');
  });

  test('quality tiers: a video entry expands into per-tier encodes, '
      'manifest rows, bundle members and library versions', () async {
    fake.wallet = {'configured': true, 'address': '0xabc', 'storage': 'file'};
    final vid = mediaFile('show-tape.mkv', 64);
    final addr1 = 'a1' * 32, addr2 = 'b2' * 32;
    fake.uploadResults = [
      {
        'address': addr1,
        'size': 32,
        'chunks': 3,
        'cost_atto': '1000',
        'gas_wei': '1',
      },
      {
        'address': addr2,
        'size': 32,
        'chunks': 3,
        'cost_atto': '1000',
        'gas_wei': '1',
      },
    ];
    fake.datamaps[addr1] = [1, 1];
    fake.datamaps[addr2] = [2, 2];

    final session = BatchUploadSession.instance;
    session.probeOverride = (path) async => null;
    session.matchOverride = scriptedMatcher({
      'show-tape.mkv': cli.MatchOutcome(
        type: 'video',
        name: 'Show Tape (1999).mkv',
        ids: {'imdb': 'tt0000001'},
        method: 'tags',
        confidence: 'high',
      ),
    });
    final ffmpeg = _FakeFfmpeg({
      'show-tape.mkv': const MediaProbe(
        hasVideo: true,
        width: 1280,
        height: 720,
        videoCodec: 'hevc',
        pixelFormat: 'yuv420p10le',
        hasAudio: true,
        audioCodec: 'eac3',
        container: 'matroska,webm',
        durationSeconds: 60,
      ),
    });
    await session.startPrepare(
      api: api(),
      paths: [vid.path],
      listName: 'Tapes',
      workDir: dirIn('work-tiers'),
      configDir: dirIn('config-tiers'),
      ffmpeg: ffmpeg,
    );
    while (session.stage == BatchStage.preparing ||
        session.tiers.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    // 720p HEVC source: Medium + Low offered and default-ticked,
    // Original offered but unticked (not universal).
    expect(session.readyVideoEntries.length, 1);
    expect(session.tiers, {PublishTier.medium, PublishTier.low});
    expect(session.plannedUploadCount, 2);

    await session.startUpload();
    while (session.stage != BatchStage.done) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    // Two encodes, two uploads, two manifest rows under tier names.
    expect(ffmpeg.encodes, [
      'Show Tape (1999) [720p].mp4',
      'Show Tape (1999) [480p].mp4',
    ]);
    final names = [
      for (final e in session.entries)
        if (e.status == 'uploaded') e.name,
    ];
    expect(names, [
      'Show Tape (1999) [720p].mp4',
      'Show Tape (1999) [480p].mp4',
    ]);
    expect(session.videoInfoByName['Show Tape (1999) [720p].mp4'],
        '720p H.264');
    // Both versions land in the auto-added list and the bundle.
    final lists = await LibraryStore.load();
    final tapes = lists.singleWhere((l) => l.title == 'Tapes');
    expect(tapes.entries.length, 2);
    expect(tapes.entries.first.videoInfo, '720p H.264');
    final parsed = parseBundle(
        Uint8List.fromList(File(session.bundlePath!).readAsBytesSync()));
    expect(parsed.datamapMembers.keys, containsAll([
      'Show Tape (1999) [720p].mp4.datamap',
      'Show Tape (1999) [480p].mp4.datamap',
    ]));
    // The ledger carries one row per output (content-hash of each).
    final ledger = File('${tempDir.path}/config-tiers/ledger.jsonl');
    expect(ledger.readAsLinesSync().length, 2);
  });

  test('needs-attention resume: a second pass over the same work dir '
      're-matches and replaces the entry', () async {
    final file = mediaFile('lost.mp4', 65);
    final config = dirIn('config-att');
    final work = dirIn('work-att');
    var session = BatchUploadSession.instance;
    session.probeOverride = (path) async => null;
    session.matchOverride = scriptedMatcher({});
    session.addListener(() {
      if (session.pendingConfirm != null) session.confirmReject();
    });
    await session.startPrepare(
      api: api(),
      paths: [file.path],
      listName: 'Lost Batch',
      workDir: work,
      configDir: config,
    );
    while (session.stage == BatchStage.preparing) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(session.attentionCount, 1);

    // The manifest on disk is what the attention scan reads.
    final batches = await scanAttentionBatches(Directory(tempDir.path));
    expect(batches.length, 1);
    expect(batches.single.listName, 'Lost Batch');
    expect(batches.single.sources, [file.path]);

    // Second pass (the Review button): the file re-matches and its
    // needs-attention row is replaced by the ready one.
    BatchUploadSession.resetForTesting();
    session = BatchUploadSession.instance;
    session.probeOverride = (path) async => null;
    session.matchOverride = scriptedMatcher({
      'lost.mp4': cli.MatchOutcome(
          type: 'video',
          name: 'Found (2002).mp4',
          method: 'search',
          confidence: 'confirm'),
    });
    session.addListener(() {
      if (session.pendingConfirm != null) session.confirmAccept();
    });
    await session.startPrepare(
      api: api(),
      paths: batches.single.sources,
      listName: batches.single.listName,
      workDir: batches.single.workDir,
      configDir: config,
    );
    while (session.stage == BatchStage.preparing) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(session.entries.length, 1);
    expect(session.entries.single.status, 'ready');
    expect(session.entries.single.name, 'Found (2002).mp4');
  });

  testWidgets('earlier-batches card refreshes when the session returns '
      'to setup', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final file = mediaFile('mystery.mp4', 68);
    final root = dirIn('batch_uploads');
    final old = Directory('${root.path}/old-batch')..createSync();
    File('${old.path}/watchit-manifest.yaml').writeAsStringSync('''
version: 1
list_name: "Old Batch"
entries:
  - source: "${file.path}"
    status: "needs-attention"
''');
    final session = BatchUploadSession.instance;
    session.probeOverride = (path) async => null;
    session.matchOverride = scriptedMatcher({
      'mystery.mp4': cli.MatchOutcome(
          type: 'video',
          name: 'Solved (2001).mp4',
          method: 'id',
          confidence: 'high'),
    });
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: BatchUploadScreen(
          apiBase: FakeEmbeddedHttp.base,
          batchRootProvider: () async => root),
    ));
    await tester.pumpAndSettle();
    expect(
        find.text('1 file from earlier uploads still needs attention'),
        findsOneWidget);

    // The Review flow re-runs prepare over the batch's own work dir;
    // the file resolves and the batch is closed. Back on the setup
    // page the card must be gone WITHOUT leaving the screen (it used
    // to stay until the screen was reopened).
    await tester.runAsync(() async {
      await session.startPrepare(
        api: api(),
        paths: [file.path],
        listName: 'Old Batch',
        workDir: old,
        configDir: dirIn('config-refresh'),
      );
      while (session.stage == BatchStage.preparing) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      session.clear();
    });
    await tester.pumpAndSettle();
    expect(
        find.textContaining('from earlier uploads still'), findsNothing);
  });

  testWidgets('carousel header: N of M with back/forward arrows',
      (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    mediaFile('one.mp4', 66);
    mediaFile('two.mp4', 67);
    final session = BatchUploadSession.instance;
    session.probeOverride = (path) async => null;
    session.matchOverride = scriptedMatcher({});

    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: BatchUploadScreen(apiBase: FakeEmbeddedHttp.base),
    ));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await session.startPrepare(
        api: api(),
        paths: [tempDir.path],
        listName: 'Two',
        workDir: dirIn('work-carw'),
        configDir: dirIn('config-carw'),
      );
      while (!session.reviewingMatches) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    expect(find.text('Review matches · 1 of 2'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pump();
    expect(find.text('Review matches · 2 of 2'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pump();
    expect(find.text('Review matches · 1 of 2'), findsOneWidget);
  });
}
