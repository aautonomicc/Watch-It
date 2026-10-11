import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchit/screens/publish_screen.dart'
    show debugDesktopPlatformOverride;
import 'package:watchit/screens/wallet_screen.dart';
import 'package:watchit/services/publish_api.dart';
import 'package:watchit/theme/tokens.dart';

import 'fake_embedded_http.dart';

/// Hardware-wallet (Trezor) setup + configured-state coverage — phase 3
/// of the hardware-wallet plan. The fake server simulates the device:
/// `trezorError == null` means a Trezor answers at `trezorAddress`.
void main() {
  late FakeEmbeddedHttp fake;

  setUp(() {
    fake = FakeEmbeddedHttp();
    HttpOverrides.global = fake;
    debugDesktopPlatformOverride = true;
  });

  tearDown(() {
    HttpOverrides.global = null;
    debugDesktopPlatformOverride = null;
  });

  Future<void> openWallet(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: const WalletScreen(apiBase: FakeEmbeddedHttp.base),
    ));
    await tester.pumpAndSettle();
  }

  group('Trezor setup', () {
    testWidgets('desktop setup offers the hardware option, mobile hides it',
        (tester) async {
      await openWallet(tester);
      expect(
          find.text('Connect a hardware wallet (Trezor)'), findsOneWidget);
      expect(find.textContaining('never leaves the'), findsOneWidget);

      // Unmount first: re-pumping the identical const widget would reuse
      // the built tree and never re-read the platform gate.
      await tester.pumpWidget(const SizedBox());
      debugDesktopPlatformOverride = false;
      await openWallet(tester);
      expect(find.text('Connect a hardware wallet (Trezor)'), findsNothing);
    });

    testWidgets(
        'ceremony with the sharing default configures a hardware wallet',
        (tester) async {
      fake.trezorError = null; // a device answers
      await openWallet(tester);
      await tester.tap(find.text('Connect a hardware wallet (Trezor)'));
      await tester.pumpAndSettle();
      // The share-read-keys choice defaults ON (phase-4 policy).
      final checkbox = tester
          .widget<CheckboxListTile>(find.byType(CheckboxListTile));
      expect(checkbox.value, isTrue);
      expect(find.textContaining('sign its backup-identity message twice'),
          findsOneWidget);
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();

      expect(fake.requests, contains('POST /wallet/trezor'));
      expect(find.text('Hardware wallet connected'), findsOneWidget);
      // Configured view: hardware copy, no file-fallback warning, the
      // device-specific remove subtitle — and no "keys not kept" line,
      // since sharing stayed on.
      expect(find.text(fake.trezorAddress), findsOneWidget);
      expect(find.textContaining('Hardware wallet (Trezor)'), findsOneWidget);
      expect(find.textContaining('No system keychain'), findsNothing);
      expect(find.textContaining('read keys are not kept'), findsNothing);
      await tester.scrollUntilVisible(
          find.textContaining('Disconnects the Trezor'), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.textContaining('Disconnects the Trezor'), findsOneWidget);
    });

    testWidgets('opting out of key sharing is honest in the configured view',
        (tester) async {
      fake.trezorError = null;
      await openWallet(tester);
      await tester.tap(find.text('Connect a hardware wallet (Trezor)'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      // The fake derives keys_held from the posted share_keys, so this
      // line proves share_keys=false went over the wire end to end.
      expect(find.textContaining('read keys are not kept'), findsOneWidget);
    });

    testWidgets('a missing device surfaces the error inside the dialog',
        (tester) async {
      // Default fake state: no device.
      await openWallet(tester);
      await tester.tap(find.text('Connect a hardware wallet (Trezor)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(find.textContaining('no Trezor found'), findsOneWidget);
      // Dialog stays open for a retry; Cancel leaves setup unchanged.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Create new wallet'), findsOneWidget);
    });

    testWidgets('the live presence poll flips the door to "Trezor detected"',
        (tester) async {
      await openWallet(tester);
      // No device yet: the generic helper line.
      expect(find.textContaining('never leaves the'), findsOneWidget);
      expect(find.text('Trezor detected — ready to set up.'), findsNothing);
      // Plug one in: the next 4-second poll notices.
      fake.trezorError = null;
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.text('Trezor detected — ready to set up.'), findsOneWidget);
      expect(find.textContaining('never leaves the'), findsNothing);
      // Unplugged again: the line reverts.
      fake.trezorError = 'no Trezor found — plug it in, unlock it, and try again';
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.text('Trezor detected — ready to set up.'), findsNothing);
    });

    testWidgets('a udev permission error offers the USB-permissions fix',
        (tester) async {
      fake.trezorError =
          'the Trezor was found but could not be opened (Access denied). '
          'On Linux this usually means the Trezor udev rules are not '
          'installed — install them (trezor.io → Learn → udev rules), '
          'replug the device, and try again.';
      await openWallet(tester);
      await tester.tap(find.text('Connect a hardware wallet (Trezor)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(find.textContaining('udev rules'), findsWidgets);
      final fix = find.text('Show me the fix (USB permissions)');
      expect(fix, findsOneWidget);
      await tester.ensureVisible(fix);
      await tester.pumpAndSettle();
      await tester.tap(fix);
      await tester.pumpAndSettle();
      // The helper dialog carries the one-liner install command.
      expect(find.text('Give W@tch access to the Trezor'), findsOneWidget);
      expect(find.textContaining('data.trezor.io'), findsWidgets);
      expect(find.text(kTrezorUdevCommand), findsOneWidget);
      // A plain no-device error does NOT offer the fix.
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      fake.trezorError = 'no Trezor found — plug it in, unlock it, and try again';
      await tester.tap(find.text('Connect a hardware wallet (Trezor)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(find.text('Show me the fix (USB permissions)'), findsNothing);
    });

    testWidgets(
        'the configured hardware view explains the on-device address check '
        'and the one-time allowance confirmation', (tester) async {
      fake.wallet = {
        'address': '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266',
        'storage': 'keychain',
        'kind': 'trezor',
        'keys_held': true,
      };
      await openWallet(tester);
      expect(find.textContaining('showed this address on its own screen'),
          findsOneWidget);
      expect(find.textContaining('one extra confirmation'), findsOneWidget);
      expect(find.textContaining('one-time spending allowance'),
          findsOneWidget);
    });

    testWidgets('removing a hardware wallet reads as a disconnect',
        (tester) async {
      fake.wallet = {
        'address': '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266',
        'storage': 'keychain',
        'kind': 'trezor',
        'keys_held': true,
      };
      await openWallet(tester);
      await tester.scrollUntilVisible(
          find.text('Remove wallet from this computer'), 200,
          scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('Remove wallet from this computer'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Nothing on the device itself changes'),
          findsOneWidget);
      await tester.tap(find.text('Remove wallet'));
      await tester.pumpAndSettle();
      expect(fake.requests, contains('DELETE /wallet'));
      expect(find.text('Create new wallet'), findsOneWidget);
    });
  });

  test('WalletStatus parses kind and keys_held', () {
    const hw = WalletStatus(
        configured: true, kind: 'trezor', keysHeld: false);
    expect(hw.isHardware, isTrue);
    const sw = WalletStatus(configured: true, kind: 'software');
    expect(sw.isHardware, isFalse);
    const old = WalletStatus(configured: true);
    expect(old.isHardware, isFalse);
  });
}
