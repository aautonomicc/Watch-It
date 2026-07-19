import 'package:flutter_test/flutter_test.dart';

import 'package:watchit/main.dart';
import 'package:watchit/theme/tokens.dart';

void main() {
  testWidgets('home screen shows wordmark and empty state', (tester) async {
    await tester.pumpWidget(const WatchItApp());

    expect(find.text('watch-it'), findsOneWidget);
    expect(find.text('Your library is empty'), findsOneWidget);
  });

  test('dark tokens match BRAND.md contract', () {
    expect(WiTokens.dark.ink.toARGB32(), 0xFF0A0A0A);
    expect(WiTokens.dark.copper.toARGB32(), 0xFFC9732B);
    expect(WiTokens.dark.bone.toARGB32(), 0xFFF5F2EB);
  });
}
