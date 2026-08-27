import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchit/db/app_database.dart';
import 'package:watchit/screens/channel_publish_screen.dart';
import 'package:watchit/services/channel_service.dart';
import 'package:watchit/services/ffmpeg.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/publish_plan.dart';
import 'package:watchit/theme/tokens.dart';

import 'fake_embedded_http.dart';

/// Serves `openFile` picks from a queue — first the media file, then
/// (inside the describe page) the artwork image.
class _FakeFileSelector extends FileSelectorPlatform
    with MockPlatformInterfaceMixin {
  _FakeFileSelector(this.singles);
  final List<XFile?> singles;

  @override
  Future<XFile?> openFile(
          {List<XTypeGroup>? acceptedTypeGroups,
          String? initialDirectory,
          String? confirmButtonText}) async =>
      singles.isEmpty ? null : singles.removeAt(0);
}

/// Probe/encode without real processes.
class _FakeFfmpeg extends FfmpegService {
  _FakeFfmpeg(this.probes);
  final Map<String, MediaProbe?> probes;
  final List<String> encodes = [];

  @override
  Future<bool> get available async => true;

  @override
  Future<MediaProbe?> probe(String path) async =>
      probes[path.split(Platform.pathSeparator).last];

  @override
  Future<void> encode({
    required String input,
    required String output,
    required PublishTier tier,
    MediaProbe? probe,
    void Function(double? fraction)? onProgress,
  }) async {
    encodes.add(
        '${input.split(Platform.pathSeparator).last} → ${output.split(Platform.pathSeparator).last}');
    onProgress?.call(1);
  }

  @override
  void cancel() {}
}

/// A real (1x1 transparent) PNG — the artwork slot renders picked bytes
/// with an Image widget, which decodes them.
const _pngBytes = [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
  0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89,
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x62,
  0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4,
  0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60,
  0x82,
];

/// A universal (as-is only) 480p H.264/AAC MP4 probe.
const universalProbe = MediaProbe(
  hasVideo: true,
  width: 640,
  height: 480,
  videoCodec: 'h264',
  pixelFormat: 'yuv420p',
  hasAudio: true,
  audioCodec: 'aac',
  container: 'mov,mp4,m4a,3gp,3g2,mj2',
  durationSeconds: 60,
);

/// A 1080p HEVC probe — several encode tiers apply.
const hevcProbe = MediaProbe(
  hasVideo: true,
  width: 1920,
  height: 1080,
  videoCodec: 'hevc',
  pixelFormat: 'yuv420p10le',
  hasAudio: true,
  audioCodec: 'eac3',
  container: 'matroska,webm',
  durationSeconds: 3600,
);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late FakeEmbeddedHttp fake;
  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    fake = FakeEmbeddedHttp();
    HttpOverrides.global = fake;
    ChannelService.resetForTesting();
    tempDir = Directory.systemTemp.createTempSync('wi-chpub-test');
  });

  tearDown(() {
    HttpOverrides.global = null;
    tempDir.deleteSync(recursive: true);
  });

  XFile mediaFile(String name, [int bytes = 5]) => XFile.fromData(
        Uint8List.fromList(List.filled(bytes, 1)),
        path: '${tempDir.path}/$name',
      );

  Future<void> openScreen(WidgetTester tester, _FakeFfmpeg ffmpeg) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: ChannelPublishScreen(
        apiBase: FakeEmbeddedHttp.base,
        ffmpeg: ffmpeg,
        postersDirProvider: () async =>
            Directory('${tempDir.path}/posters')..createSync(recursive: true),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// Walk the run stage: each upload needs a poll tick (1s) plus a frame.
  Future<void> pumpUploads(WidgetTester tester, int uploads) async {
    for (var i = 0; i < uploads + 1; i++) {
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  /// Drive the describe page to completion: title + description typed,
  /// artwork from an image file (already queued on the file selector).
  Future<void> describeAll(WidgetTester tester) async {
    await tester.enterText(
        find.widgetWithText(TextField, 'Title (required)'), 'My Film');
    await tester.enterText(
        find.widgetWithText(TextField, 'Description (required)'),
        'My own film, described.');
    await tester.tap(find.text('From image file'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save description'));
    await tester.tap(find.text('Save description'));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'publish gates on the description; picked file shows verdict + tiers',
      (tester) async {
    fake.wallet = {'address': '0x1', 'storage': 'keychain'};
    FileSelectorPlatform.instance =
        _FakeFileSelector([mediaFile('My Film (2026).mkv')]);
    await openScreen(
        tester, _FakeFfmpeg({'My Film (2026).mkv': hevcProbe}));
    expect(find.textContaining('Wallet ready'), findsOneWidget);

    await tester.tap(find.text('Choose a file'));
    await tester.pumpAndSettle();
    expect(fake.requests, contains('POST /upload/estimate'));
    expect(find.textContaining('My Film (2026).mkv'), findsOneWidget);
    expect(find.textContaining('many devices can\'t play this'),
        findsOneWidget);
    // Encode tiers offered for the 1080p HEVC source.
    expect(find.text('High · 1080p H.264'), findsOneWidget);
    expect(find.text('Medium · 720p H.264'), findsOneWidget);
    expect(find.text('Low · 480p H.264'), findsOneWidget);

    // The upload button stays disabled until the item is described.
    final publish = find.ancestor(
        of: find.textContaining('Encode & upload'),
        matching: find.byType(FilledButton));
    expect(tester.widget<FilledButton>(publish).onPressed, isNull);
    expect(find.textContaining('Still needed: the description'),
        findsOneWidget);
    expect(find.text('Describe this item'), findsOneWidget);
  });

  testWidgets(
      'file → describe → attest → encode+upload → staged on the channel '
      '+ optional add to library',
      (tester) async {
    fake.wallet = {'address': '0x1', 'storage': 'keychain'};
    fake.uploadResults = [
      {...fake.uploadResult, 'address': 'aa' * 32},
      {...fake.uploadResult, 'address': 'bb' * 32, 'size': 7},
    ];
    final poster = XFile.fromData(Uint8List.fromList(_pngBytes),
        path: '${tempDir.path}/poster.png');
    FileSelectorPlatform.instance = _FakeFileSelector(
        [mediaFile('My Film (2026).mkv'), poster]);
    final ffmpeg = _FakeFfmpeg({'My Film (2026).mkv': hevcProbe});
    await openScreen(tester, ffmpeg);

    await tester.tap(find.text('Choose a file'));
    await tester.pumpAndSettle();

    // Keep it to two versions so the run is short: High + Low.
    await tester.tap(find.text('Medium · 720p H.264'));
    await tester.pump();

    // Describe (required): opens the shared describe page against the
    // LOCAL file — no library entry exists yet.
    await tester.tap(find.text('Describe this item'));
    await tester.pumpAndSettle();
    expect(find.text('Describe this item'), findsOneWidget); // app bar
    await describeAll(tester);
    expect(find.text('Described for subscribers ✓'), findsOneWidget);

    // Now the publish button is live; it opens the rights attestation.
    final publish = find.ancestor(
        of: find.textContaining('Encode & upload'),
        matching: find.byType(FilledButton));
    expect(tester.widget<FilledButton>(publish).onPressed, isNotNull);
    await tester.ensureVisible(publish);
    await tester.tap(publish);
    await tester.pumpAndSettle();
    expect(
        find.textContaining('I created this content myself'), findsOneWidget);
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(Checkbox)));
    await tester.pump();
    await tester.tap(find.text('Add to channel'));
    await tester.pump();

    // Two encodes (High, Low) + two uploads run in turn.
    await pumpUploads(tester, 2);
    expect(ffmpeg.encodes, [
      'My Film (2026).mkv → My Film (2026) [1080p].mp4',
      'My Film (2026).mkv → My Film (2026) [480p].mp4',
    ]);
    expect(find.text('Staged for the channel'), findsOneWidget);
    expect(find.textContaining('2 of 2 uploads finished'), findsOneWidget);
    expect(find.textContaining('still private'), findsOneWidget);

    // Both versions are on the channel's staged item list.
    final items = await ChannelService.instance.myItems();
    expect(items, hasLength(2));
    expect(items[0].name, 'My Film (2026) [1080p].mp4');
    expect(items[0].address, 'aa' * 32);
    expect(items[1].name, 'My Film (2026) [480p].mp4');
    expect(items[1].address, 'bb' * 32);

    // The described metadata row exists under the shared lookup key, so
    // the manifest build will carry it.
    final db = await LibraryStore.database();
    final rows = await db.select(db.metadataCache).get();
    final row = rows.singleWhere((r) => r.userEdited);
    expect(row.title, 'My Film');
    expect(row.overview, 'My own film, described.');
    expect(row.posterFile, isNotNull);

    // Optional add-to-library leg: empty library → new-list prompt.
    await tester.tap(find.text('Also add to my library'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'My channel masters');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final lists = await LibraryStore.load();
    expect(lists, hasLength(1));
    expect(lists.single.title, 'My channel masters');
    expect(lists.single.entries, hasLength(2));
    expect(lists.single.entries[0].name, 'My Film (2026) [1080p].mp4');
    expect(lists.single.entries[0].videoInfo, '1080p H.264');
    expect(lists.single.entries[1].videoInfo, '480p H.264');

    // Back to the channel pops with `true` (caller reloads + snacks).
    await tester.tap(find.text('Back to the channel'));
    await tester.pumpAndSettle();
  });

  testWidgets('attestation declined → nothing runs, nothing staged',
      (tester) async {
    fake.wallet = {'address': '0x1', 'storage': 'keychain'};
    final poster = XFile.fromData(Uint8List.fromList(_pngBytes),
        path: '${tempDir.path}/poster.png');
    FileSelectorPlatform.instance = _FakeFileSelector(
        [mediaFile('Waterfall (2026).mp4'), poster]);
    await openScreen(
        tester, _FakeFfmpeg({'Waterfall (2026).mp4': universalProbe}));
    await tester.tap(find.text('Choose a file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Describe this item'));
    await tester.pumpAndSettle();
    await describeAll(tester);

    final publish = find.ancestor(
        of: find.textContaining('Encode & upload'),
        matching: find.byType(FilledButton));
    await tester.ensureVisible(publish);
    await tester.tap(publish);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    // Still on setup, nothing uploaded or staged.
    expect(find.text('Choose a file'), findsNothing); // file still picked
    expect(find.textContaining('Encode & upload'), findsOneWidget);
    expect(fake.requests.where((r) => r == 'POST /upload'), isEmpty);
    expect(await ChannelService.instance.myItems(), isEmpty);
  });

  testWidgets('no wallet: setup nudge shown, publish stays gated',
      (tester) async {
    FileSelectorPlatform.instance = _FakeFileSelector([]);
    await openScreen(tester, _FakeFfmpeg({}));
    expect(find.text('No wallet set up yet'), findsOneWidget);
    expect(find.text('Set up wallet'), findsOneWidget);
    expect(find.text('Choose a file'), findsOneWidget);
  });
}
