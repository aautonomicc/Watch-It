# Watch-It

## Description
Cross-platform media player (Android, Android TV, iOS, Linux, Windows, macOS) for the Autonomi network. Client-only — no server side at all, and no Plex/Emby/Jellyfin server compatibility (stripped by design). Plex-style poster-wall UI.

## Tech Stack
Flutter 3.44.6 (SDK at ~/flutter) + media_kit (libmpv); SQLite via drift planned; Riverpod planned; Autonomi access via embedded Rust library `native/watchit_core` (ant-core, dart:ffi + in-process localhost streaming server) — no gateway/sidecar.

## Test Commands
In `app/`: `flutter analyze`, `flutter test` (PATH needs `~/flutter/bin`; `source ~/Android/env.sh` for Android builds). Rust: `cargo test` in `native/watchit_core/` (needs `~/.cargo/bin` in PATH). Before `flutter build apk`: run `native/build-android.sh` (cargo-ndk → jniLibs). Host streaming harness: `cargo run --release --bin devserver` then curl `/health` and `/xor/<addr>`.

## Dev Server
`flutter run -d linux` in `app/` — blocked until clang/ninja/libgtk-3-dev are apt-installed (Linux desktop toolchain incomplete; Android is fully working).

## Current Status
Phase 0 nearly done: scaffold, media lists, detail screen/playback, embedded Autonomi client (v0.1.0-alpha.4 released). Remaining Phase 0: on-device streaming smoke test, CI. Lists persist via shared_preferences (stand-in until drift/SQLite). Release signing: keystore ~/keystores/watchit-release.jks + password in ~/keystores/watchit-key.properties (copy to app/android/key.properties, gitignored). gh CLI authenticated as aautonomicc; publish APKs via `gh release create`.

## Architecture Notes
- Library = user-held **lists**; each entry is `{XOR public file address, file name}`. Multiple lists; import/export; later publish/subscribe lists on Autonomi
- Metadata matcher parses file name → TMDB → artwork/description/category (same pipeline media servers use, but on-device); cached in SQLite
- Playback via libmpv (media_kit) everywhere; streams `http://127.0.0.1:<port>/xor/<addr>` from the embedded client — seek works via HTTP Range
- Embedded client: `native/watchit_core` (Rust cdylib, ant-core pinned rev 629b87f) — tokio runtime + axum server on 127.0.0.1, `GET /xor/<addr>` (Range via self_encryption streaming_decrypt/get_range), `GET /health` for the Settings status tile; started once from main() over dart:ffi (lib/services/embedded_client.dart). APK is arm64-v8a only (abiFilters + jniLibs excludes); jniLibs/ and target/ are gitignored build artifacts
- Download manager for offline: downloaded item = same entry with local path, full library UX offline
- Watch state/resume points local-only in SQLite; no accounts, no telemetry
- Branding follows the etchit.io family (fetch>it/etch/it): ink/bone/copper tokens, system fonts, mono for XOR addresses — see docs/BRAND.md (mirrors etchit-io/fetchit docs/BRAND.md)
- Repo: github.com/aautonomicc/Watch-It (MIT)

## Recent Changes
- [2026-07-19] v0.1.0-alpha.5: default movie re-pointed to new XOR cebd79...3988 (old ac855e...0ea0 dead on network — cause of the endless loading spinner); seeder migrates stale address in existing installs (defaults_seeded_v2); Settings gains ABOUT section (app blurb + version via package_info_plus ^10.2.1); home screen gains NetworkStatusBar (dot + "connected · N peers" from /health, polls 3s connecting / 15s ready, hidden when native lib absent). New address verified on host: 3.8GB webm, first KB + mid-file Range both 206. 18 tests pass
- [2026-07-19] v0.1.0-alpha.4: embedded Autonomi client (native/watchit_core Rust cdylib via cargo-ndk) replaces AntTP gateway; gateway setting removed, Settings shows live connection status; verified vs live network on host (full-file md5 exact in 11s, mid-file Range byte-exact; 15MB file). arm64-only APK 46.5MB, signed, on GitHub Release. No adb device for on-device test
- [2026-07-19] Android launcher icon now matches fetchit's: adaptive icon (copper [>] chevron on ink #0a0a0a) copied from etchit-io/fetchit; legacy density PNGs rendered from same geometry (PIL script, not checked in). Ships with next release build
- [2026-07-19] v0.1.0-alpha.3: seeded Night Of The Living Dead (1968) (XOR ac855e...0ea0) as built-in default movie; detail screen with bundled poster (app/assets/posters/notld_1968.jpg) + description + Play button. 17 tests pass; signed APK on GitHub Release. Note: first build was killed by a PC restart — rebuilt and published after
- [2026-07-19] v0.1.0-alpha.2: Settings screen (gear on home) — create/rename/delete titled media lists, add/remove entries (file name + XOR address, 64-hex validated); persistence via shared_preferences; lists render on home. 9 tests pass; signed APK on GitHub Release (SHA-256 58be...dee8)
- [2026-07-19] Proper GitHub Release created (gh now authenticated): APK attached to https://github.com/aautonomicc/Watch-It/releases/tag/v0.1.0-alpha.1 (SHA-256 8a9e...60d4); orphan `apk` branch workaround deleted locally and on origin
- [2026-07-19] Phase 0 scaffold: Flutter app in app/ (android+linux), WiTokens ThemeExtension from BRAND.md, branded home screen, widget+token tests. Signed release APK built and verified (cert CN=Watch-It, SHA-256 7911...0a69); tag v0.1.0-alpha.1 pushed; APK copied to ~/watch-it-v0.1.0-alpha.1.apk
- [2026-07-19] Installed Flutter 3.44.6 stable to ~/flutter; Android SDK licenses accepted; release keystore generated (~/keystores/, 30-yr validity)
- [2026-07-19] Android TV added as sixth first-class platform (was in "Later"): same Android APK + leanback launcher entry, D-pad focus nav shared with desktop keyboard map, 10-foot layout mode; scheduled in Phase 4; tvOS stays in Later
- [2026-07-19] Added docs/BRAND.md: colours/fonts/type scale adopted from etchit-io/fetchit brand contract (copper #c9732b accent, dark/dim/light themes, `watch-it` wordmark); UI-DESIGN.md aligned (Inter dropped for system fonts)
- [2026-07-19] Pushed to github.com/aautonomicc/Watch-It (main up to date with origin)
