import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchit/screens/wallet_screen.dart';
import 'package:watchit/theme/tokens.dart';

import 'fake_embedded_http.dart';

/// Passphrase protection of the fallback wallet file: the protect flow
/// on a file-stored software wallet, the locked state after a "restart",
/// and the unlock round trip.
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

  testWidgets('only file-stored software wallets offer the protect button',
      (tester) async {
    fake.wallet = {'address': '0x1', 'storage': 'file', 'kind': 'software'};
    await openWallet(tester);
    expect(find.text('Protect the wallet file with a passphrase'),
        findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    fake.wallet = {'address': '0x1', 'storage': 'keychain'};
    await openWallet(tester);
    expect(find.text('Protect the wallet file with a passphrase'),
        findsNothing);
  });

  testWidgets('protect dialog validates locally, posts, and flips the state',
      (tester) async {
    fake.wallet = {'address': '0x1', 'storage': 'file', 'kind': 'software'};
    await openWallet(tester);
    await tester.tap(find.text('Protect the wallet file with a passphrase'));
    await tester.pumpAndSettle();
    expect(find.textContaining('no way to recover'), findsOneWidget);

    final fields = find.byType(TextField);
    // Too short → refused locally, nothing posted.
    await tester.enterText(fields.at(0), 'short');
    await tester.enterText(fields.at(1), 'short');
    await tester.tap(find.text('Protect'));
    await tester.pumpAndSettle();
    expect(find.text('Use at least 8 characters.'), findsOneWidget);
    // Mismatch → refused locally.
    await tester.enterText(fields.at(0), 'open sesame now');
    await tester.enterText(fields.at(1), 'open sesame NOT');
    await tester.tap(find.text('Protect'));
    await tester.pumpAndSettle();
    expect(find.text('The two entries do not match.'), findsOneWidget);
    expect(fake.walletPassphrasePosts, isEmpty);
    // Matching entries post and the screen reloads protected.
    await tester.enterText(fields.at(1), 'open sesame now');
    await tester.tap(find.text('Protect'));
    await tester.pumpAndSettle();
    expect(fake.walletPassphrasePosts, hasLength(1));
    expect(jsonDecode(fake.walletPassphrasePosts.single),
        {'passphrase': 'open sesame now'});
    expect(find.text('Wallet file is now passphrase-protected'),
        findsOneWidget);
    expect(find.textContaining('encrypted with your passphrase'),
        findsOneWidget);
    expect(find.text('Remove passphrase protection'), findsOneWidget);
    expect(find.text('Protect the wallet file with a passphrase'),
        findsNothing);
  });

  testWidgets('a locked wallet unlocks with the right passphrase',
      (tester) async {
    fake.wallet = {
      'address': '0xAbC0000000000000000000000000000000000001',
      'storage': 'file',
      'kind': 'software',
    };
    fake.walletPassphrase = 'open sesame now';
    fake.walletLocked = true;
    await openWallet(tester);
    // Locked body: address + unlock field, no balances/danger zone.
    expect(find.text('This wallet is protected with a passphrase'),
        findsOneWidget);
    expect(find.text('0xAbC0000000000000000000000000000000000001'),
        findsOneWidget);
    expect(find.text('Unlock wallet'), findsOneWidget);
    expect(find.text('1.5 ANT'), findsNothing);

    // A wrong passphrase surfaces inline and stays locked.
    await tester.enterText(find.byType(TextField), 'nope nope nope');
    await tester.tap(find.text('Unlock wallet'));
    await tester.pumpAndSettle();
    expect(find.text('wrong passphrase'), findsOneWidget);
    expect(find.text('Unlock wallet'), findsOneWidget);

    // The right one unlocks into the full configured view.
    await tester.enterText(find.byType(TextField), 'open sesame now');
    await tester.tap(find.text('Unlock wallet'));
    await tester.pumpAndSettle();
    expect(find.text('Wallet unlocked'), findsOneWidget);
    expect(find.text('1.5 ANT'), findsOneWidget);
    await tester.scrollUntilVisible(
        find.text('Remove wallet from this computer'), 200,
          scrollable: find.byType(Scrollable).first);
    expect(find.text('Remove wallet from this computer'), findsOneWidget);
    expect(jsonDecode(fake.walletUnlockPosts.last),
        {'passphrase': 'open sesame now'});
  });

  testWidgets('removing protection asks first, then deletes', (tester) async {
    fake.wallet = {'address': '0x1', 'storage': 'file', 'kind': 'software'};
    fake.walletPassphrase = 'open sesame now';
    await openWallet(tester);
    await tester.tap(find.text('Remove passphrase protection'));
    await tester.pumpAndSettle();
    expect(find.text('Remove passphrase protection?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(fake.walletPassphrase, isNotNull);

    await tester.tap(find.text('Remove passphrase protection'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove protection'));
    await tester.pumpAndSettle();
    expect(fake.walletPassphrase, isNull);
    expect(find.text('Protect the wallet file with a passphrase'),
        findsOneWidget);
  });
}
