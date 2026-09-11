import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
