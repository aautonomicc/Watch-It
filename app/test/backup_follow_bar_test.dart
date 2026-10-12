import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:watchit/services/backup_follow.dart';
import 'package:watchit/theme/tokens.dart';
import 'package:watchit/widgets/backup_follow_bar.dart';

Widget _app() => MaterialApp(
      theme: wiTheme(WiTokens.dark, brightness: Brightness.dark),
      home: const Scaffold(body: Column(children: [BackupFollowBar()])),
    );

void main() {
  setUp(() {
    BackupFollowService.status.value = const BackupFollowStatus();
  });

  testWidgets('hidden while no fetch runs, narrates a first-time recovery '
      'with x-of-N and a progress bar, live-updates, and clears',
      (tester) async {
    await tester.pumpWidget(_app());
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('backup'), findsNothing);

    // First-time follow: the whole library arriving — announced as a
    // recovery, with the job's x-of-N.
    BackupFollowService.status.value = const BackupFollowStatus(
      following: true,
      fetching: true,
      firstTime: true,
      done: 3,
      total: 12,
    );
    await tester.pump();
    expect(find.text('Recovering your library from the backup — 3 of 12'),
        findsOneWidget);
    final bar = tester
        .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
    expect(bar.value, closeTo(3 / 12, 0.001));

    // Progress moves in place.
    BackupFollowService.status.value = const BackupFollowStatus(
      following: true,
      fetching: true,
      firstTime: true,
      done: 11,
      total: 12,
    );
    await tester.pump();
    expect(find.text('Recovering your library from the backup — 11 of 12'),
        findsOneWidget);

    // Fetch over → the bar disappears entirely.
    BackupFollowService.status.value =
        const BackupFollowStatus(following: true);
    await tester.pump();
    expect(find.textContaining('backup'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('a routine catch-up reads as such, with no x-of-N before '
      'the job reports totals', (tester) async {
    BackupFollowService.status.value = const BackupFollowStatus(
      following: true,
      fetching: true,
    );
    await tester.pumpWidget(_app());
    expect(find.text('Catching up from the backup…'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });
}
