import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchit/screens/wallet_screen.dart';
import 'package:watchit/services/publish_api.dart';
import 'package:watchit/theme/tokens.dart';

import 'fake_embedded_http.dart';

void main() {
  late FakeEmbeddedHttp fake;

  setUp(() {
    fake = FakeEmbeddedHttp();
    HttpOverrides.global = fake;
  });

  tearDown(() {
    HttpOverrides.global = null;
  });

  Future<void> openWallet(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: const WalletScreen(apiBase: FakeEmbeddedHttp.base),
    ));
    await tester.pumpAndSettle();
  }

  group('WalletScreen', () {
    testWidgets('unconfigured state offers create and import',
        (tester) async {
      await openWallet(tester);
      expect(find.text('Create new wallet'), findsOneWidget);
      expect(find.text('Import existing wallet'), findsOneWidget);
      expect(find.textContaining('hot wallet'), findsOneWidget);
    });

    testWidgets('configured state shows address, balances, and remove',
        (tester) async {
      fake.wallet = {'address': '0xAbC0000000000000000000000000000000000001', 'storage': 'keychain'};
      await openWallet(tester);
      expect(
          find.text('0xAbC0000000000000000000000000000000000001'),
          findsOneWidget);
      // 1500000000000000000 atto → 1.5 ANT; 20000000000000000 wei → 0.02 ETH.
      expect(find.text('1.5 ANT'), findsOneWidget);
      expect(find.text('0.02 ETH'), findsOneWidget);
      // Keychain storage → no file-fallback warning.
      expect(find.textContaining('No system keychain'), findsNothing);
      expect(find.text('Remove wallet from this computer'), findsOneWidget);
    });

    testWidgets('file storage backend is called out', (tester) async {
      fake.wallet = {'address': '0x1', 'storage': 'file'};
      await openWallet(tester);
      expect(find.textContaining('No system keychain'), findsOneWidget);
    });

    testWidgets('import dialog posts a private key and refreshes',
        (tester) async {
      await openWallet(tester);
      await tester.tap(find.text('Import existing wallet'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byType(TextField), 'ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80');
      await tester.tap(find.text('Import'));
      await tester.pumpAndSettle();
      expect(fake.requests, contains('POST /wallet'));
      // Screen reloaded into the configured state.
      expect(find.text('Remove wallet from this computer'), findsOneWidget);
      expect(find.text('Wallet imported'), findsOneWidget);
    });

    testWidgets('import dialog surfaces server rejection inline',
        (tester) async {
      await openWallet(tester);
      await tester.tap(find.text('Import existing wallet'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'nothex');
      await tester.tap(find.text('Import'));
      await tester.pumpAndSettle();
      expect(find.textContaining('not a valid private key'), findsOneWidget);
      // Dialog stays open; nothing configured.
      expect(fake.wallet, isNull);
    });

    testWidgets('remove wallet asks for confirmation then deletes',
        (tester) async {
      fake.wallet = {'address': '0x1', 'storage': 'keychain'};
      await openWallet(tester);
      await tester.tap(find.text('Remove wallet from this computer'));
      await tester.pumpAndSettle();
      expect(find.textContaining('seed words or private key'), findsOneWidget);
      await tester.tap(find.text('Remove wallet'));
      await tester.pumpAndSettle();
      expect(fake.requests, contains('DELETE /wallet'));
      expect(find.text('Create new wallet'), findsOneWidget);
    });
  });

  group('Seed backup ceremony', () {
    const words =
        'alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima';

    Future<void> openBackup(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: SeedBackupScreen(
          wallet: const GeneratedWallet(mnemonic: words, address: '0xFEED'),
          api: PublishApi(base: FakeEmbeddedHttp.base),
          confirmIndices: const [0, 4, 11],
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('shows all 12 numbered words and the warning',
        (tester) async {
      await openBackup(tester);
      expect(find.text('1. alpha'), findsOneWidget);
      expect(find.text('12. lima'), findsOneWidget);
      expect(find.textContaining('only backup'), findsOneWidget);
      expect(find.textContaining('cannot recover'), findsOneWidget);
    });

    testWidgets('wrong confirm word is rejected, correct words import',
        (tester) async {
      await openBackup(tester);
      await tester.tap(find.text("I've written them down"));
      await tester.pumpAndSettle();
      expect(find.text('Word #1'), findsOneWidget);
      expect(find.text('Word #5'), findsOneWidget);
      expect(find.text('Word #12'), findsOneWidget);

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'alpha');
      await tester.enterText(fields.at(1), 'WRONG');
      await tester.enterText(fields.at(2), 'lima');
      await tester.tap(find.text('Create wallet'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Word #5 does not match'), findsOneWidget);
      expect(fake.wallet, isNull);

      // Fix the word (case/space-insensitively) and finish.
      await tester.enterText(fields.at(1), ' Echo ');
      await tester.tap(find.text('Create wallet'));
      await tester.pumpAndSettle();
      expect(fake.requests, contains('POST /wallet'));
      expect(fake.wallet, isNotNull);
    });
  });

  group('formatUnits', () {
    test('whole, fractional, zero, and dust amounts', () {
      expect(formatUnits(BigInt.parse('1500000000000000000')), '1.5');
      expect(formatUnits(BigInt.parse('2000000000000000000')), '2');
      expect(formatUnits(BigInt.zero), '0');
      expect(formatUnits(BigInt.parse('250000000000000000')), '0.25');
      // Dust below the display precision is flagged, not shown as 0.
      expect(formatUnits(BigInt.parse('123')), '<0.000001');
      // Whole number with sub-precision dust: dust dropped.
      expect(formatUnits(BigInt.parse('3000000000000000123')), '3');
    });
  });
}
