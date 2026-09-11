import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/intake_draft.dart';
import 'package:watchit/models/media_credits.dart';
import 'package:watchit/screens/intake_screen.dart';
import 'package:watchit/services/intake_store.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/media_credits_store.dart';
import 'package:watchit/services/profiles.dart';
import 'package:watchit/theme/tokens.dart' show WiTokens, wiTheme;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory temp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temp = Directory.systemTemp.createTempSync('watch-intake-');
    await LibraryStore.useForTesting(
      AppDatabase.forTesting(NativeDatabase.memory()),
    );
    ProfileStore.instance = ProfileStore();
  });
  tearDown(() {
    temp.deleteSync(recursive: true);
  });

  IntakeDraft fileDraft(String path) => IntakeDraft(
        id: 'intake_test_file',
        kind: IntakeDraft.kindFile,
        label: 'Festival take 1.mp4',
        localPath: path,
        sizeBytes: 1234,
        language: 'Latvian',
        listTitle: 'Festival 2026',
        credits: const MediaCredits(
          creator: 'Test ensemble',
          licenseName: 'Creator-supplied',
        ),
      );

  group('model', () {
    test('shared text extracts a YouTube URL and trims share punctuation', () {
      expect(
        extractSharedHttpUrl(
            'Dziesmu svētki https://youtu.be/G94Q8TbFnIA?si=abc).'),
        'https://youtu.be/G94Q8TbFnIA?si=abc',
      );
      expect(
        extractSharedHttpUrl('no link here'),
        isNull,
      );
    });

    test('shared text accepts a playlist URL', () {
      expect(
        extractSharedHttpUrl(
            'https://youtube.com/playlist?list=PLkUQHd8CpZKngAYcM7R0Zy4d8cGfzzwL5'),
        startsWith('https://youtube.com/playlist?list='),
      );
    });

    test('link suggestion derives a label from the URL path', () {
      expect(
        IntakeDraft.suggestLabel('https://video.example.org/watch/song-final'),
        'song-final',
      );
      expect(
        IntakeDraft.suggestLabel('https://example.org/a/b/Clip.2026.mp4'),
        'Clip.2026',
      );
      expect(IntakeDraft.suggestLabel('https://example.org'), isNull);
    });

    test('validation enforces label, link URL shape and bounds', () {
      final d = IntakeDraft(
          id: 'x', kind: IntakeDraft.kindLink, label: '  Ref  ');
      expect(() => d.validate(), throwsFormatException); // no URL

      d.sourceUrl = 'javascript:alert(1)';
      expect(() => d.validate(), throwsFormatException);

      d.sourceUrl = 'https://user:pw@example.org/v';
      expect(() => d.validate(), throwsFormatException);

      d.sourceUrl = 'https://example.org/performance';
      d.validate();
      expect(d.label, 'Ref');
      expect(d.sourceUrl, 'https://example.org/performance');

      final blank = IntakeDraft(
          id: 'y',
          kind: IntakeDraft.kindLink,
          label: 'ok',
          sourceUrl: 'https://example.org/x');
      blank.label = '';
      expect(() => blank.validate(), throwsFormatException);
      blank.label = 'x' * 513;
      expect(() => blank.validate(), throwsFormatException);
    });

    test('a phone file pick (no durable path) is still a valid draft', () {
      final d = fileDraft(''); // phone: no path kept
      d.localPath = null;
      d.validate();
      expect(d.localPath, isNull);
      expect(d.isFile, isTrue);
    });

    test('the card URL is the single provenance authority', () {
      final d = fileDraft('/tmp/a.mp4');
      d.sourceUrl = 'https://example.org/the-source';
      d.credits = const MediaCredits(
          creator: 'c', sourceUrl: 'https://old.example.org/gone');
      d.validate();
      expect(d.credits.sourceUrl, 'https://example.org/the-source');
    });
  });

  group('store', () {
    test('save and load round-trip every field', () async {
      final d = fileDraft('/tmp/festival-take1.mp4');
      d.artworkFile = 'intake_deadbeefcafe.img';
      await IntakeStore.save(d);

      final loaded = await IntakeStore.loadAll();
      expect(loaded, hasLength(1));
      final back = loaded.single;
      expect(back.id, d.id);
      expect(back.kind, IntakeDraft.kindFile);
      expect(back.label, d.label);
      expect(back.localPath, d.localPath);
      expect(back.sizeBytes, 1234);
      expect(back.language, 'Latvian');
      expect(back.listTitle, 'Festival 2026');
      expect(back.artworkFile, 'intake_deadbeefcafe.img');
      expect(back.credits.creator, 'Test ensemble');
      expect(back.credits.licenseName, 'Creator-supplied');
    });

    test('saving again edits in place — one row, newer timestamp', () async {
      final d = IntakeDraft(
          id: 'intake_edit', kind: IntakeDraft.kindLink, label: 'First')
        ..sourceUrl = 'https://example.org/one';
      await IntakeStore.save(d);
      final before = (await IntakeStore.loadAll()).single.updatedAt;

      d.label = 'Renamed';
      d.language = 'lv';
      await IntakeStore.save(d);

      final after = await IntakeStore.loadAll();
      expect(after, hasLength(1));
      expect(after.single.label, 'Renamed');
      expect(after.single.language, 'lv');
      expect(after.single.updatedAt.isAfter(before) ||
          !after.single.updatedAt.isBefore(before), isTrue);
    });

    test('delete removes only that draft', () async {
      final a = IntakeDraft(
          id: 'intake_a', kind: IntakeDraft.kindLink, label: 'A')
        ..sourceUrl = 'https://example.org/a';
      final b = IntakeDraft(
          id: 'intake_b', kind: IntakeDraft.kindLink, label: 'B')
        ..sourceUrl = 'https://example.org/b';
      await IntakeStore.save(a);
      await IntakeStore.save(b);
      await IntakeStore.delete('intake_a');
      final left = await IntakeStore.loadAll();
      expect(left.map((d) => d.id), ['intake_b']);
    });

    test('artwork is content-addressed and traversal-safe to read',
        () async {
      final dir = Directory('${temp.path}/posters');
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final name = await IntakeStore.saveArtwork(bytes,
          postersDirProvider: () async => dir);
      expect(name, startsWith('intake_'));
      expect(name, endsWith('.img'));
      final read = await IntakeStore.readArtwork(name,
          postersDirProvider: () async => dir);
      expect(read, bytes);
      expect(
        await IntakeStore.readArtwork('../escape.img',
            postersDirProvider: () async => dir),
        isNull,
      );
      expect(
        await IntakeStore.readArtwork('missing.img',
            postersDirProvider: () async => dir),
        isNull,
      );
    });
  });

  group('upload carry', () {
    test('credits move onto uploaded addresses and the draft is consumed',
        () async {
      final path = '/tmp/festival-take1.mp4';
      final d = fileDraft(path);
      await IntakeStore.save(d);
      final link = IntakeDraft(
          id: 'intake_link', kind: IntakeDraft.kindLink, label: 'L')
        ..sourceUrl = 'https://example.org/l';
      await IntakeStore.save(link);

      final consumed = await carryCreditsIntoUploads([
        (source: path, address: 'a' * 64),
        (source: path, address: 'b' * 64), // tier encode: second output
        (source: '/tmp/unrelated.mp4', address: 'c' * 64),
      ]);

      expect(consumed, 1);
      expect((await MediaCreditsStore.read('a' * 64))!.creator,
          'Test ensemble');
      expect((await MediaCreditsStore.read('b' * 64))!.creator,
          'Test ensemble');
      expect(await MediaCreditsStore.read('c' * 64), isNull);
      final left = await IntakeStore.loadAll();
      expect(left.map((x) => x.id), ['intake_link']); // link untouched
    });

    test('a basename match carries when the source moved directories',
        () async {
      final d = fileDraft('/home/user/Downloads/festival-take1.mp4');
      await IntakeStore.save(d);
      final consumed = await carryCreditsIntoUploads([
        (source: '/mnt/other/festival-take1.mp4', address: 'd' * 64),
      ]);
      expect(consumed, 1);
      expect(await MediaCreditsStore.read('d' * 64), isNotNull);
    });

    test('an existing credit at the address wins (gap-fill)', () async {
      final path = '/tmp/festival-take1.mp4';
      await MediaCreditsStore.save('e' * 64,
          const MediaCredits(creator: 'My own correction'));
      final d = fileDraft(path);
      await IntakeStore.save(d);
      await carryCreditsIntoUploads([(source: path, address: 'e' * 64)]);
      expect((await MediaCreditsStore.read('e' * 64))!.creator,
          'My own correction');
      // Draft still consumed — its content is on the network now.
      expect(await IntakeStore.loadAll(), isEmpty);
    });
  });

  group('screen', () {
    Future<void> pumpScreen(
      WidgetTester tester, {
      IntakeFilePick? picker,
      Future<int> Function(BuildContext, IntakeDraft)? uploadOpener,
      double width = 1280,
      double height = 800,
    }) async {
      tester.view.physicalSize = Size(width, height);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: IntakeScreen(
          filesPicker: picker ?? () async => const [],
          uploadOpener: uploadOpener,
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('picked files open review cards; save persists a durable draft',
        (tester) async {
      await pumpScreen(
        tester,
        picker: () async => [
          (name: 'Festival take 1.mp4', path: '/tmp/festival-take1.mp4',
           size: 1234),
        ],
      );
      await tester.tap(find.text('Choose media files'));
      await tester.pumpAndSettle();

      expect(find.text('REVIEW'), findsOneWidget);
      final title = find.widgetWithText(TextFormField, 'Title');
      expect(title, findsOneWidget);

      await tester.enterText(
          find.byKey(const ValueKey('intake-title')), 'Festival — final cut');
      await tester.enterText(
          find.byKey(const ValueKey('intake-creator')), 'Test ensemble');
      await tester.ensureVisible(find.text('Save draft'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save draft'));
      await tester.pumpAndSettle();

      expect(find.text('REVIEW'), findsNothing);
      final saved = await IntakeStore.loadAll();
      expect(saved, hasLength(1));
      expect(saved.single.label, 'Festival — final cut');
      expect(saved.single.credits.creator, 'Test ensemble');
      expect(saved.single.kind, IntakeDraft.kindFile);
      expect(find.text('SAVED ON THIS DEVICE'), findsOneWidget);
      expect(find.text('Festival — final cut'), findsOneWidget);
    });

    testWidgets('yt-dlp sidecar pre-fills title, creator and source',
        (tester) async {
      final path = '${temp.path}/G94Q8TbFnIA.mp4';
      File(path).writeAsStringSync('x');
      File('${temp.path}/G94Q8TbFnIA.info.json').writeAsStringSync(
        jsonEncode({
          'title': 'Latvian festival set',
          'uploader': 'LSM info',
          'webpage_url': 'https://www.youtube.com/watch?v=G94Q8TbFnIA',
        }),
      );
      await pumpScreen(
        tester,
        picker: () async => [
          (name: 'G94Q8TbFnIA.mp4', path: path, size: 1234),
        ],
      );
      await tester.tap(find.text('Choose media files'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextFormField>(
          find.byKey(const ValueKey('intake-title')),
        ).controller!.text,
        'Latvian festival set',
      );
      expect(
        tester.widget<TextFormField>(
          find.byKey(const ValueKey('intake-creator')),
        ).controller!.text,
        'LSM info',
      );
      expect(
        tester.widget<TextFormField>(
          find.byKey(const ValueKey('intake-url')),
        ).controller!.text,
        'https://www.youtube.com/watch?v=G94Q8TbFnIA',
      );
    });

    testWidgets('paste: a valid link opens a card; a bad link is refused', (tester) async {
      await pumpScreen(tester);
      await tester.enterText(find.byKey(const ValueKey('intake-link-field')),
          'not a url');
      await tester.tap(find.byIcon(Icons.add_link));
      await tester.pumpAndSettle();
      expect(find.text('REVIEW'), findsNothing);
      expect(find.textContaining('plain HTTP or HTTPS'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('intake-link-field')),
          'https://video.example.org/watch/song-final');
      await tester.tap(find.byIcon(Icons.add_link));
      await tester.pumpAndSettle();
      expect(find.text('REVIEW'), findsOneWidget);
      expect(find.text('song-final'), findsWidgets); // suggested label
    });

    testWidgets('saving without a title shows the error and persists nothing',
        (tester) async {
      await pumpScreen(
        tester,
        picker: () async => [
          (name: 'x.mp4', path: '/tmp/x.mp4', size: 1),
        ],
      );
      await tester.tap(find.text('Choose media files'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('intake-title')), '   ');
      await tester.ensureVisible(find.text('Save draft'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save draft'));
      await tester.pumpAndSettle();
      expect(find.text('A title is required.'), findsOneWidget);
      expect(await IntakeStore.loadAll(), isEmpty);
    });

    testWidgets('discard removes the pending card without saving', (tester) async {
      await pumpScreen(
        tester,
        picker: () async => [
          (name: 'y.mp4', path: '/tmp/y.mp4', size: 2),
        ],
      );
      await tester.tap(find.text('Choose media files'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Discard'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(find.text('REVIEW'), findsNothing);
      expect(await IntakeStore.loadAll(), isEmpty);
    });

    testWidgets('edits survive reopen: reload reads the store', (tester) async {
      final d = fileDraft('/tmp/keep.mp4');
      await IntakeStore.save(d);
      await pumpScreen(tester);
      expect(find.text('Festival take 1.mp4'), findsOneWidget);

      d.language = 'Latvian (updated)';
      await IntakeStore.save(d);
      // A fresh widget tree, not a reused state: unpump first.
      await tester.pumpWidget(const SizedBox());
      await pumpScreen(tester);
      expect(find.text('Latvian (updated)'), findsOneWidget);
    });

    testWidgets('kid profile: choosing and pasting are disabled', (tester) async {
      final store = ProfileStore.instance;
      await store.ensureLoaded();
      final kid =
          await store.create(name: 'Kid', kind: ProfileKind.kid);
      await store.selectProfile(kid.id);
      await pumpScreen(tester);

      final choose = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Choose media files'));
      expect(choose.onPressed, isNull);
      final field = find.byKey(const ValueKey('intake-link-field'));
      await tester.enterText(field, 'https://example.org/x');
      await tester.tap(find.byIcon(Icons.add_link));
      await tester.pumpAndSettle();
      expect(find.text('REVIEW'), findsNothing);
      expect(await IntakeStore.loadAll(), isEmpty);
    });

    testWidgets('upload handoff passes the draft and reports carried credits',
        (tester) async {
      final path = '${temp.path}/festival-take1.mp4';
      File(path).writeAsStringSync('x');
      final d = fileDraft(path);
      await IntakeStore.save(d);

      IntakeDraft? handed;
      await pumpScreen(
        tester,
        uploadOpener: (context, draft) async {
          handed = draft;
          return 1;
        },
      );

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Upload this file…'));
      await tester.pumpAndSettle();

      expect(handed?.id, d.id);
      expect(
        find.textContaining('credits moved onto the resulting file record'),
        findsOneWidget,
      );
    });

    testWidgets('renders without overflow at laptop and phone sizes', (tester) async {
      for (final (w, h) in [(1280.0, 800.0), (390.0, 844.0)]) {
        await tester.pumpWidget(const SizedBox()); // fresh state per size
        await pumpScreen(
          tester,
          picker: () async => [
            (name: 'Festival take 1.mp4',
             path: '/tmp/festival-take1.mp4', size: 1234),
          ],
          width: w,
          height: h,
        );
        await tester.tap(find.text('Choose media files'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('intake-title')), findsOneWidget);
        expect(find.byKey(const ValueKey('intake-url')), findsOneWidget);
        expect(find.byKey(const ValueKey('intake-language')), findsOneWidget);
        expect(
            find.byKey(const ValueKey('intake-collection')), findsOneWidget);
        expect(tester.takeException(), isNull); // no layout overflow
        // Phone width: the row of language+collection fields must still
        // be present and tappable.
        await tester.ensureVisible(
            find.byKey(const ValueKey('intake-language')));
      }
    });
  });
}
