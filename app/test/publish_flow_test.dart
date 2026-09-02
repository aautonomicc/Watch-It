import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchit/screens/batch_upload_screen.dart';
import 'package:watchit/screens/publish_screen.dart';
import 'package:watchit/services/batch_upload.dart';
import 'package:watchit/theme/tokens.dart';

import 'fake_embedded_http.dart';

/// The Upload screen after the tier-flow merge: it is the doorway to
/// the batch uploader (wallet state + one primary way in + the
/// needs-attention pointer); quality tiers live on the batch review
/// page and are covered by batch_upload_flow_test.dart.
void main() {
  late FakeEmbeddedHttp fake;
  late Directory tempDir;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BatchUploadSession.resetForTesting();
    fake = FakeEmbeddedHttp();
    HttpOverrides.global = fake;
    tempDir = Directory.systemTemp.createTempSync('wi-publish-test');
  });

  tearDown(() {
    BatchUploadSession.resetForTesting();
    HttpOverrides.global = null;
    tempDir.deleteSync(recursive: true);
  });

  Future<void> openPublish(WidgetTester tester,
      {Future<Directory> Function()? batchRoot}) async {
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: PublishScreen(
        apiBase: FakeEmbeddedHttp.base,
        batchRootProvider: batchRoot ??
            () async => Directory('${tempDir.path}/none'),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('no wallet: setup nudge, one primary way in, no tier flow',
      (tester) async {
    await openPublish(tester);
    expect(find.text('No wallet set up yet'), findsOneWidget);
    expect(find.text('Set up wallet'), findsOneWidget);
    expect(find.text('Upload files or folders'), findsOneWidget);
    // The old competing tier entry point is gone — encoding now lives
    // on the batch review page.
    expect(find.text('Encode quality versions…'), findsNothing);
    expect(find.text('ADVANCED'), findsNothing);
  });

  testWidgets('configured wallet shows the shortened address',
      (tester) async {
    fake.wallet = {
      'configured': true,
      'address': '0x1234567890abcdef1234567890abcdef12345678',
      'storage': 'keychain',
    };
    await openPublish(tester);
    expect(find.textContaining('Wallet ready'), findsOneWidget);
    expect(find.text('0x123456…5678'), findsOneWidget);
  });

  testWidgets('primary button opens the batch uploader', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await openPublish(tester);
    await tester.tap(find.text('Upload files or folders'));
    await tester.pumpAndSettle();
    expect(find.byType(BatchUploadScreen), findsOneWidget);
    expect(find.text('Add files'), findsOneWidget);
    expect(find.text('Add a folder'), findsOneWidget);
  });

  testWidgets(
      'needs-attention files from earlier batches surface a pointer',
      (tester) async {
    // A previous batch's manifest with one unresolved file that still
    // exists on disk (missing files must not count).
    final root = Directory('${tempDir.path}/batch_uploads/old-batch')
      ..createSync(recursive: true);
    final present = File('${tempDir.path}/mystery.mp4')
      ..writeAsBytesSync([1, 2, 3]);
    File('${root.path}/watchit-manifest.yaml').writeAsStringSync('''
version: 1
list_name: "Old Batch"
entries:
  - source: "${present.path}"
    status: "needs-attention"
  - source: "${tempDir.path}/gone.mp4"
    status: "needs-attention"
  - source: "${tempDir.path}/fine.mp4"
    status: "uploaded"
''');
    await openPublish(tester,
        batchRoot: () async => Directory('${tempDir.path}/batch_uploads'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining(
            '1 file from earlier uploads still needs attention'),
        findsOneWidget);
  });

  testWidgets(
      'running session: doorway shows the in-progress card, not the '
      'fresh-start button, and returns straight to the upload',
      (tester) async {
    final session = BatchUploadSession.instance;
    session.stage = BatchStage.uploading;
    session.uploadDone = 1;
    session.uploadTotal = 3;
    await openPublish(tester);
    expect(find.text('Upload in progress'), findsOneWidget);
    expect(find.text('Uploading · 2 of 3'), findsOneWidget);
    expect(find.text('Upload files or folders'), findsNothing);
    await tester.tap(find.text('Return to the upload'));
    // Plain pumps — the uploading page's indeterminate progress bar
    // never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // Lands on the uploader showing the running batch, not setup.
    expect(find.byType(BatchUploadScreen), findsOneWidget);
    expect(find.text('Add files'), findsNothing);
  });
}
