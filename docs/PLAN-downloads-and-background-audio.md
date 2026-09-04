# Plan: tidy download folders, deletion-aware startup scan, background music on mobile

Status: **IMPLEMENTED 2026-09-04** — all three parts, in one pass. Open
questions resolved per their recommendations (custom folder = the root
itself; automatic one-time tidy; no video notification in v1; hand-rolled
Kotlin service, not `audio_service`). The Android service (Part 3) builds
but needs a user APK test on a real device — no Android hardware on the
build machine. Drafted 2026-09-04 from three user asks:

1. Desktop downloads currently pile up flat in the system Downloads folder — put them
   in a `W@tch` folder, in subfolders named after the list they came from.
2. Scan the download folders on startup so manually deleted files/folders are noticed.
3. On Android (and iOS in future), music playback dies when the device sleeps —
   keep it playing and show media controls + track info in the notification area.

---

## Part 1 — Downloads land in `W@tch/<List name>/`

### Today

`DownloadManager._downloadsDir()` (download_manager.dart) resolves, in order: test
override → user-chosen custom folder (Settings → Downloads, desktop) → system
Downloads folder (desktop default since alpha.79) → app-private `<support>/downloads/`
(Android/iOS). Every file lands flat in that one directory; `_pathFor` sanitizes the
name and prefixes 8 hex chars of the address on a global name collision.

### Design

**New layout** — one folder per source list, under a `W@tch` root:

```
<system Downloads>/W@tch/Movies/Night of the Living Dead (1968) … .mp4
<system Downloads>/W@tch/Music/The Rolling Stones - Let It Bleed - 01 Gimme Shelter.mp3
```

- **Root**: `W@tch/` inside the system Downloads folder. When the user has set a
  custom download folder, that folder IS the root (lists directly inside it — the
  user already picked a dedicated place; wrapping another `W@tch` inside it is
  clutter). Recommendation, see open question 1.
- **Android/iOS**: identical structure inside the app-private `<support>/downloads/`.
  Invisible to the user but keeps one code path, and Part 2's scan is uniform.
- **List folder name**: the list's name through the existing `_pathFor` sanitize rule
  (`[/\\:*?"<>|]` → `_`), plus trailing dot/space trim (Windows rejects those).
  `W@tch` itself is filesystem-safe on Linux/Windows/macOS/Android (`@` is legal).
- **Which list**: `enqueue(entry)` has no list context (DetailScreen carries only the
  entry; show/season/album bulk downloads likewise). Resolve at enqueue time with a
  new pure helper `downloadListFolderFor(entry, lists)`: the first **enabled** list in
  library position order whose entries contain the entry's address. Entry in several
  lists → first wins (deterministic, matches how the home wall attributes entries).
  No list found (shouldn't happen — every download starts from a library surface) →
  folder `Other`. Channel lists count like any list (their name is the folder).
- The chosen path is fixed at enqueue and persisted in the task's `filePath`, exactly
  as today. Renaming/moving the list later does NOT move existing files — moving them
  would break byte-offset resume and local playback of rows pointing at the old path.
  New downloads follow the new name. (Same "applies to new downloads only" rule the
  custom-folder setting already has.)
- **Collision prefix** becomes per-folder for free (`_pathFor` already checks against
  other tasks' full paths) — two lists can now hold the same file name without the
  addr prefix.
- **Cleanup**: `remove()`/`removeMany()` delete the file today; additionally delete
  the list folder when it is left empty, and the `W@tch` root when *it* is left empty
  (rmdir only-if-empty — never recursive).

### Existing flat downloads (migration)

Recommendation: a **one-time automatic tidy on first launch** of the new version
(desktop only): for each `done` task whose file exists at a flat path, move it into
the new layout (`rename`, falling back to copy+delete across devices), update the
row's `filePath`, skip-on-any-error (a locked/missing file just stays where it is —
its row keeps the old absolute path and keeps working). Mid-flight/paused tasks are
left alone (resume reads the file at its recorded path). This is exactly the
untidiness the user asked to fix, and every file involved is app-managed. See open
question 2.

---

## Part 2 — Startup scan for manual deletions

### Today's gap

Playback already self-heals (`localPathIfDone` checks `existsSync`), and partial
files self-heal on resume (the file on disk is the resume offset; missing → restart
from 0). But a **finished** task whose file was deleted by hand is stuck:

- `enqueue()` returns early for `status == done` → the title can never be
  re-downloaded without manually removing the queue row.
- The Downloads home row and card badges key off `status == done`
  (`downloadedItems` in home_rows.dart) → deleted media still shows as downloaded.
- Settings → Downloads storage totals count ghost rows.

### Design

In `DownloadManager._load()` (runs once per launch via `ensureLoaded`), after rows
load and before `_pump()`:

- For every `done` task: if the file no longer exists, **drop the row** (in-memory +
  DB delete) — the card badge clears, the Downloads row shrinks, and Download on the
  detail page starts a fresh transfer. A deleted *folder* is just N missing files —
  same path covers it.
- Queued/paused/error tasks: leave alone (already self-healing, and dropping a
  paused row would lose the user's queue intent).
- **Unmounted-drive guard**: when the custom download folder is set and its root
  directory itself is missing (USB drive/network mount not present), skip the scan
  entirely rather than dropping every row — the files are probably not gone, just
  unreachable. The system-Downloads/app-private roots practically always exist.
- Also run the same sweep from `onAppResumed()` (cheap: one `existsSync` per done
  row) — desktop windows stay open for days, so "on startup" alone would lag.
- One `notifyListeners()` at the end when anything changed.

No schema change; no new prefs.

---

## Part 3 — Background music + media notification on Android (iOS later)

### Why it stops today

Music plays through media_kit `Player` instances (album page inline player, and
PlayerScreen for tracks opened via the detail page). There is **no foreground
service and no MediaSession**: with the screen off, Android 12+ freezes the cached
app process — mpv *and* the embedded Rust client — and Doze cuts its network. That
is the observed "app sleeps after a while". (Video is unaffected while watching
because the Video widget holds a screen wakelock via wakelock_plus.)

The right fix for music is NOT keeping the screen awake — the screen *should* sleep;
the process and network must not. That is precisely what a `mediaPlayback` foreground
service provides (no 6h budget, unlike the downloads service's `dataSync` class), and
the attached MediaSession is what puts controls + track info in the notification
shade and on the lock screen, and makes headset/Bluetooth buttons work.

### Design (hand-rolled, mirroring `DownloadForegroundService`)

The repo already has the exact pattern: Kotlin foreground service + MethodChannel
bridge + Dart singleton (download_foreground.dart / DownloadForegroundService.kt).
Recommendation: same approach for playback rather than the `audio_service` package —
it keeps deps minimal, fits two independent media_kit Player instances without
adopting audio_service's app-lifecycle wrapper, and Android TV needs nothing extra.
Revisit `audio_service` if/when an iOS target actually exists (it would cover
MPNowPlayingInfoCenter for free). See open question 4.

**Dart side**

- New `services/now_playing.dart`: `NowPlaying` ChangeNotifier singleton — the one
  source of truth for "what is audibly playing". Fields: title, artist, album,
  artwork file path (poster/cover from the posters dir), playing, position, duration,
  canNext/canPrev; callback slots onPlay/onPause/onNext/onPrev/onSeek registered by
  whichever player is active and cleared on its dispose.
  - Album inline player: feeds track metadata per track, wires next/prev/shuffle-
    aware advance into the callbacks.
  - PlayerScreen: feeds it only for **audio** entries (music files); video stays out
    of scope for v1 (open question 3).
- New `services/media_session.dart`: `MediaSessionBridge` (no-op off Android),
  listens to `NowPlaying` and mirrors state over a `watchit/media_session`
  MethodChannel (start/update/stop + metadata + position for the seek bar);
  receives button events (play/pause/next/prev/seek/stop) and dispatches to the
  registered callbacks. Throttled like the download bridge.

**Kotlin side** (new `MediaPlaybackService.kt`)

- Foreground service, `android:foregroundServiceType="mediaPlayback"` +
  `FOREGROUND_SERVICE_MEDIA_PLAYBACK` permission; partial wakelock + Wi-Fi lock
  while playing (streaming tracks need the embedded client's sockets alive —
  same locks the download service already holds).
- `MediaSessionCompat` with playback state (position/speed → lock-screen seek bar
  on Android 10+) and metadata (title/artist/album/cover bitmap decoded from the
  passed file path); `NotificationCompat.MediaStyle` notification with
  prev/play-pause/next actions; tap opens the app. Reuses the notification
  permission request the download bridge already makes on Android 13+.
- Audio focus (`AudioFocusRequest`): pause on loss (phone call), resume after
  transient loss; `ACTION_AUDIO_BECOMING_NOISY` receiver → pause when headphones
  unplug. Focus/noisy events flow back over the channel as pause/play commands —
  the actual player stays 100% in Dart/mpv.
- Lifecycle: service starts when audio playback starts, `stopForeground(false)` on
  pause (notification stays, dismissible), `stopSelf` when the player is disposed
  or the notification is dismissed while paused.

**Interactions checked**

- NetworkPause auto-pause-when-idle already counts both players via
  `setStreamingActive` — background music correctly holds off the idle pause.
- Downloads + music at once: two foreground services is fine (the download one keeps
  its dataSync type/budget; music playing does not extend download background time).
- Cellular gates: the existing streaming policy (Ask/Allowed/Wi-Fi-only) fires
  before playback starts; no change.

**iOS (future, noted for when a target exists)**: `UIBackgroundModes: audio` in
Info.plist, AVAudioSession category `.playback`, MPNowPlayingInfoCenter +
MPRemoteCommandCenter — either hand-rolled Swift twin of the bridge, or switch to
`audio_service` then.

**Verification limits**: no Android device on Ella — Kotlin service behaviour
(screen-off longevity, lock-screen controls, focus/noisy handling) needs a user APK
test; Dart side (NowPlaying wiring, bridge protocol, per-player registration) is
fully unit/widget-testable with a fake channel like the download bridge tests.

---

## Build order (each stage releasable)

1. **Folders + scan** (Part 1 + Part 2, pure Dart): `downloadListFolderFor`, new
   `_downloadsDir`/`_pathFor` layout, empty-folder cleanup, startup/resume sweep,
   one-time tidy migration. Unit tests for folder resolution, collision, sweep
   matrix (done-missing dropped, paused kept, unmounted root skipped), migration.
2. **Android background music** (Part 3): NowPlaying + bridge + Kotlin service,
   album player first, then PlayerScreen audio entries. User APK test before release.

## Open questions

1. Custom download folder: treat it as the W@tch root itself (lists directly
   inside, no extra `W@tch` wrapper)? **Recommend yes.**
2. Existing flat downloads: move them automatically into the new layout on first
   launch (skip-on-error), vs. a manual "Tidy now" button in Settings → Downloads?
   **Recommend automatic** — it is the untidiness being complained about.
3. Should video playback also get a media notification (pause/play from the shade)?
   **Recommend not in v1** — music is the reported need; video keeps the screen on
   while watched and stops mattering when backgrounded.
4. Hand-rolled Kotlin service vs. the `audio_service` package? **Recommend
   hand-rolled** (matches DownloadForegroundService, minimal deps); revisit when an
   iOS target exists.
