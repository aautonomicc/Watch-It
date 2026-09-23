import 'package:flutter/material.dart';

import '../services/seek_preview.dart';
import '../theme/tokens.dart';

/// Thumbnail width; height follows the frame's own aspect (≤90 for 16:9).
const double kSeekPreviewWidth = 160;

/// The hover preview above the desktop seek bar: the frame under the
/// pointer (when [SeekPreview] has it — a timestamp-only pill until then,
/// so streamless moments never flash placeholder boxes) over a timestamp.
/// Rendered by the vendored fork's `seekBarHoverPreviewBuilder`.
class SeekPreviewCard extends StatelessWidget {
  const SeekPreviewCard({
    super.key,
    required this.preview,
    required this.position,
  });

  /// Null when previews are off for this source (streamed) — timestamp only.
  final SeekPreview? preview;
  final Duration position;

  static String clock(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$m:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final stamp = Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xCC000000),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        clock(position),
        style: TextStyle(
          fontSize: 11.5,
          color: t.bone,
          fontFamily: wiMonoFamily,
          fontFamilyFallback: wiMonoFallback,
        ),
      ),
    );
    final source = preview;
    if (source == null) {
      return Column(mainAxisSize: MainAxisSize.min, children: [stamp]);
    }
    return ListenableBuilder(
      listenable: source,
      builder: (context, _) {
        final bytes = source.frameFor(position);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (bytes != null)
              Container(
                width: kSeekPreviewWidth,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: const Color(0xFF000000),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0x66FFFFFF)),
                ),
                // gaplessPlayback keeps the previous frame while a
                // neighbouring bucket decodes — no flicker on sweeps.
                child: Image.memory(
                  bytes,
                  width: kSeekPreviewWidth,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                ),
              ),
            stamp,
          ],
        );
      },
    );
  }
}
