#!/usr/bin/env bash
# Build a Linux AppImage from the Flutter release bundle.
# Requires: flutter, linuxdeploy-x86_64.AppImage on PATH or at ~/tools/,
# and libmpv (libmpv.so.2) installed on the build host.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$REPO_ROOT/app"
PKG_DIR="$REPO_ROOT/linux-packaging"
OUT_DIR="$REPO_ROOT/dist"
LINUXDEPLOY="${LINUXDEPLOY:-$HOME/tools/linuxdeploy-x86_64.AppImage}"

VERSION="$(grep '^version:' "$APP_DIR/pubspec.yaml" | awk '{print $2}' | cut -d+ -f1)"
BUNDLE="$APP_DIR/build/linux/x64/release/bundle"

# Embedded Autonomi client: build the Rust cdylib for the host and drop it
# into the Flutter bundle's lib/ dir so it ships inside the AppImage.
# CFLAGS pins C deps to gnu17 — glibc 2.38+ headers otherwise emit
# __isoc23_* symbol versions that fail to load on older distros (Mint 21).
CARGO="${CARGO:-$HOME/.cargo/bin/cargo}"
(cd "$REPO_ROOT/native/watchit_core" && CFLAGS="-std=gnu17" "$CARGO" build --release)
CORE_LIB="$REPO_ROOT/native/watchit_core/target/release/libwatchit_core.so"
[ -f "$CORE_LIB" ] || { echo "libwatchit_core.so missing after cargo build"; exit 1; }

cd "$APP_DIR"
flutter build linux --release
cp "$CORE_LIB" "$BUNDLE/lib/"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APPDIR="$STAGE/AppDir"

# Keep the Flutter bundle layout intact under usr/bin — the runner resolves
# data/ and lib/ relative to the executable.
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib"
cp -r "$BUNDLE/." "$APPDIR/usr/bin/"

# package:sqlite3 (drift) dlopens libsqlite3.so by bare name (the
# native-assets manifest maps to an unqualified name, and the executable's
# RUNPATH doesn't apply to that dlopen), so the bundled copy must sit on
# the AppRun loader path — boxes without a system sqlite3 crash otherwise.
SQLITE_LIB="$BUNDLE/lib/libsqlite3.so"
[ -f "$SQLITE_LIB" ] || { echo "libsqlite3.so missing from Flutter bundle"; exit 1; }
cp "$SQLITE_LIB" "$APPDIR/usr/lib/"

# 192px launcher icon doubles as the AppImage icon.
cp "$APP_DIR/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png" "$STAGE/watchit.png"

LIBMPV="$(/sbin/ldconfig -p | awk '/libmpv\.so\.2 .*x86-64/{print $NF; exit}')"
[ -n "$LIBMPV" ] || { echo "libmpv.so.2 not found (apt install libmpv-dev)"; exit 1; }

"$LINUXDEPLOY" --appimage-extract-and-run \
  --appdir "$APPDIR" \
  -e "$APPDIR/usr/bin/watchit" \
  -l "$LIBMPV" \
  -d "$PKG_DIR/watchit.desktop" \
  -i "$STAGE/watchit.png" \
  --custom-apprun "$PKG_DIR/AppRun" \
  --output appimage

mkdir -p "$OUT_DIR"
mv Watch-It*.AppImage "$OUT_DIR/Watch-It-$VERSION-x86_64.AppImage" 2>/dev/null \
  || mv watchit*.AppImage "$OUT_DIR/Watch-It-$VERSION-x86_64.AppImage"
echo "Built $OUT_DIR/Watch-It-$VERSION-x86_64.AppImage"
