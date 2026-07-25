---
name: verify
description: Build, launch, and drive Watch-It's Linux desktop app under Xvfb to verify changes at the GUI surface, with screenshots as evidence.
---

# Verifying Watch-It changes (Linux desktop, headless)

## Build + launch

```bash
cd native/watchit_core && cargo build --release          # PATH needs ~/.cargo/bin
cd app && flutter build linux --debug                    # PATH needs ~/flutter/bin
# GOTCHA: the debug bundle does NOT contain the Rust lib — copy it in:
cp native/watchit_core/target/release/libwatchit_core.so \
   app/build/linux/x64/debug/bundle/lib/
# Clean profile + run (Xvfb :77 often already up; else Xvfb :N -screen 0 1280x800x24 &)
mkdir -p /tmp/wi-home
cd app/build/linux/x64/debug/bundle
HOME=/tmp/wi-home XDG_DATA_HOME=/tmp/wi-home/.local/share \
  XDG_CONFIG_HOME=/tmp/wi-home/.config DISPLAY=:77 ./watchit > /tmp/wi-app.log 2>&1 &
```

- App data: `$XDG_DATA_HOME/io.github.aautonomicc.watchit/` — `watchit.sqlite`
  (drift), `root_maps.sqlite` (Rust), `posters/`.
- Embedded server port is dynamic: `grep "listening on 127" /tmp/wi-app.log`;
  then `curl :port/health` (peers, stored_maps, cache stats).
- Network connect takes ~10s; status bar shows "connected · N peers".
- Debug builds have no TMDB key (good for keyless tests); pass
  `--dart-define-from-file=../.env` at build time to bundle one.

## Driving the UI

- Screenshot: `DISPLAY=:77 import -window root /tmp/shot.png` (ImageMagick).
- Click: `DISPLAY=:77 xdotool mousemove X Y click 1`. Scroll: `click 4/5`.
- **GOTCHA — no window manager on Xvfb**: nothing holds input focus, so
  keystrokes silently go nowhere after a dialog opens. Before typing into a
  GTK file dialog: `xdotool search --onlyvisible --name "Open File"` (or
  "Save File") then `xdotool windowfocus <id>`; `ctrl+l` opens the location
  bar fresh.
- **GOTCHA — xdotool drops characters** at default speed: use
  `type --delay 100`+ and screenshot the field to confirm before pressing
  Return.
- The app maps two X windows named `watchit`; the higher-id one is the real
  toplevel.

## Seeding state

Kill the app first (sqlite), then python3 sqlite3 into `watchit.sqlite`:
`media_lists (id,title,position,enabled)`,
`media_entries (list_id,name,address,position,added_at)`,
`metadata_cache (lookup_key, found=1, title, ..., poster_file, fetched_at)`,
`watch_states (address,position_ms,duration_ms,completed,updated_at)`.
Poster files go in `<data>/posters/<poster_file>`.

**GOTCHA — lookup_key**: computed by `parseMediaName` (metadata.dart); only
*video* extensions are stripped, so `BegBlag.mp3` → `movie:begblag mp3:`
(the `.mp3` stays, dots become spaces). Compute the key from the code, don't
guess.

Known-good small test address (BegBlag.mp3, 15 MB, resolves in ~20s):
`00ac7cbe1fe3e49fcd9e490eb313fabc2fe4407e67196292e961c3b34e9b1afa`

## Flows worth driving

- Home wall → gear icon (top right) → Settings; Media Lists row; About section
  at the bottom (TMDB attribution).
- Media Lists top-right icons: prefetch-maps, Import, Export-library.
  Per-list 3-dot menu: Rename / Export / Delete.
- `.watch-list` bundles: export = 3-dot → Export → Full bundle → checkboxes →
  save dialog; import = Import → Local file. Inspect bundles with `unzip -l`.
  `/rootmap/{addr}` GET/PUT on the embedded server for map store probes.
