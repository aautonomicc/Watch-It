import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/screens/exit_info_screen.dart';
import 'package:watchit/screens/settings_screen.dart';
import 'package:watchit/services/exit_info.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/theme/tokens.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const channel = MethodChannel('watchit/exitinfo');

  /// Backs the channel with a canned platform answer (or an error).
  void mockPlatform(Object? Function() answer) {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getExitReasons');
      return answer();
    });
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    ExitInfoService.instance = ExitInfoService();
  });

  const nativeCrash = {
    'timestampMs': 1756400000000,
    'reason': 5,
    'reasonName': 'crash (native)',
    'status': 11,
    'description': 'crash in libvulkan',
    'trace': 'signal 11 (SIGSEGV)\n  #00 pc 0000 libvulkan.so',
  };

  const selfExit = {
    'timestampMs': 1756300000000,
    'reason': 1,
    'reasonName': 'exit-self',
    'status': 0,
    'description': '',
    'trace': '',
  };

  group('ExitRecord', () {
    test('parses a full record and flags abnormality', () {
      final r = ExitRecord.fromMap(nativeCrash);
      expect(r.reasonName, 'crash (native)');
      expect(r.status, 11);
      expect(r.isAbnormal, isTrue);
      expect(r.reportText, contains('crash (native)'));
      expect(r.reportText, contains('libvulkan'));
      expect(ExitRecord.fromMap(selfExit).isAbnormal, isFalse);
    });

    test('missing fields fall back instead of throwing', () {
      final r = ExitRecord.fromMap(const {});
      expect(r.reasonName, 'unknown');
      expect(r.trace, '');
      expect(r.timestampMs, 0);
    });
  });

  group('ExitInfoService', () {
    test('not Android → empty, channel untouched', () async {
      var called = false;
      mockPlatform(() {
        called = true;
        return [nativeCrash];
      });
      final service = ExitInfoService(isAndroid: false);
      expect(await service.fetch(), isEmpty);
      expect(called, isFalse);
      expect(service.supported, isFalse);
    });

    test('parses the platform answer', () async {
      mockPlatform(() => [nativeCrash, selfExit]);
      final service = ExitInfoService(isAndroid: true);
      final records = await service.fetch();
      expect(records, hasLength(2));
      expect(records.first.reasonName, 'crash (native)');
      expect(records.last.reasonName, 'exit-self');
    });

    test('a platform error answers empty — never throws into Settings',
        () async {
      mockPlatform(() => throw PlatformException(code: 'nope'));
      expect(await ExitInfoService(isAndroid: true).fetch(), isEmpty);
    });
  });

  Widget app(Widget home) => MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: home,
      );

  group('ExitInfoScreen', () {
    testWidgets('renders records with trace and highlights the crash',
        (tester) async {
      mockPlatform(() => [nativeCrash, selfExit]);
      await tester.pumpWidget(app(
          ExitInfoScreen(service: ExitInfoService(isAndroid: true))));
      await tester.pumpAndSettle();
      expect(find.text('crash (native)'), findsOneWidget);
      expect(find.text('exit-self'), findsOneWidget);
      expect(find.textContaining('SIGSEGV'), findsOneWidget);
      expect(find.textContaining('crash in libvulkan'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_outlined), findsOneWidget);
    });

    testWidgets('empty history says so', (tester) async {
      mockPlatform(() => const <Object?>[]);
      await tester.pumpWidget(app(
          ExitInfoScreen(service: ExitInfoService(isAndroid: true))));
      await tester.pumpAndSettle();
      expect(find.text('No recorded exits yet.'), findsOneWidget);
    });

    testWidgets('Copy puts the whole report on the clipboard',
        (tester) async {
      mockPlatform(() => [nativeCrash]);
      String? copied;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.pumpWidget(app(
          ExitInfoScreen(service: ExitInfoService(isAndroid: true))));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.copy_all));
      await tester.pumpAndSettle();
      expect(copied, contains('crash (native)'));
      expect(copied, contains('SIGSEGV'));
    });
  });

  group('Settings tile', () {
    Future<void> pumpSettings(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      await LibraryStore.useForTesting(
          AppDatabase.forTesting(NativeDatabase.memory()));
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app(const SettingsScreen()));
      await tester.pumpAndSettle();
    }

    testWidgets('shown on Android and opens the screen', (tester) async {
      mockPlatform(() => const <Object?>[]);
      ExitInfoService.instance = ExitInfoService(isAndroid: true);
      await pumpSettings(tester);
      expect(find.text('Why did the app close?'), findsOneWidget);
      await tester.tap(find.text('Why did the app close?'));
      await tester.pumpAndSettle();
      expect(find.byType(ExitInfoScreen), findsOneWidget);
    });

    testWidgets('hidden off Android', (tester) async {
      ExitInfoService.instance = ExitInfoService(isAndroid: false);
      await pumpSettings(tester);
      expect(find.text('Why did the app close?'), findsNothing);
    });
  });
}
