#!/usr/bin/env bash
# Android-only build; no AppImage, upload, wallet or network-client execution.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
abis=arm64-v8a
test_app=0
usage() {
    echo "Usage: $0 [--abis armeabi-v7a|arm64-v8a|armeabi-v7a,arm64-v8a] [--test-app]"
    echo "Requires Flutter, Python 3, cargo-ndk, Android SDK/NDK and the selected Rust targets."
    echo "--test-app: .validation application ID, W@tch Test label, local debug certificate."
}
while (($#)); do
    case "$1" in
        --abis) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; abis=$2; shift 2 ;;
        --test-app) test_app=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
case "$abis" in
    arm64-v8a) platforms=android-arm64 ;;
    armeabi-v7a) platforms=android-arm ;;
    armeabi-v7a,arm64-v8a|arm64-v8a,armeabi-v7a) platforms=android-arm,android-arm64 ;;
    *) echo "Unsupported or duplicate ABI selection: $abis" >&2; exit 2 ;;
esac
export WATCHIT_ANDROID_ABIS="$abis" WATCHIT_TEST_APP="$test_app"
: "${ANDROID_HOME:?Set ANDROID_HOME to the Android SDK directory}"
: "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to the NDK matching Flutter ndkVersion}"
for tool in flutter python3 cargo; do command -v "$tool" >/dev/null; done
# Refuse a native/Gradle NDK mismatch before starting an expensive build.
python3 - <<'PY'
import json, os, pathlib, re, subprocess
info = json.loads(subprocess.check_output(['flutter', '--version', '--machine'], text=True))
extension = pathlib.Path(info['flutterRoot']) / 'packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt'
expected = re.search(r'val ndkVersion: String = "([^"]+)"', extension.read_text())
props = pathlib.Path(os.environ['ANDROID_NDK_HOME']) / 'source.properties'
actual = re.search(r'^Pkg.Revision\s*=\s*(\S+)', props.read_text(), re.M)
if not expected or not actual or expected[1] != actual[1]:
    raise SystemExit('Native NDK does not match Flutter/Gradle ndkVersion')
PY
build_tools="${WATCHIT_BUILD_TOOLS:-36.0.0}"
aapt2="$ANDROID_HOME/build-tools/$build_tools/aapt2"
apksigner="$ANDROID_HOME/build-tools/$build_tools/apksigner"
test -x "$aapt2"
test -x "$apksigner"
mkdir -p "$REPO/dist"
# Serialize all ABI builds sharing this checkout and its jniLibs/Gradle cache.
exec 9>"$REPO/dist/android-build.lock"
flock -n 9 || { echo "Another Android build owns this checkout" >&2; exit 1; }
cd "$REPO"
IFS=, read -r -a targets <<< "$abis"
"$REPO/native/build-android.sh" "${targets[@]}"
cd "$REPO/app"
flutter clean
flutter pub get --enforce-lockfile
log="$REPO/dist/android-build.log"
flutter build apk --release --target-platform "$platforms" --split-per-abi 2>&1 | tee "$log"
if grep -q "Invalid depfile" "$log"; then
    echo "Invalid depfile: refusing an artifact with possible stale Dart code" >&2
    exit 1
fi
package=io.github.aautonomicc.watchit
suffix=""
if [[ $test_app == 1 ]]; then package+=.validation; suffix=-validation; fi
revision=$(git -C "$REPO" rev-parse HEAD)
for abi in "${targets[@]}"; do
    apk="$REPO/app/build/app/outputs/flutter-apk/app-$abi-release.apk"
    name="Watch-It-${revision:0:8}-$abi$suffix"
    # No copy is called validated until both Android tools and the native
    # library check have passed. Receipt states whether source was dirty.
    python3 "$REPO/scripts/verify_android_apk.py" "$apk" \
        --abis "$abi" --package "$package" --aapt2 "$aapt2" --apksigner "$apksigner" \
        --source "$REPO" --output "$REPO/dist/$name.receipt.json"
    cp "$apk" "$REPO/dist/$name.apk"
    (cd "$REPO/dist" && sha256sum "$name.apk" > "$name.apk.sha256")
    echo "Validated artifact: dist/$name.apk"
done
