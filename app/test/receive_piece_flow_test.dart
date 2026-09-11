import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/services/experience_view.dart';
import 'package:watchit/theme/tokens.dart';
import 'package:watchit/widgets/receive_piece_dialog.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    wiExperienceView.value = ExperienceView.newBee;
  });

  tearDown(() {
    wiExperienceView.value = ExperienceView.newBee;
  });

  Widget host({String? base}) {
    return MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: Scaffold(
        body: ReceivePieceDialog(base: base),
      ),
    );
  }

  testWidgets('New bee Keep flow is emotion / choose, never numbered steps',
      (tester) async {
    await tester.pumpWidget(host(base: 'http://127.0.0.1:1'));
    await tester.pump();

    expect(find.text('A piece of someone’s work'), findsOneWidget);
    expect(
        find.text('They made something. They gave you a way to keep it.'),
        findsOneWidget);
    expect(find.text('Look it up'), findsOneWidget);
    expect(find.text('The address they sent you'), findsOneWidget);
    expect(find.textContaining('1.'), findsNothing);
    expect(find.textContaining('Step 1'), findsNothing);
    expect(find.text('Add public Autonomi address'), findsNothing);
    expect(find.textContaining('64-character public XOR'), findsNothing);
  });

  testWidgets('New bee errors are human and recoverable', (tester) async {
    await tester.pumpWidget(host(base: 'http://127.0.0.1:1'));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'not-an-address');
    await tester.tap(find.text('Look it up'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
        find.textContaining('doesn’t look like an address yet'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Paste a different address'), findsOneWidget);
    expect(find.textContaining('Exception'), findsNothing);
    expect(find.textContaining('64 hexadecimal'), findsNothing);
  });

  testWidgets('verified piece offers Keep it, not a devops Add', (tester) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      expect(request.method, 'HEAD');
      request.response.headers.contentLength = 4096;
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));

    await tester.pumpWidget(host(base: 'http://127.0.0.1:${server.port}'));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'ab' * 32);
    await tester.tap(find.text('Look it up'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    expect(find.textContaining('This piece is real'), findsOneWidget);
    expect(find.text('Keep it'), findsOneWidget);
    expect(find.text('Not this one'), findsWidgets);
    expect(find.text('Add to library'), findsNothing);
    expect(find.text('Name this piece'), findsOneWidget);
  });

  testWidgets('Keep pops the verified address and name', (tester) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentLength = 2048;
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));

    ReceivedPiece? kept;
    await tester.pumpWidget(MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: Builder(builder: (context) {
        return Scaffold(
          body: TextButton(
            onPressed: () async {
              kept = await showReceivePieceFlow(
                context,
                base: 'http://127.0.0.1:${server.port}',
              );
            },
            child: const Text('open'),
          ),
        );
      }),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'cd' * 32);
    await tester.tap(find.text('Look it up'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    final nameField = find.byType(TextField).last;
    await tester.enterText(nameField, 'Peak Bloom');
    await tester.tap(find.text('Keep it'));
    await tester.pumpAndSettle();

    expect(kept?.address, 'cd' * 32);
    expect(kept?.name, 'Peak Bloom');
    expect(kept?.size, 2048);
  });

  testWidgets('Cypherpunk register shows the technical door, same Keep',
      (tester) async {
    await tester.pumpWidget(host(base: 'http://127.0.0.1:1'));
    await tester.pump();

    await tester.tap(find.text('Cypherpunk'));
    await tester.pumpAndSettle();

    expect(find.text('Public XOR import'), findsOneWidget);
    expect(find.textContaining('HEAD /public/{address}'), findsOneWidget);
    expect(find.text('HEAD /public'), findsOneWidget);
    expect(find.text('Look it up'), findsNothing);
  });
}
