# Plan — auto-reconnect, background downloads, network preference, bundled NOTLD map

**Status: IMPLEMENTED 2026-07-30 (commits cf0a90b, 1265717, 9d8fba3, ba4a3fb — unreleased). Written 2026-07-30 from the
user's alpha.37 field reports.** Covers five asks:

1. AppImage: after unplugging the network cable, the app never reconnects
   when the cable comes back.
2. Android: after the phone sleeps and wakes, the app never reconnects.
3. Android: downloads must keep running in the background, with a
   progress notification (target: regular Android — Samsung + Pixel).
4. Android: a setting to prefer/forbid mobile data vs Wi-Fi.
5. Bundle the Night of the Living Dead root data map in the app so the
   demo movie plays fast on a fresh install.

---

## Root cause of 1 + 2 (one bug, two symptoms)

`Engine` holds the ant-core `Client` in a `OnceCell` (engine.rs:96):
**connected once, never rebuilt**. The retry machinery (connect_bounded,
backoff, `/health` attempts/message) only runs *until* the first successful
connect. After that, a network drop (cable pull, phone sleep killing the
QUIC sockets) leaves a live `Client` object whose peers are all dead —
`/health` reports `ready` with 0 peers forever. ConnectivityMonitor
correctly *detects* this (its offline rule is exactly `ready` + 0 peers)
and gates the UI, but nothing ever re-dials. saorsa-core does not redial
bootstrap peers on its own (observed on both platforms).

So the fix is Rust-side reconnect supervision; the Dart side only adds
fast triggers (lifecycle resume, OS network-change events).

## Phase A — auto-reconnect (fixes 1 + 2)

### A1. Rust: make the client replaceable

- Replace `client: OnceCell<Client>` with `tokio::sync::RwLock<Option<Arc<Client>>>`
  (or arc-swap). `Engine::client()` returns `Arc<Client>`; keep the
  single-flight property (concurrent callers share one connect attempt —
  a `Mutex`-guarded "connecting" flag or keep a `OnceCell` *inside* a
  generation struct).
- Ripple: `stream_full`/`stream_range`/`prefetch_ahead`/`fetch_chunk_batch`
  currently use `&'static Client`; they take the `Arc` instead (clone into
  the spawned tasks). In-flight streams on a dead client keep their old
  `Arc`, fail on the next fetch, and end — the Dart layers already handle
  that (player error surface, download auto-pause).
- `connected_peer_count`, `is_ready`, health reporting read the current
  slot.

### A2. Rust: supervision task

- Spawned once at engine start: after a successful connect, poll
  `connected_peers()` every ~10s. If 0 peers for **2 consecutive polls**
  (~20s — rides out transient blips), drop the client from the slot and
  re-enter the existing connect loop (attempt counter + last_error resume
  exactly as during first connect, so `/health` flips back to
  `connecting` with attempt/message detail and the UI's existing offline
  banner + fast 4s polling take over).
- Reuse `connect_bounded` + the 2s→60s backoff; reset backoff on each
  supervisor-triggered round.
- Dropping the old client must also be safe while streams hold `Arc`
  clones — nothing to do beyond letting the `Arc` drain.

### A3. Rust: `POST /reconnect` kick endpoint

- No-op when connected with peers; otherwise: cancel the current backoff
  sleep and start a connect attempt *now*. Returns current health JSON.
- Why: the supervisor alone reconnects within ~20s + backoff; the kick
  makes cable-replug and phone-wake feel instant.

### A4. Dart: fast triggers

- **Lifecycle observer** (new, main.dart): a `WidgetsBindingObserver`; on
  `AppLifecycleState.resumed` → `ConnectivityMonitor.refresh()`; if
  offline → `POST /reconnect`. Covers phone wake.
- **OS network events**: add `connectivity_plus` (supports Android +
  Linux/NetworkManager — covers cable replug on the AppImage). On any
  change to a usable network type → same kick. (connectivity_plus also
  feeds Phase C's Wi-Fi policy, so it pays for itself twice.)
- ConnectivityMonitor stays the single source of truth; the kick just
  accelerates what its 4s offline poll would eventually see.

### A5. Dart: auto-resume downloads on reconnect

- Today connection loss auto-pauses downloads but resume is manual
  (documented gap). Distinguish system pauses from user pauses: new
  `pausedBySystem` bool column on the `downloads` table (drift schema
  v7; the in-memory `_pausedForPlayback` pattern already exists but is
  lost on restart — persist this one so a next-launch-while-online can
  resume too). Set it in the connection-loss auto-pause path; clear it
  on any user action.
- DownloadManager listens to ConnectivityMonitor; when `offline` flips
  false → re-queue every `paused && pausedBySystem` task.

### A validation

- Rust: devserver + `WATCHIT_PEERS` pointing at a blackholed address to
  test supervisor → reconnect → recover (script: connect against real
  peers, `ip netns` / nft drop to cut traffic, restore, assert `/health`
  returns to ready without restart).
- Dart: ConnectivityMonitor/DownloadManager auto-resume unit tests with
  an injected probe (existing test pattern).
- Manual: AppImage cable pull on Ella; APK sleep/wake on the user's phone.

## Phase B — bundled NOTLD data map (ask 5; smallest win, can ship first)

All plumbing already exists: `verify.rs` offline map verification +
`PUT /rootmap/{addr}` (used by bundle import) and `GET /rootmap/{addr}`.

- Export the already-resolved map from Ella's dev install
  (`GET /rootmap/66cacd0604b01b2c2f1da1c1c3c05609d3b4cc448cff3b6cdd868e6b7eebcb13`)
  → check into `app/assets/rootmaps/66cacd06….map` (DataMap::to_bytes;
  ~1300 chunk entries for the 5.3GB file ≈ low hundreds of KB — fine as
  an asset).
- Startup seeding (main.dart, after `EmbeddedClient.start()` +
  `ensureDefaults`, fire-and-forget): `GET /rootmap/<addr>` → on 404,
  `PUT` the asset bytes. Idempotent, fully offline, and the existing
  verify step rejects a corrupt asset rather than poisoning the store.
- Effect: fresh install skips the 20–31s cold resolve; first byte is
  just chunk fetches (a few seconds). Poster/metadata are already
  bundled (`_notld` catalog), so first impression = tap → play.
- Guard: derive the asset filename from `kDefaultMovieAddress` in one
  place + a test asserting the asset exists for that address, so a
  future default-movie swap can't ship a stale map silently.

## Phase C — network-type preference (ask 4)

- New Settings → **Network** section (Android-relevant; harmless no-op on
  desktop where connectivity_plus reports ethernet/wifi):
  - **Downloads**: `Wi-Fi only` (default) / `Wi-Fi + mobile data`.
  - **Streaming**: `Ask on mobile data` (default) / `Allow` / `Wi-Fi only`.
- Enforcement is Dart-side only (the Rust client can't tell network
  types apart):
  - DownloadManager gains a policy gate checked before each task start
    and on every connectivity_plus change: on cellular with Wi-Fi-only
    set → system-pause the queue with a distinct **"Waiting for
    Wi-Fi"** status label (reuses the A5 `pausedBySystem` machinery);
    Wi-Fi back → auto-resume.
  - Streaming: on Play while on cellular, `Ask` shows a once-per-session
    confirm dialog ("You're on mobile data — stream anyway?");
    `Wi-Fi only` blocks with the same snackbar pattern as offline gating.
- Caveat to document in Settings copy: the embedded client keeps a few
  idle peer connections regardless — the toggles govern the heavy
  traffic (streams/downloads), not every byte.
- Tests: policy gate unit tests with an injected connectivity stream.

## Phase D — Android background downloads + progress notification (ask 3)

The download pump is Dart in the main isolate, streaming from the
in-process Rust server. When the app is backgrounded, Android freezes
cached apps (Android 12+ freezes the whole process — Dart *and* the Rust
tokio threads) and Doze cuts network. The sanctioned fix on both Pixel
and Samsung is a **foreground service** with a visible notification.

### D1. Minimal Kotlin service (no plugin)

- Hand-rolled `DownloadForegroundService` next to MainActivity + a small
  MethodChannel (precedent: the voice-search plan already commits to a
  platform channel; avoids `flutter_foreground_task`'s separate-isolate
  model, which would wall the pump off from the drift DB and the
  embedded server state).
- Dart → service: `start()` when the first task begins, `update(done,
  total, percent, name)` throttled to ~1/s from the existing progress
  notifications, `stop()` when the queue drains/pauses. Service →
  nothing (tap intent opens the app on the Downloads screen).
- The service holds a partial wakelock + Wi-Fi lock while active and
  posts an ongoing, silent, low-importance notification with
  `setProgress` — "Downloading 2 of 5 — 43% · Night of the Living
  Dead". v1: no action buttons (pause/cancel from the app); v2 maybe.

### D2. Manifest + permissions

- `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC`,
  `POST_NOTIFICATIONS` (runtime prompt on Android 13+, requested on
  first enqueue with a soft explainer; denial = downloads still work in
  foreground, just no notification and no background guarantee).
- `<service android:foregroundServiceType="dataSync">`.

### D3. Platform caveats (the Samsung/Pixel ask)

- **Android 15 dataSync 6h/day cap** (relevant: targetSdk follows
  Flutter's default and will reach 35): the service gets
  `onTimeout()` → gracefully system-pause the queue + notify "Downloads
  paused — reopen Watch-It to continue". Resume-from-byte already works,
  so nothing is lost. A 5.3GB movie on a decent link finishes well
  inside 6h; note it, don't engineer around it in v1.
- **Samsung**: aggressive battery management can still kill foreground
  services under "Sleeping apps". One-time tip card in Settings →
  Downloads on Samsung devices pointing at Battery → Allow background
  activity. Pixel behaves by the book.
- **Interaction with A**: while backgrounded with the service up, the
  process stays unfrozen, so the reconnect supervisor also keeps working
  — downloads survive brief network blips mid-background via A2+A5.

### D validation

- No emulator on Ella — needs on-device testing (user's Samsung/Pixel):
  screen-off download to completion, notification progress, revoked
  notification permission path, Doze (`adb shell cmd deviceidle force-idle`).
- Dart-side channel logic unit-testable with a mocked MethodChannel.

## Suggested order + effort

| Phase | What | Effort | Risk |
|---|---|---|---|
| B | Bundled NOTLD map | ~half day | tiny — plumbing exists |
| A | Reconnect supervision | ~2 days | medium — Arc refactor touches all streaming paths |
| C | Wi-Fi/mobile preference | ~1 day | low — builds on A5 + connectivity_plus |
| D | Foreground service + notification | ~2 days + on-device testing | medium — device-fleet quirks |

A before C (C reuses A's `pausedBySystem` + connectivity_plus). D last —
it depends on nothing but benefits from A being solid. Each phase is a
releasable alpha on its own.
