#!/usr/bin/env bash
# Cross-compile watchit_core for Android and drop the .so where Gradle
# packages it. Run before `flutter build apk`. Needs: rustup target
# the matching Android Rust target, cargo-ndk, and ANDROID_NDK_HOME (or an SDK with
# ndk/ under ANDROID_HOME — source ~/Android/env.sh).
set -euo pipefail

# No arguments preserves the regular ARM64 release. The Android-only
# wrapper passes the same selection to Cargo, Flutter and Gradle.
ABIS=("${@:-arm64-v8a}")
for abi in "${ABIS[@]}"; do
    case "$abi" in
        arm64-v8a|armeabi-v7a) ;;
        *) echo "Unsupported Android ABI: $abi" >&2; exit 2 ;;
    esac
done

cd "$(dirname "$0")/watchit_core"

export PATH="$HOME/.cargo/bin:$PATH"
: "${ANDROID_HOME:=$HOME/Android/Sdk}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$(ls -d "$ANDROID_HOME"/ndk/* | sort -V | tail -1)}"

JNILIBS="../../app/android/app/src/main/jniLibs"

# --platform 24 matches the app's minSdk (Flutter's default): the x0x
# tree's if_addrs needs getifaddrs, which Android's libc gained in 24.
# cargo-ndk copies EVERY cdylib artifact it finds in the target dir, and
# ant-core + self_encryption both declare a cdylib crate-type (for their
# WASM builds), so hash-suffixed libant_core-<hash>.so / libself_encryption-
# <hash>.so pile up one set per dependency bump and ride into the APK as dead
# weight (alpha.121 shipped 18 of them, 13.7 MB — libwatchit_core.so links
# both statically, nothing dlopens them). Start each requested ABI dir clean.
for abi in "${ABIS[@]}"; do
    rm -rf "$JNILIBS/$abi"
done
targets=()
for abi in "${ABIS[@]}"; do targets+=(-t "$abi"); done
cargo ndk "${targets[@]}" --platform 24 -o "$JNILIBS" build --locked --release --lib
for abi in "${ABIS[@]}"; do
    test -s "$JNILIBS/$abi/libwatchit_core.so"
    # Only our own library may remain — any side dylib means cargo-ndk
    # picked up a dependency artifact (see above) and the APK would bloat.
    find "$JNILIBS/$abi" -name '*.so' ! -name libwatchit_core.so -delete
    stray="$(find "$JNILIBS/$abi" -name '*.so' ! -name libwatchit_core.so | wc -l)"
    [ "$stray" -eq 0 ] || { echo "stray native libraries left in $JNILIBS/$abi" >&2; exit 1; }
    echo "Built: $JNILIBS/$abi/libwatchit_core.so"
done
