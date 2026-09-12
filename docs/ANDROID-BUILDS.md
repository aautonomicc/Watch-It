# Repeatable Android builds

`scripts/build_android.sh` builds Android artifacts without also building the
Linux AppImage. Its default is the existing ARM64 release. It selects the same
ABI for the embedded Rust client, Flutter and Gradle packaging, then checks the
resulting APK rather than relying on its filename.

The official release pipeline (`scripts/release_build.sh`) builds a single fat
APK containing both `armeabi-v7a` and `arm64-v8a` since alpha.98, so release
APKs install on devices that expose only 32-bit app ABIs (Fire TV Sticks, the
Google TV Streamer). The device picks its own ABI at install time.

## Toolchain

Use Flutter 3.44.6 (Dart 3.12.2), JDK 17, Android platform 36, build-tools 36.0.0,
NDK 28.2.13676358, cargo-ndk 4.1.2 and Python 3.11+. The Gradle wrapper and Cargo/
pub lockfiles in the checkout define the other dependency inputs. Flutter 3.44.6
sets minimum Android API 24; the native build uses the same minimum.

Set `ANDROID_HOME` and `ANDROID_NDK_HOME` explicitly. Put Flutter, cargo/rustup,
Java and Python on PATH, and install the selected Android Rust targets:

```sh
rustup target add armv7-linux-androideabi aarch64-linux-android
cargo install cargo-ndk --version 4.1.2 --locked
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/28.2.13676358"
export CARGO_BUILD_JOBS=3
```

Build inside a Linux filesystem (for example WSL's home directory), with space
for the SDK, native dependencies and both target caches. Pin the Rust toolchain
used for a release as well; the receipt records its actual version. Select only
the ABIs you need on a first build to limit downloads and compile work.

## Commands

```sh
# Separate test app for a device exposing only 32-bit app ABIs:
scripts/build_android.sh --abis armeabi-v7a --test-app

# Normal ARM64 release using the existing signing configuration:
scripts/build_android.sh

# Two separate APKs, each containing only its own native libraries:
scripts/build_android.sh --abis armeabi-v7a,arm64-v8a
```

`--test-app` adds `.validation` to the application ID, shows `W@tch Test` as the
launcher label, and uses the local Android debug certificate. It has separate
app data and can coexist with the official app. This is for independent testing;
it does not replace the maintainer's official signing identity. Without the flag,
the existing `key.properties` signing behavior is preserved (including its
existing debug fallback when that file is absent). Inspect the certificate report
before distributing an artifact. Never include private signing material.

The script serializes builds using a checkout-local lock, rebuilds the selected
native library with Cargo's lockfile enforced, cleans Flutter's previous output,
and uses the pub lockfile. Unselected JNI ABIs are excluded even when present in
plugin AARs or left by a previous build. An `Invalid depfile` build log prevents
the wrapper from labeling the result validated.

For split APKs, Flutter's `split-per-abi` Gradle property supplies the ABI split
configuration. The app sets `ndk.abiFilters` only for non-split builds: Android's
Gradle plugin rejects both being set together. Packaging exclusions and the
post-build artifact check still apply in both modes.

Each selected ABI produces an APK, SHA-256 file and JSON receipt in `dist/`.
The receipt records the source revision and dirty state, Flutter/Rust/cargo-ndk
versions, package/minimum API, actual native libraries, and certificate report.
Build from a clean committed checkout when preparing review artifacts. Pinned
inputs and a repeatable command are not a claim of byte-for-byte reproducibility.

## Checks and hardware acceptance

The verifier rejects duplicate ZIP members, unexpected ABIs, missing client/
Flutter/player libraries, and native files whose ELF architecture/type disagrees
with their ABI directory. Android's `aapt2` checks the package, API 24 and TV
launcher entry; `apksigner verify` checks the artifact signature. This does not
attest who owns that certificate or prove runtime loader/playback compatibility.

Offline checks:

```sh
bash -n scripts/build_android.sh native/build-android.sh
python3 -m unittest discover -s scripts -p 'test_android_apk.py'
```

CI runs these packaging-regression checks alongside the existing Flutter tests.
They use synthetic ELF headers to test rejection behavior; they do not substitute
for a real cross-build. Independently check at least one built APK per selected
ABI and compare the regular ARM64 result before accepting a build change.

Record device model/OS/ABIs, install result, native-client connection, remote-only
navigation, first picture, sound and sustained playback as separate observations.
Keep casting and native playback results separate. No install, app launch,
Autonomi client, wallet operation or publication is performed by the build script.
