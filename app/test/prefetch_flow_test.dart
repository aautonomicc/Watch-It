import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/models/media_list.dart';
import 'package:watchit/screens/media_lists_screen.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/services/prefetch_manager.dart';
import 'package:watchit/theme/tokens.dart';

const _addrA =
    '66cacd06ae5b02aeb0b4b8a463885bd7ec392b1b4291c1eda75253e831c1bcbb';
const _addrB =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

class _FakeFileSelector extends FileSelectorPlatform
    with MockPlatformInterfaceMixin {
  _FakeFileSelector(this.file);
  final XFile? file;

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async =>
      file;
}

/// HTTP mock whose requests stay pending until [release]d, so a prefetch
/// run can be observed in flight under the fake-async test zone. (A real
/// localhost server can't do this: the prefetcher's HttpClient is created
/// in the fake-async zone by the button tap, so its socket futures never
/// complete — not even inside runAsync — and the test deadlocks.)
class _GatedHttpOverrides extends HttpOverrides {
  final _GatedHttpClient client = _GatedHttpClient();

  @override
  HttpClient createHttpClient(SecurityContext? context) => client;
}

class _GatedHttpClient implements HttpClient {
  bool _open = false;
  final List<Completer<void>> _gates = [];

  /// Complete pending requests and let all future ones through.
  void release() {
    _open = true;
    for (final g in _gates) {
      if (!g.isCompleted) g.complete();
    }
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    if (!_open) {
      final gate = Completer<void>();
      _gates.add(gate);
      await gate.future;
    }
    return _GatedRequest();
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _GatedRequest implements HttpClientRequest {
  @override
  Future<HttpClientResponse> close() async => _GatedResponse();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _GatedResponse extends Stream<List<int>>
    implements HttpClientResponse {
  @override
  int get statusCode => 200;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      Stream<List<int>>.fromIterable([utf8.encode('{"size":1,"chunks":1}')])
          .listen(onData,
              onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
    FileSelectorPlatform.instance = _FakeFileSelector(XFile.fromData(
      utf8.encode('Prefetch Movies\n'
          '$_addrA First Movie (2024).mkv\n'
          '$_addrB Second Movie (1999).mp4\n'),
      name: 'movies.list',
    ));
  });

  Future<void> importWithPrefetchServer(WidgetTester tester) async {
    // Any non-null base makes the prefetcher "available"; widget tests
    // mock all HTTP to status 400, so every resolve deterministically
    // fails — which is exactly the wiring (dialogs, counters, summary)
    // this test is about.
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: const MediaListsScreen(prefetchBase: 'http://127.0.0.1:1'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Import list from file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local file'));
    await tester.pumpAndSettle();
  }

  testWidgets('import offers a prefetch and Skip declines it',
      (tester) async {
    await importWithPrefetchServer(tester);
    expect(find.text('Prefetch data maps?'), findsOneWidget);
    expect(find.textContaining('each of the 2 imported files'),
        findsOneWidget);
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(find.text('Prefetch data maps?'), findsNothing);
    expect(find.textContaining('File 1 of'), findsNothing);
    // The list itself imported regardless.
    final list = (await LibraryStore.load())
        .firstWhere((l) => l.title == 'Prefetch Movies');
    expect(list.entries, hasLength(2));
  });

  testWidgets('Prefetch walks every file and reports a summary',
      (tester) async {
    await importWithPrefetchServer(tester);
    await tester.tap(find.text('Prefetch'));
    await tester.pumpAndSettle();
    // The summary snackbar queues behind the import one — let that expire.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    // Mocked HTTP fails every resolve; the summary still names the count
    // and the resolve-on-first-play fallback.
    expect(
        find.textContaining('2 failed — those resolve on first play'),
        findsOneWidget);
    expect(find.textContaining('File 1 of'), findsNothing); // dialog closed
  });

  testWidgets(
      'Hide backgrounds the prefetch; the app bar action reopens it',
      (tester) async {
    // Gated HTTP mock: the first resolve stays pending (so the dialog is
    // observably in flight — the default widget-test mock completes
    // instantly, closing it before Hide can be tapped) until release().
    final overrides = _GatedHttpOverrides();
    final saved = HttpOverrides.current;
    HttpOverrides.global = overrides;
    try {
      await tester.pumpWidget(MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: const MediaListsScreen(prefetchBase: 'http://127.0.0.1:1'),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Import list from file'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Local file'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prefetch'));
      await tester.pump();
      // In-flight: progress dialog with both actions.
      expect(find.text('File 1 of 2'), findsOneWidget);
      expect(find.text('Hide'), findsOneWidget);
      await tester.tap(find.text('Hide'));
      await tester.pumpAndSettle();
      expect(find.text('File 1 of 2'), findsNothing);
      expect(PrefetchManager.instance.running, isTrue);
      // Reopen the hidden run from the app-bar action — no confirm
      // dialog, straight back to live progress.
      await tester.tap(find.byTooltip('Prefetch data maps'));
      await tester.pump();
      expect(find.text('File 1 of 2'), findsOneWidget);
      // Let both resolves finish; the dialog closes itself.
      overrides.client.release();
      await tester.pumpAndSettle();
      expect(PrefetchManager.instance.running, isFalse);
      expect(find.text('Hide'), findsNothing);
    } finally {
      HttpOverrides.global = saved;
    }
  });

  testWidgets('app bar action prefetches all lists after confirming',
      (tester) async {
    await LibraryStore.save(const [
      MediaList(id: 'l1', title: 'Movies', entries: [
        MediaEntry(name: 'First Movie (2024).mkv', address: _addrA),
        MediaEntry(name: 'Second Movie (1999).mp4', address: _addrB),
      ]),
    ]);
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: const MediaListsScreen(prefetchBase: 'http://127.0.0.1:1'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Prefetch data maps'));
    await tester.pumpAndSettle();
    expect(find.textContaining('resumes a cancelled prefetch'),
        findsOneWidget);
    await tester.tap(find.text('Prefetch'));
    await tester.pumpAndSettle();
    // Mocked HTTP fails every resolve; the summary names the fallback.
    expect(find.textContaining('2 failed — those resolve on first play'),
        findsOneWidget);
  });

  testWidgets('app bar action with empty lists explains itself',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: const MediaListsScreen(prefetchBase: 'http://127.0.0.1:1'),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Prefetch data maps'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No entries to prefetch'), findsOneWidget);
  });

  testWidgets('no prefetch offer without an embedded server',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: const MediaListsScreen(),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Import list from file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local file'));
    await tester.pumpAndSettle();
    expect(find.text('Prefetch data maps?'), findsNothing);
    expect(find.textContaining('Imported "Prefetch Movies"'),
        findsOneWidget);
  });
}
