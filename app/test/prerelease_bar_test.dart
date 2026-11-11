import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchit/services/build_info.dart';
import 'package:watchit/theme/tokens.dart';
import 'package:watchit/widgets/prerelease_bar.dart';

Widget _host(BuildInfo info) => MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: Scaffold(body: Column(children: [PrereleaseBar(info: info)])),
    );

void main() {
  test('a normal build is not a prerelease', () {
    expect(BuildInfo.current.isPrerelease, isFalse);
    expect(const BuildInfo().details, '');
  });

  test('details name the build in full, skipping what is unknown', () {
    const full = BuildInfo(
      prerelease: 'v0.1.0-alpha.130-test2',
      baseVersion: 'v0.1.0-alpha.129',
      commit: 'abc1234',
      built: '2026-11-11 14:02 UTC',
    );
    expect(
      full.details,
      'v0.1.0-alpha.130-test2 · on top of v0.1.0-alpha.129 · '
      'commit abc1234 · built 2026-11-11 14:02 UTC',
    );
    expect(const BuildInfo(prerelease: 'v9-test1').details, 'v9-test1');
  });

  testWidgets('release and dev builds show no bar', (tester) async {
    await tester.pumpWidget(_host(const BuildInfo()));
    expect(find.textContaining('Pre-release'), findsNothing);
    expect(tester.getSize(find.byType(PrereleaseBar)).height, 0);
  });

  testWidgets('a test build shows its full build info; tap copies it',
      (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    await tester.pumpWidget(_host(const BuildInfo(
      prerelease: 'v0.1.0-alpha.130-test2',
      baseVersion: 'v0.1.0-alpha.129',
      commit: 'abc1234',
      built: '2026-11-11 14:02 UTC',
    )));
    expect(
      find.textContaining('v0.1.0-alpha.130-test2', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('commit abc1234', findRichText: true),
        findsOneWidget);
    await tester.tap(find.byType(PrereleaseBar));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(copied, contains('Pre-release test build · v0.1.0-alpha.130-test2'));
    expect(copied, contains('built 2026-11-11 14:02 UTC'));
    expect(find.text('Build info copied'), findsOneWidget);
  });
}
