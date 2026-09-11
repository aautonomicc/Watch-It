import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchit/services/experience_view.dart';
import 'package:watchit/services/skaists_estate.dart';
import 'package:watchit/theme/tokens.dart';
import 'package:watchit/widgets/estate_connect_sheet.dart';
import 'package:watchit/widgets/skaists_bloom.dart';

void main() {
  late SkaistsEstate estate;
  final launched = <Uri>[];

  setUp(() {
    wiExperienceView.value = ExperienceView.newBee;
    estate = SkaistsEstate.parse(
      File('assets/skaists_estate.json').readAsStringSync(),
    );
    launched.clear();
    estateUrlLaunch = (url) async {
      launched.add(url);
      return true;
    };
  });

  tearDown(() {
    estateUrlLaunch = (url) async => false;
    wiExperienceView.value = ExperienceView.newBee;
  });

  Widget host() {
    return MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: Scaffold(body: EstateConnectSheet(estate: estate)),
    );
  }

  testWidgets('sheet lists every atlas family, not a shortlist',
      (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();

    expect(find.text('Stay connected'), findsOneWidget);
    expect(find.text('See more'), findsOneWidget);
    expect(find.byKey(const ValueKey('estate-connect-bloom')), findsOneWidget);
    expect(
      find.byWidgetPredicate((w) =>
          w is SkaistsBloom && w.moment == SkaistsBloomMoment.still),
      findsOneWidget,
    );
    for (final family in SkaistsEstate.familyOrder) {
      expect(find.byKey(ValueKey('estate-family-$family')), findsOneWidget);
      expect(find.text(SkaistsEstate.familyLabel(family)), findsOneWidget);
    }
    expect(find.text('beehive-nature'), findsOneWidget);
    expect(find.text('beehive-biomass'), findsOneWidget);
    expect(find.text('bnr'), findsOneWidget);
  });

  testWidgets('See more hits the documented hub URL', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.tap(find.text('See more'));
    await tester.pump();
    expect(launched, [Uri.parse(kSkaistsAtlasUrl)]);
  });

  testWidgets('expanding a family shows real cards with public URLs',
      (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();

    await tester.tap(find.text('beehive-nature'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('ERC20i gallery'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('ERC20i gallery'), findsOneWidget);
    await tester.tap(find.text('ERC20i gallery'));
    await tester.pump();
    expect(
      launched,
      [Uri.parse('https://skaists.dev/surfaces/blight/gallery.html')],
    );

    launched.clear();
    await tester.ensureVisible(find.text('bnature'));
    await tester.tap(find.text('bnature'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('bsymposium'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('bsymposium'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('bFood'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('bFood'), findsOneWidget);
    await tester.tap(find.text('bFood'));
    await tester.pump();
    expect(launched, [Uri.parse('https://skaists.dev/surfaces/bfood.html')]);
  });

  Future<void> tapAtlasCard(WidgetTester tester, String title) async {
    await tester.scrollUntilVisible(
      find.text(title),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text(title));
    await tester.pump();
  }

  testWidgets('skaists family carries music, buzz and ant-door cards',
      (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.ensureVisible(find.text('skaists'));
    await tester.tap(find.text('skaists'));
    await tester.pumpAndSettle();

    await tapAtlasCard(tester, 'Music studio');
    expect(launched.last,
        Uri.parse('https://skaists.dev/surfaces/blight/studio-music.html'));

    await tapAtlasCard(tester, 'buzz-directory');
    expect(launched.last,
        Uri.parse('https://skaists.dev/surfaces/buzz-directory.html'));

    await tapAtlasCard(tester, 'Autonomi door');
    expect(launched.last,
        Uri.parse('https://skaists.dev/surfaces/ant-door.html'));
  });

  testWidgets('biomass and bnr families keep their documented doors',
      (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();

    await tester.ensureVisible(find.text('beehive-biomass'));
    await tester.tap(find.text('beehive-biomass'));
    await tester.pumpAndSettle();
    await tapAtlasCard(tester, 'doors-beehivebiomass');
    expect(
      launched.last,
      Uri.parse('https://skaists.dev/surfaces/doors/beehivebiomass.html'),
    );

    launched.clear();
    await tester.ensureVisible(find.text('bnr'));
    await tester.tap(find.text('bnr'));
    await tester.pumpAndSettle();
    await tapAtlasCard(tester, 'biq');
    expect(launched.last, Uri.parse('https://skaists.dev/surfaces/biq.html'));
  });
}
