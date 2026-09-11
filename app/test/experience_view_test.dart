import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/l10n/eco_corpus.dart';
import 'package:watchit/services/app_settings.dart';
import 'package:watchit/services/experience_view.dart';
import 'package:watchit/services/public_address_import.dart';
import 'package:watchit/services/list_import.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    wiExperienceView.value = ExperienceView.newBee;
  });

  tearDown(() {
    wiExperienceView.value = ExperienceView.newBee;
  });

  test('experience view defaults to New bee', () async {
    expect(await AppSettings.experienceView(), ExperienceView.newBee);
  });

  test('experience view round-trips every register', () async {
    for (final view in ExperienceView.values) {
      await AppSettings.setExperienceView(view);
      expect(await AppSettings.experienceView(), view);
    }
  });

  test('garbage stored value falls back to New bee', () async {
    SharedPreferences.setMockInitialValues({'experience_view_v1': 'maximalist'});
    expect(await AppSettings.experienceView(), ExperienceView.newBee);
  });

  test('New bee copy never numbers a step', () {
    final copy = ExperienceCopy(ExperienceView.newBee);
    expect(copy.receiveEmotion.contains('1.'), isFalse);
    expect(copy.receiveEmotion.toLowerCase().contains('step'), isFalse);
    expect(copy.keepVerb, 'Keep it');
    expect(copy.badgeLabel, 'Shared');
    expect(copy.fileDoorTechnical, isNull);
  });

  test('eco corpus covers 26 languages and Latvian Keep', () {
    expect(kEcoLanguageCodes, hasLength(26));
    expect(kEcoLocales, hasLength(26));
    expect(EcoCorpus.string('lv', 'keepVerb.newBee'), 'Paturi');
    expect(EcoCorpus.string('lv', 'receiveTitle.newBee'), 'Kāda darba gabals');
    final lv = ExperienceCopy(ExperienceView.newBee, locale: const Locale('lv'));
    expect(lv.keepVerb, 'Paturi');
    expect(lv.receiveTitle, 'Kāda darba gabals');
    expect(lv.rightsLine, contains('izplatīt'));
  });

  test('rights line is explicit in every register', () {
    expect(ExperienceCopy(ExperienceView.newBee).rightsLine,
        contains('give it away'));
    expect(ExperienceCopy(ExperienceView.raver).rightsLine,
        contains('not permission to redistribute'));
    expect(ExperienceCopy(ExperienceView.cypherpunk).rightsLine,
        contains('public address ≠ redistribute permission'));
  });

  test('estate connect copy points at the public atlas', () {
    expect(ExperienceCopy(ExperienceView.newBee).estateSnackAction, 'Estate');
    expect(ExperienceCopy(ExperienceView.raver).estateAtlasVerb,
        'skaists.dev/surfaces');
    expect(ExperienceCopy(ExperienceView.cypherpunk).estateTitle,
        'skaists.dev/surfaces');
    expect(ExperienceCopy(ExperienceView.cypherpunk).estateEmotion,
        contains('estate.json v1'));
  });

  test('Cypherpunk copy keeps Luna\'s engineering contract visible', () {
    final copy = ExperienceCopy(ExperienceView.cypherpunk);
    expect(copy.receiveEmotion, contains('read-only'));
    expect(copy.receiveEmotion, contains('re-uploaded'));
    expect(copy.fileDoorTechnical, contains('.datamap'));
    expect(copy.keepVerb, 'Save public reference');
  });

  test('humanPublicAddressError never dumps a stack', () {
    expect(
      humanPublicAddressError(const ListImportException(
          'Enter a public Autonomi address: 64 hexadecimal characters.')),
      contains('doesn’t look like an address yet'),
    );
    expect(
      humanPublicAddressError(const ListImportException(
          'That public address could not be resolved (404).')),
      contains('couldn’t find that piece'),
    );
    expect(
      humanPublicAddressError(Exception('SocketException: timed out')),
      contains('Try again'),
    );
    expect(humanPublicAddressError(Exception('boom')), contains('Try again'));
  });
}
