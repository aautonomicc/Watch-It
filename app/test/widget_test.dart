import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/main.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/theme/tokens.dart';
import 'package:watchit/widgets/brand_mark.dart';

void main() {
  // Each test gets its own in-memory database, so the multiple-instance
  // race drift warns about cannot happen.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
  });

  testWidgets('home screen shows lockup and empty state', (tester) async {
    await tester.pumpWidget(const WatchItApp());

    expect(find.byType(BrandMark), findsOneWidget);
    expect(find.text('watch-it'), findsOneWidget);
    expect(find.text('Your library is empty'), findsOneWidget);
  });

  test('dark tokens match BRAND.md contract', () {
    expect(WiTokens.dark.ink.toARGB32(), 0xFF0A0A0A);
    expect(WiTokens.dark.accent.toARGB32(), 0xFF42A5F5);
    expect(WiTokens.dark.bone.toARGB32(), 0xFFF5F2EB);
    expect(WiTokens.bucketBlue.toARGB32(), 0xFF42A5F5);
  });
}
