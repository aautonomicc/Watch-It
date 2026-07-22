import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Big-artwork header shared by the movie/episode detail, show, and
/// season pages: artwork at ~4x the home-tile area (240×360, vs the
/// wall's 120×180) with the info block beside it on wide layouts and
/// below it on phones.
class DetailHeader extends StatelessWidget {
  const DetailHeader({super.key, required this.poster, required this.info});

  static const double posterWidth = 240;
  static const double posterHeight = 360;

  final Widget poster;
  final Widget info;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxWidth >= 520) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            poster,
            const SizedBox(width: 20),
            Expanded(child: info),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(child: poster),
          const SizedBox(height: 16),
          info,
        ],
      );
    });
  }
}

/// The header's artwork slot: [image] clipped to the big poster size, or
/// a placeholder tile with [placeholder] when there is no artwork yet.
Widget headerArtwork(WiTokens t, Widget? image, IconData placeholder) {
  return ClipRRect(
    borderRadius: BorderRadius.circular(8),
    child: SizedBox(
      width: DetailHeader.posterWidth,
      height: DetailHeader.posterHeight,
      child: image ??
          Container(
            color: t.ink2,
            child: Icon(placeholder, color: t.ash, size: 96),
          ),
    ),
  );
}

/// `★ 8.9 / 10` community-score line (TMDB rating).
Widget ratingLine(WiTokens t, double rating) {
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(Icons.star_rounded, color: t.copper, size: 20),
      const SizedBox(width: 4),
      Text(
        rating.toStringAsFixed(1),
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          color: t.bone,
        ),
      ),
      Text(' / 10', style: TextStyle(fontSize: 12, color: t.ash)),
    ],
  );
}

/// Small all-caps section label (`SEASONS`, `EPISODES`, `XOR ADDRESS`).
Widget sectionLabel(WiTokens t, String text) {
  return Text(
    text,
    style: TextStyle(
      fontSize: 10,
      letterSpacing: 1.5,
      fontWeight: FontWeight.w700,
      color: t.ash,
    ),
  );
}
