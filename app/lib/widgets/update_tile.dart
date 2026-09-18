import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/update_check.dart';
import '../services/update_install.dart';
import '../theme/tokens.dart';

/// Settings → About "Update available" row.
///
/// Hidden until [UpdateCheck] has seen a newer release. Where the app
/// can update itself — Android with an APK asset, Linux running from
/// an AppImage with an AppImage asset, or an installed Windows bundle
/// with a zip asset — tapping downloads and applies the update
/// (user-triggered only, never automatic); anywhere else it opens the
/// release page like before.
class UpdateAvailableTile extends StatelessWidget {
  const UpdateAvailableTile({super.key});

  bool get _selfUpdateApk =>
      Platform.isAndroid && UpdateCheck.instance.apkAsset != null;

  bool get _selfUpdateAppImage =>
      Platform.isLinux &&
      UpdateInstaller.runningAppImagePath != null &&
      UpdateCheck.instance.appImageAsset != null;

  bool get _selfUpdateWindows =>
      UpdateInstaller.onWindows &&
      UpdateInstaller.windowsInstallDir != null &&
      UpdateCheck.instance.windowsZipAsset != null;

  @override
  Widget build(BuildContext context) {
    final t = WiTokens.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge(
          [UpdateCheck.instance, UpdateInstaller.instance]),
      builder: (context, _) {
        final tag = UpdateCheck.instance.availableTag;
        if (tag == null) return const SizedBox.shrink();
        final installer = UpdateInstaller.instance;
        if (!_selfUpdateApk && !_selfUpdateAppImage && !_selfUpdateWindows) {
          // No self-update path here (macOS, dev runs, plain Linux
          // bundles): keep the open-the-release-page row.
          return _tile(
            t,
            subtitle: '$tag — open the release page to download',
            trailing: Icon(Icons.open_in_new, color: t.ash, size: 18),
            onTap: () => launchUrl(Uri.parse(
                UpdateCheck.instance.releaseUrl ?? UpdateCheck.releasePage)),
          );
        }
        switch (installer.stage) {
          case UpdateInstallStage.downloading:
            final pct = (installer.progress * 100).round();
            return _tile(
              t,
              subtitle: 'Downloading $tag · $pct%',
              extra: LinearProgressIndicator(
                value: installer.progress <= 0 ? null : installer.progress,
                color: t.accent,
                backgroundColor: t.ink2,
                minHeight: 3,
              ),
              trailing: IconButton(
                icon: Icon(Icons.close, color: t.ash, size: 18),
                tooltip: 'Cancel download',
                onPressed: installer.cancel,
              ),
            );
          case UpdateInstallStage.readyToInstall:
            return _tile(
              t,
              subtitle:
                  '$tag downloaded — tap to open the installer again',
              onTap: installer.launchApkInstaller,
            );
          case UpdateInstallStage.awaitingRestart:
            return _tile(
              t,
              subtitle:
                  '$tag installed — restart W@tch to finish the update',
            );
          case UpdateInstallStage.applying:
            return _tile(
              t,
              subtitle:
                  'Installing $tag — W@tch will close and reopen updated',
            );
          case UpdateInstallStage.idle:
          case UpdateInstallStage.failed:
            final action = _selfUpdateApk
                ? 'tap to download and install'
                : _selfUpdateWindows
                    ? 'tap to download — W@tch restarts to finish'
                    : 'tap to download and update in place';
            return _tile(
              t,
              subtitle: installer.stage == UpdateInstallStage.failed
                  ? '${installer.error ?? 'Update failed.'} '
                      'Tap to try again.'
                  : '$tag — $action',
              error: installer.stage == UpdateInstallStage.failed,
              onTap: () => _selfUpdateApk
                  ? installer
                      .downloadAndInstallApk(UpdateCheck.instance.apkAsset!)
                  : _selfUpdateWindows
                      ? installer.downloadAndRunWindowsUpdate(
                          UpdateCheck.instance.windowsZipAsset!)
                      : installer.downloadAndSwapAppImage(
                          UpdateCheck.instance.appImageAsset!),
            );
        }
      },
    );
  }

  Widget _tile(
    WiTokens t, {
    required String subtitle,
    Widget? extra,
    Widget? trailing,
    VoidCallback? onTap,
    bool error = false,
  }) =>
      ListTile(
        leading: Icon(Icons.system_update_alt, color: t.accent),
        title: Text(
          'Update available',
          style: TextStyle(color: t.accent, fontSize: 15),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              subtitle,
              style: TextStyle(
                  color: error ? t.rust : t.ash, fontSize: 12),
            ),
            if (extra != null) ...[
              const SizedBox(height: 6),
              extra,
            ],
          ],
        ),
        trailing: trailing,
        onTap: onTap,
      );
}
