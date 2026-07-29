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

  testWidgets('wide layout bottom-aligns the info block with the artwork',
      (tester) async {
    await tester.pumpWidget(host(
      900,
      DetailHeader(
        poster: const SizedBox(
          key: Key('poster'),
          width: DetailHeader.posterWidth,
          height: DetailHeader.posterHeight,
        ),
        info: const SizedBox(key: Key('info'), height: 120),
      ),
    ));

    final row = tester.widget<Row>(find.ancestor(
      of: find.byKey(const Key('poster')),
      matching: find.byType(Row),
    ));
    expect(row.crossAxisAlignment, CrossAxisAlignment.end);

    final posterRect = tester.getRect(find.byKey(const Key('poster')));
    final infoRect = tester.getRect(find.byKey(const Key('info')));
    expect(infoRect.bottom, posterRect.bottom);
    expect(infoRect.top, greaterThan(posterRect.top));
  });

  testWidgets('narrow layout stacks poster above info', (tester) async {
    await tester.pumpWidget(host(
      400,
      DetailHeader(
        poster: const SizedBox(
          key: Key('poster'),
          width: DetailHeader.posterWidth,
          height: DetailHeader.posterHeight,
        ),
        info: const SizedBox(key: Key('info'), height: 120),
      ),
    ));

    final posterRect = tester.getRect(find.byKey(const Key('poster')));
    final infoRect = tester.getRect(find.byKey(const Key('info')));
    expect(infoRect.top, greaterThanOrEqualTo(posterRect.bottom));
  });
}
