import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/tokens.dart';

/// Autonomi's home page — where the credit links.
const kAutonomiHomeUrl = 'https://autonomi.com/';

/// The Autonomi wordmark asset (`assets/autonomi_logo.png` + 2x/3x
/// variants): the official mark from autonomi.com with the wordmark text
/// recoloured to bone so it reads on the app's ink chrome (the red mark is
/// untouched). Source SVG kept at `branding/autonomi-wordmark-bone.svg`.
/// Rendered at its native 160:25 aspect.
const kAutonomiLogoAsset = 'assets/autonomi_logo.png';

/// Opens [kAutonomiHomeUrl] in the system browser. Replaceable for tests —
/// url_launcher has no in-process fake.
@visibleForTesting
Future<bool> Function(Uri uri) autonomiLinkLauncher = (uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// Opens the Autonomi home page, telling the user the address when the
/// platform has no browser to hand it to (a TV box, typically).
Future<void> openAutonomiHome(BuildContext context) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  var ok = false;
  try {
    ok = await autonomiLinkLauncher(Uri.parse(kAutonomiHomeUrl));
  } catch (_) {
    ok = false;
  }
  if (!ok) {
    messenger?.showSnackBar(
      const SnackBar(content: Text('Visit $kAutonomiHomeUrl in a browser')),
    );
  }
}

/// The Autonomi wordmark at a given [height].
class AutonomiLogo extends StatelessWidget {
  const AutonomiLogo({super.key, this.height = 20});

  final double height;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      kAutonomiLogoAsset,
      height: height,
      width: height * 160 / 25,
      fit: BoxFit.contain,
      semanticLabel: 'Autonomi logo',
    );
  }
}

/// The "Powered by the Autonomi network" credit.
///
/// Two shapes share one tap target (the Autonomi home page):
/// - [AutonomiCredit.tile] — the Settings → About row, styled like the
///   W@tch identity row above it: accent network icon, the wordmark as the
///   title, the "Powered by…" explanation below.
/// - [AutonomiCredit.compact] — the library drawer's footer: a single
///   "Powered by" + logo line, visible on every home screen (always on
///   desktop, where the drawer is pinned).
class AutonomiCredit extends StatelessWidget {
  const AutonomiCredit.tile({super.key}) : compact = false;
  const AutonomiCredit.compact({super.key}) : compact = true;

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    if (compact) {
      return InkWell(
        onTap: () => openAutonomiHome(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Row(
            children: [
              Text(
                'Powered by',
                style: TextStyle(color: t.ash, fontSize: 12),
              ),
              const SizedBox(width: 8),
              const AutonomiLogo(height: 16),
            ],
          ),
        ),
      );
    }
    // Mirrors the W@tch identity row directly above it in Settings → About:
    // an accent-blue icon on the left, the brand mark as the title, and the
    // description below (2026-10-17, user ask). The whole row is the link.
    return ListTile(
      leading: Icon(Icons.hub_outlined, color: t.accent),
      title: const Align(
        alignment: Alignment.centerLeft,
        child: AutonomiLogo(height: 16),
      ),
      subtitle: Text(
        'Powered by the Autonomi network. Your media is stored on and '
        'streamed from Autonomi\'s decentralised network — tap to visit '
        'autonomi.com.',
        style: TextStyle(color: t.ash, fontSize: 12),
      ),
      onTap: () => openAutonomiHome(context),
    );
  }
}
