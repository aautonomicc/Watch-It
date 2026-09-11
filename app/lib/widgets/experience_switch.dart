import 'package:flutter/material.dart';

import '../services/app_settings.dart';
import '../services/experience_view.dart';
import '../theme/tokens.dart';

/// Compact three-register chrome. Lives next to choices, never over
/// primary media controls. Same access in every view.
class ExperienceSwitch extends StatelessWidget {
  const ExperienceSwitch({super.key, this.compact = false});

  /// Tighter padding for dialog headers and TV top bars.
  final bool compact;

  Future<void> _select(ExperienceView view) async {
    if (wiExperienceView.value == view) return;
    wiExperienceView.value = view;
    await AppSettings.setExperienceView(view);
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return ValueListenableBuilder<ExperienceView>(
      valueListenable: wiExperienceView,
      builder: (context, current, _) {
        return SegmentedButton<ExperienceView>(
          showSelectedIcon: false,
          style: ButtonStyle(
            visualDensity: compact
                ? const VisualDensity(horizontal: -2, vertical: -2)
                : VisualDensity.standard,
            tapTargetSize: compact
                ? MaterialTapTargetSize.shrinkWrap
                : MaterialTapTargetSize.padded,
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.selected)) {
                return t.accent.withValues(alpha: 0.18);
              }
              return t.ink2;
            }),
            foregroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.selected)) return t.accent;
              return t.ash;
            }),
            side: WidgetStatePropertyAll(BorderSide(color: t.line)),
          ),
          segments: [
            for (final view in ExperienceView.values)
              ButtonSegment(
                value: view,
                label: Text(
                  view.label,
                  style: TextStyle(
                    fontSize: compact ? 11 : 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                tooltip: view.hint,
              ),
          ],
          selected: {current},
          onSelectionChanged: (next) {
            if (next.isEmpty) return;
            _select(next.single);
          },
        );
      },
    );
  }
}
