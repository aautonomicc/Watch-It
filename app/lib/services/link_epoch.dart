import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/my_watch_screen.dart';
import '../theme/tokens.dart';
import 'low_data_mode.dart';
import 'my_watch_api.dart';

/// The My W@tch link "epoch".
///
/// RELEASE STEP: bump this by one in a release whose x0x cannot sync
/// with the previous release's x0x (a breaking wire or storage change
/// with no fallback for old peers). On its first launch after the
/// update every device then removes its My W@tch link by itself and
/// tells the user to pair the devices again. Do NOT bump for x0x
/// releases that still talk to old peers — a bump makes every user
/// pair every device again.
///
/// `test/link_epoch_test.dart` fails when the x0x version in
/// `native/watchit_core/Cargo.toml` leaves [kLinkEpochReviewedX0x], so
/// the question is asked at every x0x minor bump.
const int kLinkEpoch = 1;

/// The x0x `major.minor` line [kLinkEpoch] was last reviewed against.
/// After bumping x0x: read its release notes, bump [kLinkEpoch] if old
/// and new cannot sync, then set this to the new line.
const String kLinkEpochReviewedX0x = '0.50';

/// Breaks a link made under an older [kLinkEpoch] and remembers that
/// the user still has to be told.
class LinkEpoch {
  static const _epochKey = 'mywatch_link_epoch_v1';
  static const _noticeKey = 'mywatch_relink_notice_v1';

  /// Call once at startup, before the sync loop starts. Returns whether
  /// a link was removed. Installs that predate the epoch count as
  /// epoch 1. Anything going wrong leaves the stored epoch alone, so
  /// the next launch tries again.
  static Future<bool> enforce({MyWatchApi? api, int epoch = kLinkEpoch}) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getInt(_epochKey) ?? 1;
    if (stored >= epoch) {
      if (prefs.getInt(_epochKey) == null) await prefs.setInt(_epochKey, epoch);
      return false;
    }
    var broke = false;
    try {
      final watch = api ?? MyWatchApi();
      final status = await watch.status();
      if (status.supported && status.linked) {
        await watch.unlink();
        // The mode is a property of being linked (see the unlink
        // button on the My W@tch screen).
        await LowDataMode.instance.clear();
        await prefs.setBool(_noticeKey, true);
        broke = true;
      }
    } catch (_) {
      return false;
    }
    await prefs.setInt(_epochKey, epoch);
    return broke;
  }

  /// Whether a link was removed and the user has not acknowledged it.
  static Future<bool> noticePending() async =>
      (await SharedPreferences.getInstance()).getBool(_noticeKey) ?? false;

  static Future<void> acknowledge() async =>
      (await SharedPreferences.getInstance()).remove(_noticeKey);
}

/// Shows the "pair your devices again" dialog when [LinkEpoch.enforce]
/// removed a link. It stays until answered and comes back on the next
/// launch if the app is closed first.
Future<void> offerRelinkNotice(BuildContext context) async {
  if (!await LinkEpoch.noticePending()) return;
  if (!context.mounted) return;
  final t = WiTokens.of(context);
  final open = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      backgroundColor: t.ink2,
      title: Text(
        'Pair your devices again',
        style: TextStyle(color: t.bone, fontSize: 16),
      ),
      content: Text(
        'This update changed how W@tch devices talk to each other, so '
        'the old My W@tch link no longer works and has been removed '
        'from this device.\n\n'
        'Update W@tch on all your devices, then pair them again in '
        'Settings → Network → My W@tch.\n\n'
        'Your library, watch points and profiles on this device are '
        'untouched.',
        style: TextStyle(color: t.boneDim, fontSize: 13),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text('Later', style: TextStyle(color: t.ash)),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text('Open My W@tch', style: TextStyle(color: t.accent)),
        ),
      ],
    ),
  );
  await LinkEpoch.acknowledge();
  if (open == true && context.mounted) {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const MyWatchScreen()),
    );
  }
}
