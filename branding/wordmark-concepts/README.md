# W@tch wordmark concepts

Rebrand evaluation samples for renaming `watch-it` → **W@tch**.

**ADOPTED 2026-07-31: w22 — Anton** (bone `W`/`tch`, accent-blue `@`). The
font ships as `app/assets/fonts/Anton-Regular.ttf` and the wordmark is drawn
by `BrandWordmark` in `app/lib/widgets/brand_mark.dart`; see docs/BRAND.md.
Everything else in this directory is the evaluation history.

Colors are the current brand tokens: ink `#0a0a0a`, bone `#f5f2eb`, accent
blue `#42a5f5` (light-theme accent `#1976d2`). Default treatment: bone
`W`/`tch` with the `@` in accent blue.

## Files

- `w01`–`w16` — one tile per font (2026-07-31 round):
  Roboto Black (the app's native Flutter font), Roboto Condensed Bold,
  Montserrat ExtraBold, Bebas Neue (caps-only), Orbitron Bold, Righteous,
  Oswald SemiBold, Archivo Black, Comfortaa Bold, Quicksand Bold,
  Monoton (marquee), Limelight (art deco), Bungee, Audiowide,
  DejaVu Sans Mono Bold, URW Gothic Demi
- `contact-sheet-fonts.png` — all 16 fonts, default treatment
- `w17`–`w32` — round 2 (2026-07-31):
  Poppins ExtraBold, Raleway Black, Rubik Bold, Exo 2 Bold,
  Space Grotesk Bold, Anton, Staatliches (caps-only), Russo One,
  Black Ops One (stencil), Alfa Slab One, Ultra, Abril Fatface,
  Titan One, Bangers (caps-only comic), Lobster (script),
  Press Start 2P (pixel)
- `contact-sheet-fonts-2.png` — the 16 round-2 fonts, default treatment
- `s1`–`s8` + `contact-sheet-styles.png` — color/case treatments on
  Montserrat ExtraBold: all bone, blue @, all blue, caps `W@TCH`,
  lowercase `w@tch`, bone-dim + blue @, light theme, blue W
- `legibility-appbar.png` — round-1 fonts at ~app-bar size (30pt)
- `legibility-appbar-2.png` — round-2 fonts at ~app-bar size (30pt)

## Font sources / licenses

Google Fonts (all SIL OFL): Montserrat, Bebas Neue, Orbitron, Righteous,
Oswald, Archivo Black, Comfortaa, Quicksand, Monoton, Limelight, Bungee,
Audiowide; round 2 adds Poppins, Raleway, Rubik, Exo 2, Space Grotesk,
Anton, Staatliches, Russo One, Black Ops One, Alfa Slab One, Abril
Fatface, Titan One, Bangers, Lobster, Press Start 2P (all OFL) and Ultra
(Apache 2.0). Roboto (Apache 2.0) ships with Flutter. DejaVu / URW Gothic
are system fonts. Downloaded TTFs live in `/tmp/wfonts/` (not committed);
variable fonts were instanced to static weights with fonttools
(`instantiateVariableFont`, `inplace=True`).

Adopting any non-Roboto font means bundling its TTF as a Flutter asset
(`pubspec.yaml` fonts section) plus its license file.

## Observations (for the pick)

- The `@` glyph varies a lot: Oswald, Comfortaa, Quicksand, and Limelight
  draw a large descending `@` that drops below the baseline — awkward in a
  tight app bar. Roboto Black, Montserrat, Righteous, Bungee, Bebas,
  Orbitron, and Audiowide keep it compact.
- Bebas Neue and Monoton have no lowercase — always render `W@TCH`.
- Monoton's inline-stripe style echoes the striped popcorn bucket but is
  the weakest at small sizes.
- At app-bar size everything except Monoton stays legible.

Round 2 (w17–w32):

- Staatliches and Bangers are caps-only (`W@TCH`); Lobster is a script,
  Press Start 2P is pixel/8-bit — both are personality picks, not
  app-bar-safe defaults.
- Exo 2, Russo One, Staatliches, and Black Ops One draw a squared-off,
  boxy `@` — distinctive, reads more "tech". Press Start 2P's pixel `@`
  is the most extreme version of this.
- Abril Fatface's thin-stroke `@` nearly disappears at 30pt; Black Ops
  One's stencil `@` also muddies small.
- Strongest at app-bar size: Poppins, Rubik, Space Grotesk, Anton,
  Russo One, Titan One, Alfa Slab One.
- Anton is the closest "condensed poster" match to Bebas (w04) but with
  lowercase; Poppins/Rubik/Space Grotesk are the modern-geometric
  alternatives to Montserrat (w03).

## Rename scope (planning notes, not done)

Display-name only — keep `watchit` for every identifier:
- `widgets/brand_mark.dart` lockup text `watch-it` → `W@tch` (+ font asset
  if non-Roboto), BRAND.md wordmark section
- Android `android:label`, Linux window title, AppImage desktop-entry Name
- README / ROADMAP / release titles; repo rename optional
- Keep `@`-free names for: applicationId, package/crate names, artifact
  filenames (`%40` in URLs, shell escaping), keystore alias. Suggested
  artifact stem stays `Watch-It-…` or becomes `Watch-…`.
