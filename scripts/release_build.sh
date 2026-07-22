#!/usr/bin/env bash
# Release build (APK + AppImage, TMDB key bundled) for the version currently
# in app/pubspec.yaml. Runs under systemd --user so the build survives the
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

set -a; source "$REPO/.env"; set +a
[ -n "${TMDB_API_KEY:-}" ] || { echo "FATAL: TMDB_API_KEY unset"; exit 1; }

echo "=== APK build start $(date) ==="
"$REPO/native/build-android.sh"
cd "$REPO/app"
flutter build apk --release --dart-define=TMDB_API_KEY="$TMDB_API_KEY"
echo "=== APK done $(date) ==="

echo "=== AppImage build start $(date) ==="
"$REPO/scripts/build_appimage.sh" --dart-define=TMDB_API_KEY="$TMDB_API_KEY"
echo "=== ALL BUILDS DONE $(date) ==="
