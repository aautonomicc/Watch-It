import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/services/app_settings.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('AppSettings buffer size', () {
    test('defaults to 32 MB when unset', () async {
      expect(await AppSettings.bufferSizeMb(), 32);
    });

    test('set and read back a chosen size', () async {
      await AppSettings.setBufferSizeMb(128);
      expect(await AppSettings.bufferSizeMb(), 128);
    });

    test('unknown stored value falls back to the default', () async {
      SharedPreferences.setMockInitialValues({'buffer_size_mb_v1': 999});
      expect(await AppSettings.bufferSizeMb(),
          AppSettings.defaultBufferSizeMb);
    });

    test('all offered options are valid to store and read', () async {
      for (final mb in AppSettings.bufferSizeOptionsMb) {
        await AppSettings.setBufferSizeMb(mb);
        expect(await AppSettings.bufferSizeMb(), mb);
      }
    });
  });

  group('AppSettings TMDB key source', () {
    // Tests run without --dart-define, so the bundled key is empty and
    // TmdbKeySource.bundled cannot occur here.
    test('none when nothing is set', () async {
      expect(await AppSettings.tmdbKeySource(), TmdbKeySource.none);
    });

    test('user once a key is stored, none again after clearing', () async {
      await AppSettings.setTmdbApiKey('my-key');
      expect(await AppSettings.tmdbKeySource(), TmdbKeySource.user);
      expect(await AppSettings.tmdbApiKey(), 'my-key');

      await AppSettings.setTmdbApiKey('');
      expect(await AppSettings.tmdbKeySource(), TmdbKeySource.none);
    });
  });
}
