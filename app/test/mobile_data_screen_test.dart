import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/screens/mobile_data_screen.dart';
import 'package:watchit/services/app_settings.dart';
import 'package:watchit/services/x0x_cellular.dart';
import 'package:watchit/theme/tokens.dart';

/// Records policy-change notifications instead of talking to the
/// embedded client.
class _RecordingGate extends X0xCellularGate {
  int policyChanges = 0;

  @override
  Future<void> onPolicyChanged() {
    policyChanges++;
    return Future.value();
  }
}

void main() {
  late _RecordingGate gate;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    gate = _RecordingGate();
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: MobileDataScreen(gate: gate),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('shows all four consumers with their defaults',
      (tester) async {
    await open(tester);

    expect(find.text('Streaming'), findsOneWidget);
    expect(find.text('Downloads'), findsOneWidget);
    expect(find.text('Channels'), findsOneWidget);
    expect(find.text('My W@tch'), findsOneWidget);
    // Defaults: streaming asks, downloads Wi-Fi only, x0x allowed.
    expect(find.text('Ask first'), findsOneWidget);
    expect(find.text('Wi-Fi only'), findsOneWidget);
    expect(find.text('May use mobile data'), findsNWidgets(2));
    final switches =
        tester.widgetList<SwitchListTile>(find.byType(SwitchListTile));
    expect(switches.map((s) => s.value), everyElement(isTrue));
  });

  testWidgets('streaming policy change persists', (tester) async {
    await open(tester);

    await tester.tap(find.text('Streaming'));
    await tester.pumpAndSettle();
    expect(find.text('Streaming on mobile data'), findsOneWidget);
    // Pick Wi-Fi only from the dialog (the Downloads tile already shows
    // the same words — the dialog's copy is the second on screen).
    await tester.tap(find.text('Wi-Fi only').last);
    await tester.pumpAndSettle();

    expect(await AppSettings.streamingNetworkPolicy(),
        StreamingNetworkPolicy.wifiOnly);
    // Tile now shows the choice (plus the Downloads tile's own).
    expect(find.text('Wi-Fi only'), findsNWidgets(2));
  });

  testWidgets('downloads policy change persists', (tester) async {
    await open(tester);

    await tester.tap(find.text('Downloads'));
    await tester.pumpAndSettle();
    expect(find.text('Download over'), findsOneWidget);
    await tester.tap(find.text('Wi-Fi + mobile data'));
    await tester.pumpAndSettle();

    expect(await AppSettings.downloadNetworkPolicy(),
        DownloadNetworkPolicy.any);
    expect(find.text('Wi-Fi + mobile data'), findsOneWidget);
  });

  testWidgets('x0x switches persist and poke the gate', (tester) async {
    await open(tester);

    // Channels off (the first SwitchListTile).
    await tester.tap(find.byType(SwitchListTile).first);
    await tester.pumpAndSettle();
    expect(await AppSettings.channelsOnCellular(), isFalse);
    expect(await AppSettings.myWatchOnCellular(), isTrue);
    expect(gate.policyChanges, 1);
    expect(
        find.text('Wi-Fi only — pauses on mobile data, resumes on Wi-Fi'),
        findsOneWidget);

    // My W@tch off too.
    await tester.tap(find.byType(SwitchListTile).last);
    await tester.pumpAndSettle();
    expect(await AppSettings.myWatchOnCellular(), isFalse);
    expect(gate.policyChanges, 2);

    // And back on.
    await tester.tap(find.byType(SwitchListTile).first);
    await tester.pumpAndSettle();
    expect(await AppSettings.channelsOnCellular(), isTrue);
    expect(gate.policyChanges, 3);
  });
}
