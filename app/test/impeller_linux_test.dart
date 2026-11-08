import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchit/services/impeller.dart';
import 'package:watchit/widgets/brand_mark.dart';

// Linux renderer opt-out: the Settings toggle is a marker FILE the C runner
// checks at launch (impeller.off in the app data dir), not a preference.
void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('wi-impeller');
    ImpellerSettings.linuxMarkerDirOverride = () async => dir;
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    ImpellerSettings.linuxMarkerDirOverride = null;
    dir.deleteSync(recursive: true);
  });

  test('the toggle is a marker file in the app data dir on Linux', () async {
    expect(ImpellerSettings.supported, isTrue);
    expect(await ImpellerSettings.explicit(), isNull);
    expect(await ImpellerSettings.effectiveDisabled(), isFalse);

    await ImpellerSettings.setDisabled(true);
    final marker = File('${dir.path}/${ImpellerSettings.linuxMarkerName}');
    expect(marker.existsSync(), isTrue);
    expect(await ImpellerSettings.explicit(), isTrue);
    expect(await ImpellerSettings.effectiveDisabled(), isTrue);

    await ImpellerSettings.setDisabled(false);
    expect(marker.existsSync(), isFalse);
    expect(await ImpellerSettings.explicit(), isNull);
  });

  test('bucket feather is one device pixel', () {
    expect(bucketFeatherFor(1.0), 1.0);
    expect(bucketFeatherFor(2.0), 0.5);
    expect(bucketFeatherFor(0), 1.0);
  });
}
