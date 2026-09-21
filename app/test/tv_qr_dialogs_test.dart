import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchit/screens/channels_screen.dart';
import 'package:watchit/services/my_watch_api.dart';
import 'package:watchit/services/tv_settings.dart';
import 'package:watchit/theme/tokens.dart';
import 'package:watchit/widgets/pair_dialogs.dart';
import 'package:watchit/widgets/tv_app_frame.dart';
import 'package:watchit/widgets/wi_qr.dart';

// QR dialogs on a real TV viewport (1920×1080 physical at DPR 2 =
// 960×540 logical, minus the 5% overscan margins and the 1.15 text
// scale): a fixed-size QR pushed its own bottom third out of the
// dialog — the Streamer tester's "pairing QR clipped at the bottom"
// report. The QR now shrinks to the height the dialog really has
// (WiQrCard) and every action stays on screen.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TvSettings.instance = TvSettings(enabled: true);
  });
  tearDown(() {
    TvSettings.instance.dispose();
    TvSettings.instance = TvSettings();
  });

  const pairCode =
      'wtchp1-000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'
      '202122232425262728292a2b2c2d2e2f';
  const channelCode = 'wchn1-gnidyresagnidyresagnidyresagnidyresagnidyresa';

  void tvViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> showOnTv(
    WidgetTester tester,
    Widget Function(BuildContext) dialog,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        builder: (context, child) => TvAppFrame(child: child!),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: dialog,
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  void expectQrFitsWithActions(WidgetTester tester, String actionLabel) {
    final logicalHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final qr = tester.widget<WiQr>(find.byType(WiQr));
    expect(qr.size, lessThan(220), reason: 'QR must shrink on a small TV');
    expect(qr.size, greaterThanOrEqualTo(120),
        reason: 'below ~120px the code stops scanning');
    final qrRect = tester.getRect(find.byType(WiQr));
    expect(qrRect.bottom, lessThanOrEqualTo(logicalHeight),
        reason: 'the whole QR stays on screen');
    final action = tester.getRect(find.text(actionLabel));
    expect(action.bottom, lessThanOrEqualTo(logicalHeight));
  }

  testWidgets('pairing QR dialog fits a 960×540 TV whole', (tester) async {
    tvViewport(tester);
    await showOnTv(
      tester,
      (_) => PairCodeDialog(
        api: MyWatchApi(base: 'http://127.0.0.1:1'),
        code: pairCode,
        // Never fires within the test — the dialog is layout-only here.
        pollInterval: const Duration(days: 1),
      ),
    );
    expect(find.byType(PairCodeDialog), findsOneWidget);
    expectQrFitsWithActions(tester, 'Cancel');
    // Cancels the poll timer.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('channel share-code dialog fits a 960×540 TV whole',
      (tester) async {
    tvViewport(tester);
    await showOnTv(tester, (_) => const ChannelQrDialog(code: channelCode));
    expect(find.text(channelCode), findsOneWidget);
    expectQrFitsWithActions(tester, 'Copy & close');
  });

  testWidgets('with room to spare the QR keeps its natural size',
      (tester) async {
    // Default 800×600 test viewport, no TV frame.
    TvSettings.instance.enabled = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: const Scaffold(body: ChannelQrDialog(code: channelCode)),
      ),
    );
    await tester.pump();
    expect(tester.widget<WiQr>(find.byType(WiQr)).size, 220);
  });
}
