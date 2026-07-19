#!/usr/bin/env bash
# Cross-compile watchit_core for Android and drop the .so where Gradle
# packages it. Run before `flutter build apk`. Needs: rustup target
# aarch64-linux-android, cargo-ndk, and ANDROID_NDK_HOME (or an SDK with
# ndk/ under ANDROID_HOME — source ~/Android/env.sh).
set -euo pipefail

cd "$(dirname "$0")/watchit_core"

export PATH="$HOME/.cargo/bin:$PATH"
: "${ANDROID_HOME:=$HOME/Android/Sdk}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$(ls -d "$ANDROID_HOME"/ndk/* | sort -V | tail -1)}"

JNILIBS="../../app/android/app/src/main/jniLibs"

cargo ndk -t arm64-v8a -o "$JNILIBS" build --release
echo "Built: $JNILIBS/arm64-v8a/libwatchit_core.so"
