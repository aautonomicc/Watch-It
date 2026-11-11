import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/build_info.dart';
import '../theme/tokens.dart';

/// Home-screen bar shown ONLY on test builds published as prereleases:
/// names the build in full (prerelease name, the release it sits on,
/// commit, build time) so a tester — and a bug report — can say exactly
/// which build is running. Settings → About cannot: a test build keeps
/// the last release's version number. Tap copies the line. Renders
/// nothing on release and dev builds.
class PrereleaseBar extends StatelessWidget {
  const PrereleaseBar({super.key, this.info = BuildInfo.current});

  final BuildInfo info;

  @override
  Widget build(BuildContext context) {
    if (!info.isPrerelease) return const SizedBox.shrink();
    final t = WiTokens.of(context);
    final line = 'Pre-release test build · ${info.details}';
    return Material(
      color: WiTokens.warnAmber.withValues(alpha: 0.14),
      child: InkWell(
        onTap: () async {
          await Clipboard.setData(ClipboardData(text: line));
          if (!context.mounted) return;
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(content: Text('Build info copied')),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.science_outlined,
                  size: 16, color: WiTokens.warnAmber),
              const SizedBox(width: 10),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      const TextSpan(
                        text: 'Pre-release test build',
                        style: TextStyle(
                          color: WiTokens.warnAmber,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      TextSpan(text: ' · ${info.details}'),
                    ],
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: t.boneDim),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
