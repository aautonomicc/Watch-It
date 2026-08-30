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
import 'package:watchit/screens/publish_screen.dart';
import 'package:watchit/services/ffmpeg.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/publish_plan.dart';
import 'package:watchit/services/publish_session.dart';
import 'package:watchit/theme/tokens.dart';

import 'fake_embedded_http.dart';

class _FakeFileSelector extends FileSelectorPlatform
    with MockPlatformInterfaceMixin {
  _FakeFileSelector(this.files, {this.directory});
  final List<XFile> files;
  final String? directory;

  @override
  Future<List<XFile>> openFiles(
          {List<XTypeGroup>? acceptedTypeGroups,
          String? initialDirectory,
          String? confirmButtonText}) async =>
      files;

  @override
  Future<String?> getDirectoryPath(
          {String? initialDirectory, String? confirmButtonText}) async =>
      directory;
}

/// Probe/encode without real processes: probes come from a canned map by
/// file name, encodes just record themselves and report completion.
class _FakeFfmpeg extends FfmpegService {
  _FakeFfmpeg(this.probes, {this.isAvailable = true});
  final Map<String, MediaProbe?> probes;
  final bool isAvailable;
  final List<String> encodes = [];

  @override
  Future<bool> get available async => isAvailable;

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

/// A 4K HEVC probe — every encode tier applies, original starts unticked.
const hevc4kProbe = MediaProbe(
  hasVideo: true,
  width: 3840,
  height: 2160,
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
    PublishSession.resetForTesting();
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    fake = FakeEmbeddedHttp();
    HttpOverrides.global = fake;
    tempDir = Directory.systemTemp.createTempSync('wi-publish-test');
  });

  tearDown(() {
    HttpOverrides.global = null;
    tempDir.deleteSync(recursive: true);
  });

  /// In-memory XFile with a real-looking path: `fromData` answers
  /// `length()` from the bytes (a path-backed XFile would do real file
  /// I/O, which never completes in the fake-async test zone).
  XFile mediaFile(String name, [int bytes = 5]) => XFile.fromData(
        Uint8List.fromList(List.filled(bytes, 1)),
        path: '${tempDir.path}/$name',
      );

  Future<void> openPublish(WidgetTester tester, _FakeFfmpeg ffmpeg) async {
    // Tall surface so the whole setup page renders — the ListView builds
    // lazily and the tier/estimate/rights widgets sit below the fold at
    // the default test size.
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: PublishScreen(apiBase: FakeEmbeddedHttp.base, ffmpeg: ffmpeg),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> pickAndEstimate(WidgetTester tester) async {
    await tester.tap(find.text('Choose files to upload'));
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

  testWidgets('no wallet: setup nudge shown, no rights gate yet',
      (tester) async {
    FileSelectorPlatform.instance = _FakeFileSelector([]);
    await openPublish(tester, _FakeFfmpeg({}));
    expect(find.text('No wallet set up yet'), findsOneWidget);
    expect(find.text('Set up wallet'), findsOneWidget);
    expect(find.text('Choose files to upload'), findsOneWidget);
  });

  testWidgets(
      'pick → estimate → rights gate → publish → progress → done result',
      (tester) async {
    fake.wallet = {
      'address': '0xAbC0000000000000000000000000000000000001',
      'storage': 'keychain'
    };
    fake.uploadStates.addAll([
      {'phase': 'encrypting', 'done': 1, 'total': 0},
      {'phase': 'storing', 'done': 2, 'total': 3},
      {
        'phase': 'done',
        'done': 3,
        'total': 3,
        'result': fake.uploadResult,
      },
    ]);
    FileSelectorPlatform.instance =
        _FakeFileSelector([mediaFile('My Film (2021).mp4')]);
    await openPublish(
        tester, _FakeFfmpeg({'My Film (2021).mp4': universalProbe}));
    expect(find.textContaining('Wallet ready'), findsOneWidget);

    await pickAndEstimate(tester);
    expect(fake.requests, contains('POST /upload/estimate'));
    expect(find.textContaining('My Film (2021).mp4'), findsOneWidget);
    expect(find.textContaining('plays everywhere'), findsOneWidget);
    // 250000000000000000 atto → 0.25 ANT for the single as-is upload.
    expect(find.textContaining('estimated cost ≈0.25 ANT'), findsOneWidget);

    // Publish is gated on the rights checkbox.
    final publishButton = find.widgetWithText(FilledButton, 'Upload');
    expect(tester.widget<FilledButton>(publishButton).onPressed, isNull);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    expect(tester.widget<FilledButton>(publishButton).onPressed, isNotNull);

    await tester.tap(publishButton);
    await tester.pump();
    expect(fake.requests, contains('POST /upload'));

    // Poll ticks walk the staged phases.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('Encrypting file…'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.textContaining('Storing chunks (2 of 3)'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(find.text('Uploaded'), findsOneWidget);
    expect(find.textContaining('1 of 1 uploads finished'), findsOneWidget);
    expect(find.textContaining('paid 0.25 ANT'), findsOneWidget);
    expect(find.text('Add to library'), findsOneWidget);
    expect(find.text('Save .datamap file'), findsOneWidget);
  });

  testWidgets('series: two files upload in turn, both land in one list',
      (tester) async {
    fake.wallet = {'address': '0x1', 'storage': 'keychain'};
    fake.uploadResults = [
      {...fake.uploadResult, 'address': 'aa' * 32},
      {...fake.uploadResult, 'address': 'bb' * 32},
    ];
    fake.datamaps['aa' * 32] = [1, 2, 3];
    fake.datamaps['bb' * 32] = [4, 5, 6];
    final saveDir = Directory('${tempDir.path}/maps')..createSync();
    FileSelectorPlatform.instance = _FakeFileSelector([
      mediaFile('Show S01E01.mp4'),
      mediaFile('Show S01E02.mp4', 7),
    ], directory: saveDir.path);
    await openPublish(
        tester,
        _FakeFfmpeg({
          'Show S01E01.mp4': universalProbe,
          'Show S01E02.mp4': universalProbe,
        }));
    await pickAndEstimate(tester);
    expect(find.text('FILES (2)'), findsOneWidget);
    expect(find.textContaining('2 uploads · estimated cost'), findsOneWidget);

    await tester.tap(find.byType(CheckboxListTile).last); // rights
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Upload 2 files'));
    await tester.pump();
    await pumpUploads(tester, 2);

    expect(find.text('Uploaded'), findsOneWidget);
    expect(find.textContaining('2 of 2 uploads finished'), findsOneWidget);
    expect(find.textContaining('paid 0.5 ANT'), findsOneWidget);

    await tester.tap(find.text('Add to library'));
    await tester.pumpAndSettle();
    // Empty library → straight to the new-list prompt.
    await tester.enterText(find.byType(TextField), 'My uploads');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final lists = await LibraryStore.load();
    expect(lists, hasLength(1));
    expect(lists.single.title, 'My uploads');
    expect(lists.single.entries, hasLength(2));
    expect(lists.single.entries[0].name, 'Show S01E01 [480p].mp4');
    expect(lists.single.entries[0].address, 'aa' * 32);
    expect(lists.single.entries[0].videoInfo, '480p H.264');
    expect(lists.single.entries[1].name, 'Show S01E02 [480p].mp4');
    expect(lists.single.entries[1].sizeBytes, 5);

    // Batch datamap export writes one file per published title.
    await tester.tap(find.text('Save 2 .datamap files'));
    await tester.pumpAndSettle();
    expect(
        File('${saveDir.path}/Show S01E01 [480p].mp4.datamap').readAsBytesSync(),
        [1, 2, 3]);
    expect(
        File('${saveDir.path}/Show S01E02 [480p].mp4.datamap').readAsBytesSync(),
        [4, 5, 6]);
  });

  testWidgets('tier checkboxes drive encodes and output names',
      (tester) async {
    fake.wallet = {'address': '0x1', 'storage': 'keychain'};
    fake.uploadResults = [
      {...fake.uploadResult, 'address': 'aa' * 32},
      {...fake.uploadResult, 'address': 'bb' * 32},
      {...fake.uploadResult, 'address': 'cc' * 32},
    ];
    final ffmpeg = _FakeFfmpeg({'Movie (2020).mkv': hevc4kProbe});
    FileSelectorPlatform.instance =
        _FakeFileSelector([mediaFile('Movie (2020).mkv')]);
    await openPublish(tester, ffmpeg);
    await pickAndEstimate(tester);

    // 4K HEVC: warned about, offered High/Medium/Low (ticked) + Original
    // (unticked).
    expect(find.textContaining("can't play"), findsOneWidget);
    expect(find.text('High · 1080p H.264'), findsOneWidget);
    expect(find.text('Medium · 720p H.264'), findsOneWidget);
    expect(find.text('Low · 480p H.264'), findsOneWidget);
    expect(find.text('Original files (as-is)'), findsOneWidget);
    expect(find.textContaining('3 uploads · estimated cost'), findsOneWidget);

    // Untick Low: two uploads remain.
    await tester.tap(find.text('Low · 480p H.264'));
    await tester.pump();
    expect(find.textContaining('2 uploads · estimated cost'), findsOneWidget);

    // Rights checkbox is the last CheckboxListTile on the page.
    await tester.tap(find.byType(CheckboxListTile).last);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Upload 2 files'));
    await tester.pump();
    await pumpUploads(tester, 2);

    expect(ffmpeg.encodes, [
      'Movie (2020).mkv → Movie (2020) [1080p].mp4',
      'Movie (2020).mkv → Movie (2020) [720p].mp4',
    ]);
    expect(find.text('Uploaded'), findsOneWidget);
    expect(find.textContaining('2 of 2 uploads finished'), findsOneWidget);
    expect(find.textContaining('Movie (2020) [1080p].mp4'), findsWidgets);
    expect(find.textContaining('Movie (2020) [720p].mp4'), findsWidgets);
  });

  testWidgets('quality info button explains why versions are encoded',
      (tester) async {
    fake.wallet = {'address': '0x1', 'storage': 'keychain'};
    FileSelectorPlatform.instance =
        _FakeFileSelector([mediaFile('Movie (2020).mkv')]);
    await openPublish(
        tester, _FakeFfmpeg({'Movie (2020).mkv': hevc4kProbe}));
    await pickAndEstimate(tester);

    expect(find.textContaining('Devices and connections vary'),
        findsOneWidget);
    await tester.tap(find.byTooltip('Why multiple versions?'));
    await tester.pumpAndSettle();
    expect(find.text('Why multiple versions?'), findsOneWidget);
    expect(find.textContaining('replaced with a re-encoded copy'),
        findsOneWidget);
    expect(find.textContaining('version picker'), findsWidgets);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Why multiple versions?'), findsNothing);
  });

  testWidgets('files matching no ticked quality are called out',
      (tester) async {
    fake.wallet = {'address': '0x1', 'storage': 'keychain'};
    FileSelectorPlatform.instance = _FakeFileSelector([
      mediaFile('Old Short.mp4'), // 480p universal: as-is only
      mediaFile('Fresh Rip.mkv'), // 4K HEVC: encode tiers
    ]);
    await openPublish(
        tester,
        _FakeFfmpeg({
          'Old Short.mp4': universalProbe,
          'Fresh Rip.mkv': hevc4kProbe,
        }));
    await pickAndEstimate(tester);
    // Union default covers both files — no warning.
    expect(find.textContaining('will be skipped'), findsNothing);

    await tester.tap(find.text('Original files (as-is)'));
    await tester.pump();
    expect(find.textContaining('will be skipped'), findsOneWidget);
    expect(find.textContaining('Old Short.mp4'), findsWidgets);
  });

  testWidgets('estimate failure surfaces the server text with retry',
      (tester) async {
    fake.wallet = {'address': '0x1', 'storage': 'keychain'};
    fake.estimateFailure =
        (503, 'not connected to the network yet: still dialling');
    FileSelectorPlatform.instance =
        _FakeFileSelector([mediaFile('My Film (2021).mp4')]);
    await openPublish(
        tester, _FakeFfmpeg({'My Film (2021).mp4': universalProbe}));
    await pickAndEstimate(tester);
    expect(find.textContaining('not connected to the network'),
        findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    fake.estimateFailure = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.textContaining('estimated cost ≈0.25 ANT'), findsOneWidget);
  });

  testWidgets('failed upload offers retry/skip/stop; skip finishes batch',
      (tester) async {
    fake.wallet = {'address': '0x1', 'storage': 'keychain'};
    fake.uploadStates.add({
      'phase': 'error',
      'error': 'upload failed: insufficient ANT balance',
    });
    FileSelectorPlatform.instance =
        _FakeFileSelector([mediaFile('My Film (2021).mp4')]);
    await openPublish(
        tester, _FakeFfmpeg({'My Film (2021).mp4': universalProbe}));
    await pickAndEstimate(tester);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Upload'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(find.textContaining('My Film (2021) [480p].mp4 failed'), findsOneWidget);
    expect(find.textContaining('insufficient ANT balance'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Try again'), findsOneWidget);
    expect(find.text('Skip this file'), findsOneWidget);

    await tester.tap(find.text('Skip this file'));
    await tester.pumpAndSettle();
    expect(find.text('Uploaded'), findsOneWidget);
    expect(find.textContaining('0 of 1 uploads finished'), findsOneWidget);
    expect(find.textContaining('1 skipped'), findsOneWidget);
    // Nothing published → no add-to-library offer.
    expect(find.text('Add to library'), findsNothing);
    expect(find.text('Upload more'), findsOneWidget);
  });

  testWidgets(
      'leaving mid-upload and returning shows the running batch, then done',
      (tester) async {
    fake.wallet = {'address': '0x1', 'storage': 'keychain'};
    fake.uploadStates.addAll([
      {'phase': 'storing', 'done': 1, 'total': 3},
      {'phase': 'storing', 'done': 2, 'total': 3},
      {
        'phase': 'done',
        'done': 3,
        'total': 3,
        'result': fake.uploadResult,
      },
    ]);
    FileSelectorPlatform.instance =
        _FakeFileSelector([mediaFile('My Film (2021).mp4')]);
    final ffmpeg = _FakeFfmpeg({'My Film (2021).mp4': universalProbe});
    await openPublish(tester, ffmpeg);
    await pickAndEstimate(tester);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Upload'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.textContaining('Storing chunks'), findsOneWidget);

    // Leave the Upload page mid-upload (the old behaviour dropped the
    // batch and a fresh screen showed the setup page)...
    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    // ...and come back: the same batch is still running and on show.
    await openPublish(tester, ffmpeg);
    expect(find.text('Choose files to upload'), findsNothing);
    expect(find.textContaining('Uploading · task 1 of 1'), findsOneWidget);

    // It finishes while the page is open; the done page offers the
    // library actions that were unreachable before.
    await pumpUploads(tester, 1);
    expect(find.text('Uploaded'), findsOneWidget);
    expect(find.text('Add to library'), findsOneWidget);

    // Upload more resets to a fresh setup page.
    await tester.tap(find.text('Upload more'));
    await tester.pump();
    expect(find.text('Choose files to upload'), findsOneWidget);
  });

  testWidgets('ffmpeg missing: as-is only banner, publish still works',
      (tester) async {
    fake.wallet = {'address': '0x1', 'storage': 'keychain'};
    FileSelectorPlatform.instance =
        _FakeFileSelector([mediaFile('Clip.webm')]);
    await openPublish(tester, _FakeFfmpeg({}, isAvailable: false));
    await pickAndEstimate(tester);
    expect(find.textContaining('quality tiers are unavailable'),
        findsOneWidget);
    expect(find.textContaining('Could not read this file'), findsOneWidget);
    expect(find.textContaining('1 upload · estimated cost'), findsOneWidget);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Upload'));
    await tester.pump();
    await pumpUploads(tester, 1);
    expect(find.text('Uploaded'), findsOneWidget);
    expect(find.textContaining('1 of 1 uploads finished'), findsOneWidget);
  });
}
