import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchit/services/publish_api.dart';
import 'package:watchit/services/trezor_attention.dart';
import 'package:watchit/theme/tokens.dart';
import 'package:watchit/widgets/trezor_prompt.dart';

import 'fake_embedded_http.dart';

/// A hand-driven attention service for the host/dialog tests.
class _FakeAttention extends TrezorAttentionService {
  void emit(TrezorActivity? activity) {
    current = activity;
    notifyListeners();
  }
}

void main() {
  late FakeEmbeddedHttp fake;

  setUp(() {
    fake = FakeEmbeddedHttp();
    HttpOverrides.global = fake;
  });

  tearDown(() {
    HttpOverrides.global = null;
    TrezorChime.playOverride = null;
  });

  group('TrezorAttentionService', () {
    testWidgets('during() mirrors the beacon: new taps notify, clearing '
        'notifies, and the poller stops with the scope', (tester) async {
      final service = TrezorAttentionService(
        api: PublishApi(base: FakeEmbeddedHttp.base, token: 't'),
        pollInterval: const Duration(milliseconds: 100),
      );
      final seen = <String>[];
      service.addListener(
          () => seen.add(service.current?.action ?? '(cleared)'));
      final gate = Completer<void>();
      final scope = service.during(() => gate.future);
      await tester.pump(const Duration(milliseconds: 20));
      expect(service.current, isNull, reason: 'beacon starts quiet');

      fake.trezorActivityActive = true;
      fake.trezorActivitySeq = 1;
      fake.trezorActivityAction = 'sign-payment';
      await tester.pump(const Duration(milliseconds: 150));
      expect(service.current?.action, 'sign-payment');
      expect(service.current?.seq, 1);

      // A NEW tap (fresh seq) notifies again even with the same action.
      fake.trezorActivitySeq = 2;
      await tester.pump(const Duration(milliseconds: 150));
      expect(service.current?.seq, 2);

      fake.trezorActivityActive = false;
      await tester.pump(const Duration(milliseconds: 150));
      expect(service.current, isNull);
      expect(seen, ['sign-payment', 'sign-payment', '(cleared)']);

      gate.complete();
      await scope;
      await tester.pump(const Duration(milliseconds: 10));
      expect(service.armed, isFalse);
      // The test framework fails on pending timers — reaching the end
      // proves the woken poller left none behind.
    });

    testWidgets('a dead or old core reads as nothing waiting',
        (tester) async {
      // No base at all: every poll throws inside the service and is
      // swallowed — current stays null and the scope still completes.
      final service = TrezorAttentionService(
        api: PublishApi(base: 'http://127.0.0.1:1/', token: 't'),
        pollInterval: const Duration(milliseconds: 50),
      );
      final gate = Completer<void>();
      final scope = service.during(() => gate.future);
      await tester.pump(const Duration(milliseconds: 120));
      expect(service.current, isNull);
      gate.complete();
      await scope;
      await tester.pump(const Duration(milliseconds: 10));
    });
  });

  group('TrezorPromptHost', () {
    Future<_FakeAttention> mountHost(WidgetTester tester) async {
      final service = _FakeAttention();
      await tester.pumpWidget(MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: TrezorPromptHost(
          service: service,
          child: const Scaffold(body: Text('home')),
        ),
      ));
      return service;
    }

    testWidgets('a payment tap chimes and pops the explanation, which '
        'dismisses itself when the device stops waiting', (tester) async {
      var chimes = 0;
      TrezorChime.playOverride = () async => chimes++;
      final service = await mountHost(tester);

      service.emit(
          const TrezorActivity(active: true, seq: 1, action: 'sign-payment'));
      await tester.pumpAndSettle();
      expect(find.text('Confirm the payment on your Trezor'), findsOneWidget);
      expect(find.textContaining('one-time'), findsOneWidget,
          reason: 'the double-tap allowance note is part of the copy');
      expect(chimes, 1);

      service.emit(null);
      await tester.pumpAndSettle();
      expect(find.text('Confirm the payment on your Trezor'), findsNothing);
      expect(find.text('home'), findsOneWidget);
    });

    testWidgets('the open popup follows the action live instead of '
        'stacking a second dialog', (tester) async {
      var chimes = 0;
      TrezorChime.playOverride = () async => chimes++;
      final service = await mountHost(tester);

      service.emit(
          const TrezorActivity(active: true, seq: 1, action: 'sign-identity'));
      await tester.pumpAndSettle();
      expect(find.text('Check your Trezor'), findsOneWidget);
      expect(find.textContaining('backup-identity'), findsOneWidget);

      service.emit(const TrezorActivity(
          active: true, seq: 2, action: 'confirm-address'));
      await tester.pumpAndSettle();
      expect(find.text('Check the address on your Trezor'), findsOneWidget);
      expect(find.text('Check your Trezor'), findsNothing);
      expect(find.byType(TrezorPromptCard), findsOneWidget);
      expect(chimes, 2, reason: 'every new tap chimes');

      service.emit(null);
      await tester.pumpAndSettle();
      expect(find.byType(TrezorPromptCard), findsNothing);
    });

    testWidgets('Hide silences only that tap — the next one announces '
        'again', (tester) async {
      var chimes = 0;
      TrezorChime.playOverride = () async => chimes++;
      final service = await mountHost(tester);

      service.emit(
          const TrezorActivity(active: true, seq: 1, action: 'sign-payment'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hide'));
      await tester.pumpAndSettle();
      expect(find.byType(TrezorPromptCard), findsNothing);

      // The same tap re-reported never re-opens…
      service.emit(
          const TrezorActivity(active: true, seq: 1, action: 'sign-payment'));
      await tester.pumpAndSettle();
      expect(find.byType(TrezorPromptCard), findsNothing);
      expect(chimes, 1);

      // …but a fresh tap does.
      service.emit(
          const TrezorActivity(active: true, seq: 2, action: 'sign-payment'));
      await tester.pumpAndSettle();
      expect(find.byType(TrezorPromptCard), findsOneWidget);
      expect(chimes, 2);

      service.emit(null);
      await tester.pumpAndSettle();
    });

    testWidgets('a dialog that closes while the prompt is up REALLY '
        'closes — the prompt never absorbs another dialog\'s pop '
        '(the stranded-Trezor-setup-dialog regression)', (tester) async {
      TrezorChime.playOverride = () async {};
      // A tall window: the bottom-anchored prompt card must not overlap
      // the centered dialog's Done button for the tap below to land.
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final service = _FakeAttention();
      bool? dialogResult;
      await tester.pumpWidget(MaterialApp(
        theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
        home: TrezorPromptHost(
          service: service,
          child: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  dialogResult = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('setup dialog'),
                      actions: [
                        TextButton(
                          // The exact shape of the Trezor setup dialog's
                          // success path: pop the moment the core call
                          // returns, while the prompt is still showing.
                          onPressed: () => Navigator.of(context).pop(true),
                          child: const Text('Done'),
                        ),
                      ],
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('setup dialog'), findsOneWidget);

      // The ceremony's last tap is pending: the prompt card shows.
      service.emit(const TrezorActivity(
          active: true, seq: 1, action: 'confirm-address'));
      await tester.pumpAndSettle();
      expect(find.byType(TrezorPromptCard), findsOneWidget);

      // The dialog's own pop must close the DIALOG and deliver its
      // result, with the prompt still up (the old dialog-route prompt
      // swallowed this pop and stranded the setup dialog).
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(dialogResult, isTrue);
      expect(find.text('setup dialog'), findsNothing);
      expect(find.byType(TrezorPromptCard), findsOneWidget);

      service.emit(null);
      await tester.pumpAndSettle();
      expect(find.byType(TrezorPromptCard), findsNothing);
    });
  });

  test('every beacon action has its own explanation', () {
    expect(trezorPromptBody('sign-identity'), contains('costs '));
    expect(trezorPromptBody('confirm-address'), contains('matches'));
    expect(trezorPromptBody('sign-payment'), contains('amount'));
    expect(trezorPromptBody('something-new'), contains('confirmation'));
    expect(trezorPromptTitle('sign-payment'),
        'Confirm the payment on your Trezor');
    expect(trezorPromptTitle('confirm-address'),
        'Check the address on your Trezor');
    expect(trezorPromptTitle('sign-identity'), 'Check your Trezor');
  });
}
