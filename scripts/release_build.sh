#!/usr/bin/env bash
# Release build (APK + AppImage) for the version currently
# in app/pubspec.yaml. Keyless by design since alpha.34: no TMDB key is
# bundled — users bring their own via Settings → Metadata (the repo-root
# .env stays for dev runs and live tests only).
# Runs under systemd --user so the build survives the
# session that launched it (detached builds died with their session twice).
# Just invoke it; it re-execs itself as transient unit 'watchit-build'.
#   follow:  tail -f /tmp/watchit-build.log
#   status:  systemctl --user status watchit-build
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
UNIT="watchit-build"
LOG="/tmp/watchit-build.log"

if [ -z "${WATCHIT_BUILD_INNER:-}" ]; then
  if systemctl --user is-active --quiet "$UNIT"; then
    echo "FATAL: $UNIT is already running (tail -f $LOG)" >&2
    exit 1
  fi
  systemctl --user reset-failed "$UNIT" 2>/dev/null || true
  : > "$LOG"
  systemd-run --user --unit="$UNIT" \
    --property=StandardOutput=append:"$LOG" \
    --property=StandardError=inherit \
    --setenv=WATCHIT_BUILD_INNER=1 \
    "$(readlink -f "$0")"
  echo "Build detached as user unit '$UNIT' — survives this session."
  echo "  follow:  tail -f $LOG"
  echo "  status:  systemctl --user status $UNIT"
  exit 0
fi

export PATH="$HOME/flutter/bin:$HOME/.cargo/bin:$PATH"
source "$HOME/Android/env.sh"

echo "=== APK build start $(date) ==="
"$REPO/native/build-android.sh"
cd "$REPO/app"
# Release builds always start clean: a corrupt incremental cache once made
# Gradle package the PREVIOUS release's Dart snapshot into a fresh-versioned
# APK ("Invalid depfile: ... kernel_snapshot_program.d" in the log, alpha.70/.71).
flutter clean
flutter pub get
flutter build apk --release
if grep -q "Invalid depfile" "$LOG"; then
  echo "FATAL: Invalid depfile during APK build — stale-snapshot risk, aborting" >&2
  exit 1
fi
echo "=== APK done $(date) ==="

echo "=== AppImage build start $(date) ==="
"$REPO/scripts/build_appimage.sh"

# Both artifacts land in dist/ under their final release-asset names
# (Watch-It-0.1.0-alpha.N.apk / -x86_64.AppImage), ready for gh release upload.
PUBSPEC_VERSION="$(grep '^version:' "$REPO/app/pubspec.yaml" | awk '{print $2}')"
VERSION="${PUBSPEC_VERSION%%+*}"
[[ "$PUBSPEC_VERSION" == *+* ]] && VERSION="$VERSION-alpha.${PUBSPEC_VERSION##*+}"
APK="$REPO/app/build/app/outputs/flutter-apk/app-release.apk"
cp "$APK" "$REPO/dist/Watch-It-$VERSION.apk"
echo "APK copied to dist/Watch-It-$VERSION.apk"
ls -l "$REPO/dist/Watch-It-$VERSION"*
echo "=== ALL BUILDS DONE $(date) ==="
