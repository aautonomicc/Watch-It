import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:watchit/db/app_database.dart';
import 'package:watchit/main.dart';
import 'package:watchit/services/library_store.dart';
import 'package:watchit/theme/tokens.dart';

void main() {
  // Each test gets its own in-memory database, so the multiple-instance
  // race drift warns about cannot happen.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await LibraryStore.useForTesting(
        AppDatabase.forTesting(NativeDatabase.memory()));
  });

  testWidgets('home screen shows wordmark and empty state', (tester) async {
    await tester.pumpWidget(const WatchItApp());

    expect(find.text('[>] watch-it'), findsOneWidget);
    expect(find.text('Your library is empty'), findsOneWidget);
  });

  test('dark tokens match BRAND.md contract', () {
    expect(WiTokens.dark.ink.toARGB32(), 0xFF0A0A0A);
    expect(WiTokens.dark.copper.toARGB32(), 0xFFC9732B);
    expect(WiTokens.dark.bone.toARGB32(), 0xFFF5F2EB);
  });
}
