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
import 'package:watchit/services/library_store.dart';
import 'package:watchit/theme/tokens.dart';

import 'fake_embedded_http.dart';

class _FakeFileSelector extends FileSelectorPlatform
    with MockPlatformInterfaceMixin {
  _FakeFileSelector(this.file);
  final XFile? file;

  @override
  Future<XFile?> openFile(
          {List<XTypeGroup>? acceptedTypeGroups,
          String? initialDirectory,
          String? confirmButtonText}) async =>
      file;
}

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
    tempDir = Directory.systemTemp.createTempSync('wi-publish-test');
  });

  tearDown(() {
    HttpOverrides.global = null;
    tempDir.deleteSync(recursive: true);
  });

  /// In-memory XFile with a real-looking path: `fromData` answers
  /// `length()` from the bytes (a path-backed XFile would do real file
  /// I/O, which never completes in the fake-async test zone).
  XFile mediaFile() => XFile.fromData(
        Uint8List.fromList([1, 2, 3, 4, 5]),
        path: '${tempDir.path}/My Film (2021).mp4',
      );

  Future<void> openPublish(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: const PublishScreen(apiBase: FakeEmbeddedHttp.base),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> pickAndEstimate(WidgetTester tester) async {
    FileSelectorPlatform.instance = _FakeFileSelector(mediaFile());
    await tester.tap(find.text('Choose a file to publish'));
    await tester.pumpAndSettle();
  }

  testWidgets('no wallet: setup nudge shown, no rights gate yet',
      (tester) async {
    await openPublish(tester);
    expect(find.text('No wallet set up yet'), findsOneWidget);
    expect(find.text('Set up wallet'), findsOneWidget);
    expect(find.text('Choose a file to publish'), findsOneWidget);
  });

  testWidgets(
      'pick → estimate → rights gate → publish → progress → done result',
      (tester) async {
    fake.wallet = {'address': '0xAbC0000000000000000000000000000000000001', 'storage': 'keychain'};
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
    await openPublish(tester);
    expect(find.textContaining('Wallet ready'), findsOneWidget);

    await pickAndEstimate(tester);
    expect(fake.requests, contains('POST /upload/estimate'));
    expect(find.textContaining('My Film (2021).mp4'), findsOneWidget);
    // 250000000000000000 atto → 0.25 ANT.
    expect(find.text('Estimated cost: 0.25 ANT'), findsOneWidget);
    expect(find.textContaining('3 chunks'), findsOneWidget);

    // Publish is gated on the rights checkbox.
    final publishButton = find.widgetWithText(FilledButton, 'Publish');
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

    expect(find.text('Published'), findsOneWidget);
    expect(find.text('ab' * 32), findsOneWidget);
    expect(find.textContaining('paid 0.25 ANT'), findsOneWidget);
    expect(find.text('Add to library'), findsOneWidget);
    expect(find.text('Save .datamap file'), findsOneWidget);
  });

  testWidgets('add to library creates a list holding the new entry',
      (tester) async {
    fake.wallet = {'address': '0x1', 'storage': 'keychain'};
    await openPublish(tester);
    await pickAndEstimate(tester);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Publish'));
    await tester.pump();
    // Immediate done (no staged states).
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('Published'), findsOneWidget);

    await tester.tap(find.text('Add to library'));
    await tester.pumpAndSettle();
    // Empty library → straight to the new-list prompt.
    await tester.enterText(find.byType(TextField), 'My uploads');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final lists = await LibraryStore.load();
    expect(lists, hasLength(1));
    expect(lists.single.title, 'My uploads');
    expect(lists.single.entries.single.address, 'ab' * 32);
    expect(lists.single.entries.single.name, 'My Film (2021).mp4');
    expect(lists.single.entries.single.sizeBytes, 5);
  });

  testWidgets('estimate failure surfaces the server text with retry',
      (tester) async {
    fake.wallet = {'address': '0x1', 'storage': 'keychain'};
    fake.estimateFailure =
        (503, 'not connected to the network yet: still dialling');
    await openPublish(tester);
    await pickAndEstimate(tester);
    expect(find.textContaining('not connected to the network'),
        findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    // Rights gate/publish never appears without an estimate.
    expect(find.byType(CheckboxListTile), findsNothing);

    fake.estimateFailure = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Estimated cost: 0.25 ANT'), findsOneWidget);
  });

  testWidgets('failed upload shows the error and offers a retry',
      (tester) async {
    fake.wallet = {'address': '0x1', 'storage': 'keychain'};
    fake.uploadStates.add({
      'phase': 'error',
      'error': 'upload failed: insufficient ANT balance',
    });
    await openPublish(tester);
    await pickAndEstimate(tester);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Publish'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('Upload failed'), findsOneWidget);
    expect(find.textContaining('insufficient ANT balance'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Try again'), findsOneWidget);
    expect(find.text('Start over'), findsOneWidget);
  });
}
