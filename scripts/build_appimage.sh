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
APPIMAGETOOL="${APPIMAGETOOL:-$HOME/tools/appimagetool-x86_64.AppImage}"

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

# Extra args (e.g. --dart-define=TMDB_API_KEY=…) pass through to flutter build.
cd "$APP_DIR"
flutter build linux --release "$@"
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

# Deploy into the AppDir only — packing happens after the audio-lib
# restructuring below (a second linuxdeploy pass would re-bundle libpulse).
"$LINUXDEPLOY" --appimage-extract-and-run \
  --appdir "$APPDIR" \
  -e "$APPDIR/usr/bin/watchit" \
  -l "$LIBMPV" \
  -d "$PKG_DIR/watchit.desktop" \
  -i "$STAGE/watchit.png" \
  --custom-apprun "$PKG_DIR/AppRun"

# Audio client libs are system-first with bundled fallback (AppRun picks per
# host): park the ones linuxdeploy bundled OFF the loader path in fallback/
# (a bundled Pulse client vs the host's daemon = silent audio), and add host
# copies of the three linuxdeploy deliberately excludes — libmpv/libavdevice
# hard-link them, so distros without e.g. JACK otherwise fail at load.
FALLBACK="$APPDIR/usr/lib/fallback"
mkdir -p "$FALLBACK"
for pat in libpulse.so.0 libpulsecommon-*.so libsndio.so.7 libopenal.so.1; do
  for f in "$APPDIR/usr/lib/"$pat; do
    [ -e "$f" ] && mv "$f" "$FALLBACK/"
  done
done
for lib in libjack.so.0 libpipewire-0.3.so.0 libasound.so.2; do
  src="$(/sbin/ldconfig -p | awk -v l="$lib" '$1==l && /x86-64/{print $NF; exit}')"
  [ -n "$src" ] || { echo "$lib not found on build host"; exit 1; }
  cp -L "$src" "$FALLBACK/"
done
for lib in libjack.so.0 libpipewire-0.3.so.0 libasound.so.2 \
           libpulse.so.0 libsndio.so.7 libopenal.so.1; do
  [ -e "$FALLBACK/$lib" ] || { echo "fallback/$lib missing"; exit 1; }
done

# Publish quality tiers: static ffmpeg/ffprobe (johnvansickle build,
# fully static — no glibc/soname interplay with the bundled libmpv
# stack) land beside the app binary, where FfmpegService looks first.
# Tarball cached in ~/tools and sha256-pinned; a hash mismatch means the
# release URL moved on to a newer version — re-pin deliberately.
FFMPEG_TAR="${FFMPEG_TAR:-$HOME/tools/ffmpeg-7.0.2-amd64-static.tar.xz}"
FFMPEG_URL="https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz"
FFMPEG_SHA256="abda8d77ce8309141f83ab8edf0596834087c52467f6badf376a6a2a4c87cf67"
[ -f "$FFMPEG_TAR" ] || curl -fsSL -o "$FFMPEG_TAR" "$FFMPEG_URL"
echo "$FFMPEG_SHA256  $FFMPEG_TAR" | sha256sum -c --quiet - \
  || { echo "ffmpeg tarball sha256 mismatch"; exit 1; }
tar -xJf "$FFMPEG_TAR" -C "$STAGE" \
  ffmpeg-7.0.2-amd64-static/ffmpeg ffmpeg-7.0.2-amd64-static/ffprobe
install -m755 "$STAGE/ffmpeg-7.0.2-amd64-static/ffmpeg" \
  "$STAGE/ffmpeg-7.0.2-amd64-static/ffprobe" "$APPDIR/usr/bin/"
"$APPDIR/usr/bin/ffprobe" -version >/dev/null || { echo "bundled ffprobe broken"; exit 1; }

mkdir -p "$OUT_DIR"
ARCH=x86_64 "$APPIMAGETOOL" --appimage-extract-and-run "$APPDIR" \
  "$OUT_DIR/Watch-It-$VERSION-x86_64.AppImage"
echo "Built $OUT_DIR/Watch-It-$VERSION-x86_64.AppImage"
