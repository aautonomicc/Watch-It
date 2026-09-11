import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/experience_view.dart';
import '../services/skaists_estate.dart';
import '../theme/tokens.dart';
import 'skaists_bloom.dart';

/// Opens a public atlas URL. Tests inject this so no real browser.
typedef EstateUrlLaunch = Future<bool> Function(Uri url);

EstateUrlLaunch estateUrlLaunch = (url) => launchUrl(url);

/// Soft post-Keep connect: the FULL skaists.dev/surfaces atlas,
/// grouped by family (beehive-nature / biomass / bnr…). Not a
/// shortlist — every LIVE card from estate.json is here. Opened
/// from the Keep snack, never stacked on the My Media header.
class EstateConnectSheet extends StatelessWidget {
  const EstateConnectSheet({super.key, required this.estate});

  final SkaistsEstate estate;

  static Future<void> show(BuildContext context) async {
    final estate = await SkaistsEstate.load();
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: WiTokens.of(context).ink2,
      showDragHandle: true,
      builder: (context) => EstateConnectSheet(estate: estate),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final copy = ExperienceCopy.of(context);
    final maxH = MediaQuery.sizeOf(context).height * 0.78;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const SkaistsBloom(
                    key: ValueKey('estate-connect-bloom'),
                    moment: SkaistsBloomMoment.still,
                    size: 36,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      copy.estateTitle,
                      style: TextStyle(
                        color: t.bone,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                copy.estateEmotion,
                style: TextStyle(color: t.boneDim, fontSize: 13, height: 1.35),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () =>
                      estateUrlLaunch(Uri.parse(kSkaistsAtlasUrl)),
                  icon: Icon(Icons.open_in_new, size: 16, color: t.accent),
                  label: Text(copy.estateAtlasVerb,
                      style: TextStyle(color: t.accent)),
                ),
              ),
              const SizedBox(height: 4),
              Expanded(
                child: ListView(
                  children: [
                    for (final family in estate.families)
                      _FamilyTile(
                        family: family,
                        cards: estate.ofFamily(family),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FamilyTile extends StatelessWidget {
  const _FamilyTile({required this.family, required this.cards});

  final String family;
  final List<SkaistsSurface> cards;

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    final name = SkaistsEstate.familyLabel(family);
    final org = cards.isEmpty ? '' : cards.first.org;
    return ExpansionTile(
      key: ValueKey('estate-family-$family'),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      title: Text(
        name,
        style: TextStyle(
          color: t.bone,
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
      ),
      subtitle: Text(
        org.isEmpty ? '${cards.length}' : '$org · ${cards.length}',
        style: TextStyle(color: t.ash, fontSize: 11.5),
      ),
      children: [
        for (final card in cards)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: 8, right: 0),
            title: Text(
              card.title,
              style: TextStyle(color: t.bone, fontSize: 13.5),
            ),
            subtitle: Text(
              card.gloss ?? card.path,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: t.ash, fontSize: 11.5, height: 1.3),
            ),
            trailing: Icon(Icons.open_in_new, color: t.ash, size: 16),
            onTap: () => estateUrlLaunch(card.publicUrl),
          ),
      ],
    );
  }
}
