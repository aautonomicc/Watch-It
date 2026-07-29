# Brand & design tokens

Watch-It's visual identity follows the **etchit.io family** design language
(see [etchit-io/fetchit](https://github.com/etchit-io/fetchit) `docs/BRAND.md`
and <https://etchit.io/brand.html>): warm near-black surfaces, bone-white text,
a single copper accent, system fonts, lowercase mono wordmark. The apps in that
family read as one continuous brand; Watch-It adopts the same tokens so it sits
naturally beside them, extended with the handful of roles a media player needs.

## Wordmark

The family pattern is a lowercase compound with a separator glyph
(`fetch>it`, `etch/it`). Ours keeps the hyphen:

> **`watch-it`** — mono family, 18px, weight 700, lowercase.

In app chrome (the home app bar) the wordmark is locked up with the launcher
icon's bucket mark: the three tapered popcorn-bucket stripes (bone / red /
bone, drawn by `widgets/brand_mark.dart`) followed by **`watch-it`** in bone —
mono, 18px, weight 700.

Tagline slot in the family: *etch it. fetch it. **watch it.***

## Theme tokens

Three themes; **dark is default** (poster art provides the colour). Token names
and values match the fetchit contract exactly; the `wi-*` tokens are Watch-It
extensions.

| Token             | Role                                        |
|-------------------|---------------------------------------------|
| `--ink`           | canvas background                           |
| `--ink-2`         | elevated surface (cards, sidebar, dialogs)  |
| `--line`          | dividers, hairlines                         |
| `--bone`          | primary text                                |
| `--bone-dim`      | secondary text                              |
| `--ash`           | labels, muted, helper text                  |
| `--copper`        | accent (play, focus, progress, links)       |
| `--copper-bright` | accent hover / active                       |
| `--rust`          | error (fetch failed, playback error)        |
| `--signal-ok`     | success (downloaded, verified)              |
| `--wi-scrim`      | poster/backdrop gradient overlay            |
| `--wi-progress`   | watched-progress bar fill (= `--copper`)    |

### Dark (default)

```css
--ink: #0a0a0a;       --ink-2: #141414;      --line: #222;
--copper: #c9732b;    --copper-bright: #e58a3f;
--bone: #f5f2eb;      --bone-dim: #d6cfc0;   --ash: #8a8a8a;
--rust: #ff8a7a;      --signal-ok: #6ab04c;
--wi-scrim: linear-gradient(rgba(10,10,10,0) 40%, #0a0a0a 100%);
```

### Dim

```css
--ink: #1a1612;       --ink-2: #221d18;      --line: #2a2520;
--copper: #c9732b;    --copper-bright: #e58a3f;
--bone: #f5f2eb;      --bone-dim: #e6dfd0;   --ash: #a09a90;
--rust: #ff8a7a;      --signal-ok: #6ab04c;
--wi-scrim: linear-gradient(rgba(26,22,18,0) 40%, #1a1612 100%);
```

### Light

```css
--ink: #f5f2eb;       --ink-2: #faf7f2;      --line: #d6cfc0;
--copper: #c9732b;    --copper-bright: #b86420;
--bone: #0a0a0a;      --bone-dim: #1a1814;   --ash: #3a3a3a;
--rust: #c0392b;      --signal-ok: #3d7e2c;
--wi-scrim: linear-gradient(rgba(245,242,235,0) 40%, #f5f2eb 100%);
```

Rules carried over from the fetchit contract:

- No hex literals in UI code — everything goes through a token
  (in Flutter: a `ThemeExtension` holding these values, keyed by theme).
- New role needed? Add a token here first, then use it.
- The player surface (video + controls) is always dark-chromed regardless of
  theme; controls draw on `#0a0a0a` scrims with dark-theme token values.

## Fonts

**App chrome: system fonts only.** No bundled or downloaded UI font — Watch-It
melts into the host OS like the rest of the family (Roboto on Android, San
Francisco on iOS/macOS, Segoe UI on Windows, Cantarell/host font on Linux).
Body base is `14px/1.5`.

**Monospace** — used for the wordmark and for XOR addresses / hex / data-map
displays:

```
"JetBrains Mono", "Source Code Pro", Menlo, Consolas, monospace
```

Name-preference only; nothing is shipped. Fallback to the platform mono.

(This supersedes the earlier Inter candidate in UI-DESIGN.md.)

## Typography scale

Same canonical px scale as the family — don't invent in-between sizes; if a
new size is genuinely needed, add it to this table first.

| Surface                                    | Size | Weight | Notes                                                 |
|--------------------------------------------|-----:|-------:|-------------------------------------------------------|
| Page heading (h1 — "Library", "Settings")  | 22px |    600 | `letter-spacing: -0.01em`                             |
| Section heading (h2 — row titles: "Continue Watching") | 15px | 600 | Mixed case                                  |
| Subsection label / chip tag ("GENRE")      | 11px |    600 | uppercase, `letter-spacing: 0.08em`                   |
| Body paragraph (overview text)             | 14px |    400 | Body base; `line-height: 1.5`                         |
| Compact body (episode rows, descriptions)  | 13px |    400 | `line-height: 1.55`                                   |
| Helper / meta (runtime, year, file size)   | 12px |    400 | `color: var(--ash)`                                   |
| Micro chip (badge counts, quality tags)    | 11px |    500 | Tag pills, unwatched counts                           |
| Wordmark                                   | 18px |    700 | Mono family, lowercase                                |
| Tab / nav label                            | 13px |    500 | `letter-spacing: 0.02em`                              |
| Poster card title                          | 13px |    500 | Single line, ellipsized                               |
| XOR address / hex                          | 13px |    400 | Mono                                                  |

Headings use `--bone`; helper/meta use `--ash`. The tokens carry theme
switching — no per-theme text styles.

## Accent usage (media-player specifics)

One accent, used sparingly so poster art stays the hero:

- **Play/Resume button, focus rings, active tab, seek bar fill, watched-progress
  bars** → `--copper` (hover/drag: `--copper-bright`).
- **Download states on cards**: stream-only = outline glyph in `--ash`;
  downloading = progress ring in `--copper`; downloaded = check in
  `--signal-ok`; failed = `--rust`.
- Never colour large surfaces with copper; it is a line-and-glyph accent on
  `--ink` / `--ink-2`.

## App icon

A striped popcorn bucket on the family's near-black `#0a0a0a` square: three
tapered stripes (steep-sided bucket silhouette, top wider than the base) —
bone, **red `#ef5350`**, bone. The red is icon-only (`WiTokens.bucketRed`);
it never appears in UI chrome, which stays on the copper accent. Flat, no
gradients. Canonical source: `branding/icon.svg` (512px master render
`branding/icon-512.png`); launcher PNGs are resized from it (Android mipmaps
48–192px, `linux/runner/resources/watchit.png` 192px, AppImage icon reuses
the xxxhdpi mipmap via `scripts/build_appimage.sh`).
