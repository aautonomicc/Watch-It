import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watchit/services/skaists_estate.dart';

void main() {
  late SkaistsEstate estate;

  setUp(() {
    SkaistsEstate.resetCache();
    estate = SkaistsEstate.parse(
      File('assets/skaists_estate.json').readAsStringSync(),
    );
  });

  test('committed atlas is estate.json v1 — 8 families, full LIVE list', () {
    expect(estate.generated, '2026-08-28');
    expect(estate.families, SkaistsEstate.familyOrder);
    expect(estate.families, hasLength(8));
    expect(estate.surfaces, hasLength(102));
    expect(estate.surfaces.every((s) => s.isLive), isTrue);
    expect(
      estate.surfaces.every((s) => s.path.startsWith('surfaces/')),
      isTrue,
    );
  });

  test('family labels match the atlas sidebar, not a rename', () {
    expect(SkaistsEstate.familyLabel('beehivenature'), 'beehive-nature');
    expect(SkaistsEstate.familyLabel('beehivebiomass'), 'beehive-biomass');
    expect(SkaistsEstate.familyLabel('beehivebuds'), 'beehive-buds');
    expect(SkaistsEstate.familyLabel('bnr'), 'bnr');
    expect(estate.ofFamily('beehivenature'), hasLength(40));
    expect(estate.ofFamily('beehivebiomass'), hasLength(5));
    expect(estate.ofFamily('bnr'), hasLength(1));
    expect(estate.ofFamily('beehivebuds'), isEmpty);
    expect(estate.ofFamily('skaists'), hasLength(20));
    expect(estate.ofFamily('bnature'), hasLength(26));
    expect(estate.ofFamily('plur'), hasLength(5));
    expect(estate.ofFamily('midi'), hasLength(5));
    expect(
      estate.families.fold<int>(0, (n, f) => n + estate.ofFamily(f).length),
      102,
    );
  });

  test('real atlas cards keep their documented public URLs', () {
    SkaistsSurface card(String id) =>
        estate.surfaces.firstWhere((s) => s.id == id);

    expect(card('bfood').publicUrl.toString(),
        'https://skaists.dev/surfaces/bfood.html');
    expect(card('bfood').title, 'bFood');
    expect(card('bearth').publicUrl.toString(),
        'https://skaists.dev/surfaces/bearth.html');
    expect(card('bearth').title, 'bEarth');
    expect(card('ant-door').publicUrl.toString(),
        'https://skaists.dev/surfaces/ant-door.html');
    expect(card('ant-door').title, 'Autonomi door');
    expect(card('buzz-directory').publicUrl.toString(),
        'https://skaists.dev/surfaces/buzz-directory.html');
    expect(card('buzz-directory').title, 'buzz-directory');
    expect(card('blight-gallery').label, 'ERC20i gallery');
    expect(card('blight-gallery').publicUrl.toString(),
        'https://skaists.dev/surfaces/blight/gallery.html');
    expect(card('blight-studio-music').family, 'skaists');
    expect(card('blight-studio-music').publicUrl.toString(),
        'https://skaists.dev/surfaces/blight/studio-music.html');
    expect(card('blight-studio-music').title, 'Music studio');
    expect(card('bsymposium').family, 'bnature');
    expect(card('bsymposium').publicUrl.toString(),
        'https://skaists.dev/surfaces/bsymposium.html');
    expect(card('biq').family, 'bnr');
    expect(card('biq').publicUrl.toString(),
        'https://skaists.dev/surfaces/biq.html');
    expect(card('doors-beehivenature').org, 'beehive-nature');
    expect(card('doors-beehivenature').publicUrl.toString(),
        'https://skaists.dev/surfaces/doors/beehivenature.html');
    expect(card('doors-beehivebiomass').org, 'beehive-biomass');
    expect(card('doors-beehivebiomass').publicUrl.toString(),
        'https://skaists.dev/surfaces/doors/beehivebiomass.html');
    expect(kSkaistsAtlasUrl, 'https://skaists.dev/surfaces/');
    expect(kSkaistsEstateJsonUrl, 'https://skaists.dev/estate.json');
  });
}
