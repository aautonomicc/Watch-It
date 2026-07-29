import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:watchit/widgets/detail_header.dart';

void main() {
  Widget host(double width, Widget child) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(width: width, child: child),
          ),
        ),
      );

  const poster = SizedBox(
    key: Key('poster'),
    width: DetailHeader.posterWidth,
    height: DetailHeader.posterHeight,
  );

  testWidgets(
      'wide layout top-aligns the info block and puts actions below the '
      'artwork', (tester) async {
    await tester.pumpWidget(host(
      900,
      DetailHeader(
        poster: poster,
        info: const SizedBox(key: Key('info'), height: 120),
        actions: const SizedBox(key: Key('actions'), height: 40),
      ),
    ));

    final posterRect = tester.getRect(find.byKey(const Key('poster')));
    final infoRect = tester.getRect(find.byKey(const Key('info')));
    final actionsRect = tester.getRect(find.byKey(const Key('actions')));
    // Info sits beside the artwork, level with its top edge.
    expect(infoRect.top, posterRect.top);
    expect(infoRect.left, greaterThan(posterRect.right));
    // Actions sit under the artwork, matching its width.
    expect(actionsRect.top, greaterThan(posterRect.bottom));
    expect(actionsRect.left, posterRect.left);
    expect(actionsRect.width, DetailHeader.posterWidth);
  });

  testWidgets('narrow layout stacks poster, info, then actions',
      (tester) async {
    await tester.pumpWidget(host(
      400,
      DetailHeader(
        poster: poster,
        info: const SizedBox(key: Key('info'), height: 120),
        actions: const SizedBox(key: Key('actions'), height: 40),
      ),
    ));

    final posterRect = tester.getRect(find.byKey(const Key('poster')));
    final infoRect = tester.getRect(find.byKey(const Key('info')));
    final actionsRect = tester.getRect(find.byKey(const Key('actions')));
    expect(infoRect.top, greaterThanOrEqualTo(posterRect.bottom));
    expect(actionsRect.top, greaterThanOrEqualTo(infoRect.bottom));
  });

  testWidgets('wide layout without actions keeps the bare poster',
      (tester) async {
    await tester.pumpWidget(host(
      900,
      DetailHeader(
        poster: poster,
        info: const SizedBox(key: Key('info'), height: 120),
      ),
    ));

    final posterRect = tester.getRect(find.byKey(const Key('poster')));
    final infoRect = tester.getRect(find.byKey(const Key('info')));
    expect(infoRect.top, posterRect.top);
  });
}
