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

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late FakeEmbeddedHttp fake;
  late Directory tempDir;

  setUp(() {
    SharedPreferences.setMockInitialValues(
        {'terms_accepted_version_v1': kTermsVersion});
    BatchUploadSession.resetForTesting();
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
    // One primary way in; the tier flow is demoted to ADVANCED.
    expect(find.text('Upload files or folders'), findsOneWidget);
    expect(find.text('ADVANCED'), findsOneWidget);
    expect(find.text('Encode quality versions…'), findsOneWidget);
    await tester.tap(find.text('Upload files or folders'));
    await tester.pumpAndSettle();
    expect(find.byType(BatchUploadScreen), findsOneWidget);
    expect(find.text('Add files'), findsOneWidget);
    expect(find.text('Add a folder'), findsOneWidget);
  });
}
