import 'package:flutter/material.dart';

import '../services/profiles.dart';
import '../theme/tokens.dart';
import '../widgets/brand_mark.dart';
import '../widgets/pin_dialog.dart';
import '../widgets/profile_avatar.dart';

/// Switch profile: leaving a KID profile requires the admin PIN when
/// one is set (the agreed guard — a kid can't hop to an unprotected
/// adult profile). Pops back to the root first so the picker (which
/// replaces the gated home) isn't buried under pushed routes.
Future<void> switchProfileFlow(BuildContext context) async {
  final store = ProfileStore.instance;
  if (store.isKid && store.adminHasPin) {
    final ok = await verifyAdminPin(
      context,
      title: 'Admin PIN to switch profile',
    );
    if (!ok) return;
  }
  if (context.mounted) {
    Navigator.of(context).popUntil((r) => r.isFirst);
  }
  store.signOut();
}

/// "Who's watching?" — shown by the ProfileGate whenever nobody is
/// signed in (multi-profile launch without an auto-login profile, or
/// after Switch profile). Tapping a profile verifies its PIN (if any)
/// and signs it in.
class ProfilePickerScreen extends StatelessWidget {
  const ProfilePickerScreen({super.key});

  Future<void> _pick(BuildContext context, Profile profile) async {
    if (profile.hasPin) {
      final ok = await verifyPinDialog(context, profile);
      if (!ok) return;
    }
    await ProfileStore.instance.selectProfile(profile.id);
  }

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return Scaffold(
      backgroundColor: t.ink,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: ProfileStore.instance,
          builder: (context, _) {
            final profiles = ProfileStore.instance.profiles;
            return Center(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const BrandMark(height: 28),
                    const SizedBox(height: 24),
                    Text(
                      'Who\'s watching?',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: t.bone,
                      ),
                    ),
                    const SizedBox(height: 32),
                    Wrap(
                      spacing: 28,
                      runSpacing: 28,
                      alignment: WrapAlignment.center,
                      children: [
                        for (final p in profiles)
                          _ProfileTile(
                            profile: p,
                            onTap: () => _pick(context, p),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ProfileTile extends StatelessWidget {
  const _ProfileTile({required this.profile, required this.onTap});

  final Profile profile;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ProfileAvatar(name: profile.name, avatar: profile.avatar, size: 84),
            const SizedBox(height: 10),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (profile.hasPin) ...[
                  Icon(Icons.lock_outline, size: 13, color: t.ash),
                  const SizedBox(width: 4),
                ],
                Text(
                  profile.name,
                  style: TextStyle(fontSize: 14, color: t.boneDim),
                ),
              ],
            ),
            if (profile.isKid)
              Text('Kids', style: TextStyle(fontSize: 11, color: t.ash)),
          ],
        ),
      ),
    );
  }
}
