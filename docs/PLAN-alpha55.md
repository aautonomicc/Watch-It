# Plan — next edition (v0.1.0-alpha.55) — "Publish edition"

Status: rev 4 2026-08-25 — WINDOWS TEST PASSED: user ran the fresh
2026-08-25 zip on a real Windows box, confirmed working → the Windows
release leg is UNGATED; Windows joins this and future desktop releases.
New section 6 (distribution: release mechanics, installer question,
desktop auto-update) added with recommendations — discussion pending.
Earlier: APPROVED scope, decisions recorded (see
"Decisions" below): internal wallet with seed-word backup + private-key
import, all tiers encoded by default with deselect checkboxes, ffmpeg
bundled, no macOS attempt this edition. Desktop-only releases (Windows +
Linux now, macOS when we get there); in-app upload from home PCs with
wallet integration and re-encode to quality tiers. The rev-1 scope-A
items (keyboard map, H/W-decode toggle, shortcuts sheet) are DEFERRED to
a later release — kept at the bottom.

## Headline: in-app upload ("Publish") from desktop

### 0. Research findings — EtchIt (etchit-io/etchit-desktop, checked 2026-08-25)

EtchIt is the closest prior art: same network, same problem (pay-per-upload
from a consumer app), desktop + Android, same brand family we already
mirror for styling. What their code shows:

**Wallet — two modes, both shipped:**
- **Internal wallet**: user pastes an EVM private key once; it's stored in
  the OS keychain (Rust `keyring` crate → libsecret / Windows Credential
  Manager / macOS Keychain — never a settings file). App derives the
  address and shows ANT + ETH balances on Arbitrum One
  (`https://arb1.arbitrum.io/rpc`). Their risk copy is specific and worth
  copying in spirit: *"Use a dedicated upload wallet, fund it small,
  treat it as hot."*
- **WalletConnect (Reown AppKit)**: external-signer flow. The app never
  sees the key; it displays a QR, the user's **mobile** wallet app
  (MetaMask mobile, Trust, Rainbow…) scans and signs. On desktop this is
  the only MetaMask path — a desktop app cannot talk to the MetaMask
  browser extension directly.
- **Trezor/Ledger: NOT integrated** — no direct hardware-wallet code
  anywhere in EtchIt. Hardware keys are reachable only indirectly
  (a WalletConnect wallet fronting the device). Their answer to key
  safety is the small dedicated hot wallet, not hardware signing.

**Payment mechanics (Arbitrum One):** upload cost is paid in ANT (ERC-20)
to a payment-vault contract. The signed legs are: ensure chain →
pre-flight ANT balance check (readable error *before* any signing) →
ERC-20 `approve` if allowance short → vault `payForQuotes(payments[])`
→ collect tx hashes.

**Upload flow (external signer)** — 4 steps, mirrored in their Android
`EtchSigner` and desktop TS: prepare (self-encrypt + collect quotes) →
approve ANT → pay vault → finalize (store chunks with tx-hash proofs).
They persist a **pending-finalize record** so a paid-but-crashed upload
can resume WITHOUT paying again — essential, payments are real money.

**Reusability caveat:** etchit-desktop is AGPL-3.0 (W@tch is MIT source /
GPLv3 binaries) — we take the architecture, not the code. Nothing needs
copying anyway, because:

### 1. The good news: our Rust core already has the whole upload API

watchit_core's pinned ant-core rev **81a0a24 (0.5.1)** — no bump needed —
already exposes:
- `file_upload(path)` — one-call upload with a client-configured wallet
  (internal-wallet path), plus `data_upload` for bytes
- `file_prepare_upload` → `PreparedUpload` (quotes + payments + total),
  then `finalize_upload(prepared, quote_hash→tx_hash map)` — the exact
  external-signer split EtchIt's fork added by hand; upstream has it now
- `estimate_upload_cost` — cost preview BEFORE paying
- `approve_token_spend`, `pay_for_storage`, batch/wave payment
- progress events (`UploadEvent::ChunkStored`) for a real progress bar

So the Rust work is wiring, not porting: new endpoints on the embedded
axum server (`POST /upload/estimate`, `POST /upload` with progress,
wallet config), not a new dependency.

### 2. Wallet plan for W@tch — phased

**Phase 1 (this edition): internal wallet — DECIDED 2026-08-25.**
Settings → new **Wallet** section with TWO ways in (one step further
than EtchIt, which is paste-key only):
- **Generate new wallet** (the recommended default): app creates a
  BIP-39 12-word seed phrase and derives the EVM key at the standard
  path m/44'/60'/0'/0/0 — the SAME derivation MetaMask/Trust use, so
  the seed words restore the wallet in any standard wallet app too.
  Backup flow: show the 12 words ONCE full-screen ("write these down —
  anyone with them controls the funds; we cannot recover them"),
  require a confirm step (re-pick 2–3 words) before the wallet
  activates. Only the derived private key goes to the OS keychain;
  the mnemonic is shown, confirmed, then NOT stored (user's paper is
  the backup) — nothing to steal from disk later.
- **Import existing wallet**: paste a raw private key (EtchIt-style
  Advanced copy + hot-wallet warning). Accepting a seed phrase here
  too is cheap (same BIP-39 code path) — do both.
Key stored via OS keychain (`keyring` crate in watchit_core → libsecret
/ Windows Credential Manager; NOT in SQLite/prefs), Settings shows
address + ANT/ETH balance on Arbitrum One, "how to fund" help text.
All signing stays in Rust — identical on Linux/Windows/macOS, no new
Flutter deps. Rust adds: `bip39` crate + BIP-32 derivation (e.g.
`coins-bip32` or alloy's signer-mnemonic — pick whichever meshes with
ant-core's existing evmlib wallet type).

**Phase 2 (later edition): WalletConnect for MetaMask.** Checked
2026-08-25: the official `reown_appkit` Flutter package is
**Android/iOS only — no desktop support**, so EtchIt's approach doesn't
drop in (their AppKit runs in Tauri's WebView; we have no WebView).
Desktop options to spike later: drive the WalletConnect sign protocol
from Dart/Rust directly and render our own pairing QR, or an embedded
localhost page. Real work either way → not this edition.

**Trezor/MetaMask expectation-setting:** even in phase 2, "MetaMask" on
desktop means *MetaMask mobile scans a QR*. Trezor only via such a
wallet. Recommendation to state in-app and in release notes: use a
dedicated small hot wallet for uploads (this is also what EtchIt tells
users).

### 3. Where the upload lives in the UI

- **Entry point:** library drawer (☰), new tile **"Publish"** between
  Media and Settings. "Publish" over "Upload" because Download/Downloads
  already exist as concepts one letter away, and publishing captures the
  permanence better. Alternatives if you prefer: "Upload", "Share to
  network".
- **Publish screen flow:** pick file(s) → probe (codec/resolution/
  bitrate via ffprobe) → quality-tier choice with per-tier size + ANT
  cost estimate (`estimate_upload_cost`) → permanence/rights
  confirmation → pay (wallet) → chunk-progress bar → result page:
  `.datamap` saved + "Add to library" + export-to-.watch-list offer.
- **Result plugs into the existing datamap-first model:** an upload IS
  a datamap; we store it in the mapstore, add the entry to a list, and
  the title is immediately playable/shareable like any import. No new
  entry type.
- **Wallet status** lives in Settings → Wallet (balance, key mgmt), not
  on the Publish screen (Publish just shows "balance: X ANT" and links
  there).
- **Permanence gate (important given our recent copyright cleanup):**
  the confirm step states uploads are permanent (no deletion on
  Autonomi) and paid, and requires ticking "I have the rights to
  publish this / it is public domain". Cheap to build, protects users.

### 4. Quality assessment + re-encode tiers (the "no media server" solver)

Since there is no server to transcode later, encode BEFORE upload:

- **Probe** with ffprobe (JSON): container, video codec, resolution,
  bitrate, HDR flags. Verdict shown in plain English ("1080p H.264,
  plays everywhere" / "4K HEVC 10-bit — many devices can't play this").
- **Tiers** (H.264 High + AAC in faststart MP4 — matches what we learned
  shipping NOTLD: H.264 8-bit is the only thing that plays everywhere):
  - **High** — 1080p, ~5 Mbps (≈2.2 GB/h)
  - **Medium** — 720p, ~2.5 Mbps (≈1.1 GB/h)
  - **Low** — 480p, ~1 Mbps (≈0.45 GB/h)
  - **As-is** — offered when the source is already H.264/AAC ≤1080p
    (no generation loss, no wait).
- **Tier selection — DECIDED 2026-08-25:** checkboxes, ALL applicable
  tiers checked by default (encode + upload every tier unless the user
  unticks some). "Applicable" = tiers at or below the source resolution
  (no upscaling: a 720p source offers Medium/Low/As-is, not High); As-is
  replaces the tier matching the source when the source is already
  H.264/AAC. The summed ANT cost across checked tiers shows before the
  confirm gate, so unticking is an informed cost decision.
- **Multi-tier uploads fit the app we already have:** same-title uploads
  already fold into ONE wall card with a version dropdown ("480p H.264 ·
  570 MB" / "1080p H.264 · 5.29 GB") since alpha.49. Publishing High +
  Low of one film produces exactly that UX for free. Output names follow
  docs/NAMING.md (`Title (Year) [720p].mp4`) so the picker labels come
  out right.
- **Cost preview per tier** before any wallet action: encoded size ×
  network quote via `estimate_upload_cost`. Each extra tier costs real
  ANT — the UI shows the sum before paying.
- **Encoder = ffmpeg CLI**, invoked as a subprocess with progress parsing
  (`-progress`). Not a Flutter package — desktop-only feature, CLI is
  the robust path. **Sourcing — DECIDED 2026-08-25: bundle static
  builds** (ffmpeg + ffprobe) in both the AppImage and the Windows zip
  (+~25–30 MB per platform; zero-setup, GPL fine since binaries are
  GPLv3 anyway). Sources: BtbN/FFmpeg-Builds (win64-gpl) for Windows,
  johnvansickle or BtbN static for Linux — pin exact versions + sha256
  in the build scripts.
- **Resumable finalize** (EtchIt's lesson): persist prepared-upload +
  payment state so a crash after payment resumes chunk storage without
  re-paying.

### 5. Release scope: desktop-only

- Artifacts: **Linux AppImage + Windows zip** (Windows gate CLEARED
  2026-08-25 — user tested the fresh zip built at HEAD fafbdfd on a real
  Windows box, confirmed working). No APK this release (nothing
  Android-relevant in it; skipping avoids implying upload works there).
- **macOS — DECIDED 2026-08-25: NOT attempted this edition.** Parked
  until after this ships (no Mac hardware to smoke-test; a macos.yml CI
  stretch remains the plan for a later edition — unsigned build,
  Gatekeeper friction, $99/yr Apple ID for proper signing).

### 6. Windows distribution + desktop auto-update (rev 4 — recommendations)

**How the Windows zip joins releases (mechanics — mostly settled):**
- Release process: trigger windows.yml (workflow_dispatch) on the
  version-bump commit → `gh run download` → verify contents + sha256 →
  rename `Watch-It-<version>-windows-x64.zip` → attach to the GitHub
  release beside the AppImage. Small improvement to land with alpha.55:
  add `push: tags: ['v*']` to windows.yml so tagging the release builds
  the zip automatically (keep workflow_dispatch for ad-hoc builds).
- Release notes get a standing Windows section: unzip anywhere, run
  watchit.exe; first run trips SmartScreen ("Windows protected your
  PC") because the binaries are unsigned — More info → Run anyway.
  Delete the folder to uninstall (data lives in %APPDATA%).

**Installer — recommendation: NOT yet; the portable zip IS the answer
for alpha:**
- The zip is the Windows analogue of the AppImage: no admin rights, no
  install step, delete to remove. Right fit for weekly-ish alphas.
- An installer would NOT reduce the real friction, which is SmartScreen:
  an unsigned Inno/MSIX installer gets flagged exactly like the unzipped
  exe. The actual fix is a code-signing certificate (OV ~$100+/yr, or
  Azure Trusted Signing ~$10/mo — both need identity validation) — not
  worth it at alpha user counts; revisit at beta/1.0.
- When one IS wanted later: **Inno Setup**, per-user install to
  %LOCALAPPDATA% (no admin), Start-menu shortcut + uninstaller +
  optional `.datamap`/`.watch-list` file associations (the one real UX
  win only an installer provides). MSIX is store-oriented and strict
  about signing — Inno is the pragmatic pick. An installer also pairs
  naturally with self-update (below) — decide the two together.

**Desktop auto-upgrade — recommendation: check-and-notify now, actual
self-update later:**
- **Phase 1 — update CHECK (small, proposed for this edition or the
  next):** on desktop, at most once per 24h on startup, GET
  `https://api.github.com/repos/aautonomicc/Watch-It/releases/latest`
  (unauthenticated; 60 req/h anonymous limit is plenty), compare the tag
  to the built-in version; if newer → quiet "Update available:
  v0.1.0-alpha.NN" snackbar + a badge/row in Settings → About linking
  the release page (per-OS asset link). Failures silent (offline = no
  nag). MUST have a Settings toggle ("Check for updates on startup") —
  this is the app's only phone-home besides the Autonomi network itself
  and the user's own TMDB key, so it stays visible and switchable;
  default ON, mentioned in release notes. Desktop-only for now (an APK
  can't self-serve an install anyway; extendable later).
- **Phase 2 — self-update (DEFERRED):** Linux = AppImageUpdate/zsync
  (needs update info embedded at build time + zsync file per release);
  Windows = a running exe cannot replace itself — needs a helper
  process or an installer handoff (ties into the Inno decision). Real
  work on both platforms for modest payoff while check-and-notify
  covers awareness. Not this edition.

## Suggested build order (each step lands with tests)

1. Rust: wallet config + keychain storage, `/wallet/info`,
   `/upload/estimate`, `/upload` with progress + resumable finalize
   (cargo tests against devnet where possible)
2. Flutter: Settings → Wallet section
3. Flutter: Publish screen (file pick → probe → tier choice → cost →
   confirm → progress → result), ffmpeg integration
4. Wire result into library/list + export
5. Release plumbing: desktop-only artifact set (+ Windows workflow
   fold-in per rev-1 item 1; macOS CI stretch)

This is likely too much for one edition — natural split point: ship
1+2 (wallet + a text-file/"any file" upload behind it) first, then the
encode pipeline. Or hold alpha.55 until the full Publish flow works.
Your call.

## Decisions (user, 2026-08-25)

1. **Wallet:** internal wallet ✓ — self-generated (BIP-39 seed words
   shown once for backup) AND import of an existing private key for
   users who don't want a generated one. MetaMask/WalletConnect stays
   phase 2.
2. **Tiers:** encode ALL applicable tiers by default; checkboxes to
   DESELECT tiers if desired.
3. **ffmpeg:** bundle it (static builds in AppImage + Windows zip).
4. **macOS:** do not attempt yet.
5. **Windows:** fresh Windows zip generated for user download + test
   (build at current HEAD incl. alpha.54 changes — supersedes the
   2026-08-11 zip).
6. **Windows CONFIRMED WORKING** (user test on real Windows,
   2026-08-25) — Windows zip joins this and future desktop releases;
   the alpha.55 Windows leg is ungated.

## Still open

1. **Name:** Publish vs Upload for the drawer entry? (Plan assumes
   "Publish" until said otherwise.)
2. **Split the edition?** Wallet+plain upload in alpha.55, encode tiers
   in alpha.56 — or one big release?
3. **Windows installer?** Recommendation: no — keep the portable zip
   through alpha; revisit (Inno Setup, per-user) at beta/1.0 together
   with code signing and self-update. (Section 6.)
4. **Update check-and-notify** (GitHub releases API, Settings toggle):
   include in alpha.55, or park for the next edition? Recommendation:
   yes if the edition doesn't split — it's ~a day of work; if the
   edition splits, it slots into the second half. Self-update proper is
   deferred either way. (Section 6.)

## DEFERRED to a later release (was rev-1 scope A)

- Desktop keyboard map + `?` shortcuts help sheet
- H/W-decoding toggle + pre-first-frame error grace (old Mint report)
- Hover thumbnails on seek bar (was already stretch-deferred)

## Maintenance / explicitly NOT this edition

- ant-core bump: upstream is still on 0.3.4-beta/rc pre-releases; the
  pinned 0.5.1 (81a0a24) already has everything the upload needs — stay.
- media_kit #1404 still OPEN — vendored media_kit_video patch stays.
- Android/iOS upload — desktop-only by decision.

## Standing user actions (outside the release, reminders)

- Rotate the old TMDB key (extractable from alpha.24–.33 binaries).
- GitHub Support sensitive-data request still unsubmitted
  (~/projects/watchit-github-support-request.md).

## Release checklist (desktop-only variant)

analyze + full test suites (Dart + cargo) → version bump →
watchit-build unit (AppImage; skip/keep APK per decision above) →
Windows workflow_dispatch on bump commit + `gh run download` →
clean-HOME Xvfb AppImage smoke incl. a devnet or small live upload →
`gh release create` (AppImage + Windows zip) → CLAUDE.md/ROADMAP.md.
