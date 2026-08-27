# Plan: Personal media (My W@tch) vs public Channels

**Status: IMPLEMENTED (2026-08-27).** Part 1 (the Publish→Upload rename)
shipped as alpha.64. Parts 2–3 (Channels core + safety rails) are
implemented together on main: Ed25519 channel identity from its own
12-word phrase (SLIP-0010, wallet-style ceremony), signed manifests
uploaded publicly (`file_upload_public_with_progress`), head records
gossiped on an x0x topic derived from the channel pubkey, subscribe →
read-only auto-updating amber-badged channel lists, Describe-this-item
+ per-item attestation + first-publish typed-name gate + cost preview,
Terms v2. Implementation deviations from the plan text: the owner's
signature covers the HEAD record (seq + manifest address) rather than a
`channel.sig` member inside the zip — content addressing makes the two
equivalent (the address IS the manifest hash) with much less zip
machinery; `channel.json` carries advisory seq/previous for the history
chain. The Describe-this-item category dropdown was dropped — category
derives from the file name (SxxEyy = episode) exactly like everywhere
else in the app. User agreed to all open questions' recommendations
(separate channel phrase, no directory in v1, subscribe everywhere,
cost preview, Part 4 menu layout). Defines the two
content spaces, how each works technically, and the naming/safety wall
between them so nobody publishes copyrighted material publicly by accident.

## The two spaces

| | Personal — **My W@tch** | Public — **Channels** |
|---|---|---|
| Who can watch | You + your linked devices (+ anyone you hand a bundle) | Anyone holding the channel code |
| Upload visibility | `Visibility::Private` — datamap never on the network | `Visibility::Public` — datamap stored as a chunk, discoverable |
| Reversible? | Chunks are unlinkable noise without the map | **Irrevocable, forever** |
| Word used in UI | "Upload" / "Add" | "Publish" — reserved exclusively for this |
| Status today | **Essentially shipped** | New feature |

### Key insight: the private half already exists

Today's Publish feature (alpha.55+) uploads with
`file_upload_with_progress` → `Visibility::Private` (verified in ant-core
81a0a24 `client/file.rs`): chunks go on the network, the root datamap stays
local in the mapstore. My W@tch sync then carries the shrunk map to linked
devices, so "upload on desktop, watch on phone" works now. What's missing is
not machinery but **framing**: the feature is named "Publish", which sounds
public and collides head-on with the future genuinely-public feature.

## Part 1 — Personal space: rename + gather under the My W@tch brand

1. **Rename Publish → "Upload"** (drawer tile, screen title, done-page
   copy). Screen subtitle: *"Private: only you and your linked devices can
   watch. Nothing is published."* The word "publish" disappears from this
   flow entirely.
2. **My W@tch becomes the umbrella brand** for the personal space: your
   library, your uploads, your linked devices. The Settings → Network
   "My W@tch" section stays the sync control panel; docs/README pitch
   "My W@tch = your private media, everywhere you are".
3. Later (not this cycle): mobile upload (needs wallet on Android — keyring
   backend + key-security review), sync-while-apart (standing ROADMAP item).

Cost: a day of renames + copy + docs; no protocol changes; tests are
string-level updates.

## Part 2 — Public space: Channels

A **channel** is a signed, updatable, publicly-fetchable list of media —
"a YouTube channel" — created and updated only by its owner, subscribable
by anyone with the channel code.

### Data design (Chunk-only network — verified: current ant-core has no
Pointer/Scratchpad/Register; chunks + datamaps are all we get)

- **Channel identity**: an Ed25519 keypair generated at "Create channel".
  Channel code `wchn1-<base32(pubkey)>` (distinct prefix from `wtch1-`
  invites on purpose — visually different kind of thing). Secret key in the
  OS keychain beside the wallet key. Derived from its own 12-word phrase —
  see "Channel master key backup" below; backup is part of creation, not
  an afterthought.
- **Channel manifest**: a `.watch-list`-style zip (bundle spec v2 reused:
  `datamaps/`, `list.txt`, `metadata.json`, `posters/`) plus
  `channel.json` — name, description, pubkey, sequence number, previous
  manifest address (history chain), created/updated timestamps — and
  `channel.sig`, the owner's signature over the manifest content. Uploaded
  **publicly** to Autonomi; its address is fetchable by anyone
  (`data_map_fetch` — the public path the app deleted for *entries* in
  alpha.41 returns here for *manifests only*, which are public by intent).
- **Head distribution** (the mutability layer): an x0x gossip topic derived
  from the channel pubkey — same shipped machinery as My W@tch, but the
  topic key is *public* (anyone with the code derives it). The owner
  publishes a signed head record `{seq, manifest_address, sig}` into the
  topic's CRDT KV store; subscribers replicate it, so late joiners get the
  newest head from **any online subscriber** — the owner does not need to
  stay online (same snapshot property My W@tch relies on). App layer
  ignores any record not signed by the channel key (self-keyed store means
  strangers can write their own keys; unsigned junk is filtered).
- **Subscriber side**: "Add channel" (paste/scan code) → fetch head →
  fetch manifest → verify signature + hash chain → import as a **channel
  list**: a new read-only list kind, badged with the channel name, that
  auto-updates when a newer signed head arrives. Entries stream/download
  exactly like today (the manifest carries root datamaps).
- **Publishing an existing private upload to a channel is cheap**:
  self-encryption is deterministic, so the chunks are already stored — the
  incremental cost is the public datamap chunk + the manifest upload. This
  makes "upload privately first, decide to publish later" the natural and
  safe default order.
- **Update cost**: each channel update = one manifest upload (small; ANT
  from the existing wallet). Deletion is impossible — removing an entry
  from the manifest only stops *new* subscribers seeing it.

### Channel master key backup — REQUIRED, part of channel creation

Losing the channel secret key is worse than losing the wallet key:

- The channel code **is** the pubkey. No secret key → no signed head → the
  channel is **frozen forever** at its last manifest. There is no recovery,
  no re-issue: a replacement channel is a new code every subscriber must
  manually re-add.
- A **leaked** key is worse still: anyone holding it publishes as you,
  publicly and irrevocably, and there is no revocation mechanism.

Plan (reuses the shipped wallet machinery wholesale):

1. **The channel key is generated from its own 12-word BIP-39 phrase**
   (Ed25519 via SLIP-0010 from the seed). "Create channel" runs the exact
   full-screen ceremony Publish's wallet already ships (show words →
   retype 3 words → only then persist) — so by the time a channel exists,
   its backup exists. Restoring on a new machine = "Restore channel" →
   type phrase → same keypair, same code, publishing resumes.
2. **Deliberately a separate phrase from the wallet phrase.** The wallet is
   a disposable hot wallet (rotate/abandon at will, holds funds); the
   channel key must live as long as the channel and holds *identity*.
   Tying them means one leak/rotation drags the other down. Two phrases,
   each labelled clearly ("this restores your channel, not your money" and
   vice versa).
3. My Channel screen shows a **backup status row** ("Recovery phrase backed
   up ✓ / Show recovery phrase" behind a confirm), mirroring wallet UX.
4. Secret stored in the OS keychain (file fallback 0600, same as wallet.rs
   today); the phrase itself is never stored — display-once + re-derive.

### Metadata for channel content — fresh content is NOT in TMDB

Self-made media has no TMDB entry, so a channel manifest must be
**self-describing**: title, description, artwork, category all travel in
the manifest or subscribers see bare filenames. Nearly all machinery
exists:

- The manifest reuses bundle spec v2, which already carries
  `metadata.json` rows + `posters/` files, and bundle import already
  gap-fills the receiver's metadata cache and posters dir (shipped:
  seed catalog, .watch-list import, alpha.57 `userEdited` rows).
- Rows travel flagged `userEdited: true`, so the receiver's TMDB matcher
  never queries for or overwrites them (shipped semantics: a found cache
  row short-circuits the fetch). Keyless receivers render fully offline.

What's new is a **required metadata step in the add-to-channel flow**,
*before* the rights attestation:

1. Pick the item (from your uploads) → **"Describe this item"** page:
   title, year (optional), description, category (Movie / Show episode /
   Other), artwork. All prefilled from local metadata when present (user
   edits, or a TMDB match for the rare case the content is indexed).
2. Artwork comes from the shipped Edit-details pickers: image file, or
   the video-frame picker + poster crop (alpha.57/.59) — for self-made
   video, "grab a frame" is the natural poster source.
3. **Title, description, and artwork are required** — the Add button stays
   disabled until present. Rationale shown inline: "Subscribers only see
   what you write here — fresh content is not in any database."
4. Saving also writes the same rows locally as a normal Edit-details save,
   so the publisher's own library and the channel stay consistent, and a
   later manifest rebuild re-exports them unchanged.
5. Editing an item's details later = normal Edit details + "Update
   channel" (new manifest, one small upload). Old manifest stays fetchable
   (permanence), but subscribers follow the newest signed head.

Episode support: SxxEyy in the file name + per-episode rows fold into the
existing show/season grouping on the subscriber side for free.

### v1 scope cuts

- **No global directory / search.** Channels spread by code only (link, QR,
  message). This is both simpler and the single biggest liability reducer:
  the app is a player, not a public bulletin board. A curated directory can
  come later as a separate repo/site with its own vetting + de-listing
  process (de-listing ≠ deletion; say so there too).
- No comments, no subscriber counts, no monetization, no multi-owner
  channels, no mobile channel *creation* (subscribe works everywhere;
  publishing needs the desktop wallet anyway).

## Part 3 — The safety wall (naming + friction + terms)

The danger: someone puts their movie rip collection in a channel thinking
it's "sharing my library", and it's public, attributable, and permanent.

1. **Vocabulary is the first wall.** "Upload" always private; "Publish"
   always public; the UI never uses one where the other applies. Channel
   surfaces get a distinct accent (e.g. amber) + a "PUBLIC" badge; personal
   surfaces stay blue. The words "private" / "public · permanent" appear on
   the respective action buttons themselves.
2. **Separate doors.** Channel publishing is its own screen reached only
   via My Channel — never a checkbox/toggle on the Upload flow. No bulk
   "publish my library". Items enter a channel one explicit pick at a time.
3. **Per-item attestation, stronger than today's Publish checkbox:**
   *"I created this content myself, or I hold the rights to distribute it
   publicly. I understand it will be public and permanent and can never be
   deleted from the network."* — required per item added to a channel.
4. **First-publish gate:** creating a channel or first publishing shows a
   dedicated full-screen warning (mirrors the wallet ceremony pattern):
   public, permanent, attributable to your channel key, you are the
   publisher legally. Confirm by typing the channel name.
5. **Terms bump** (`kTermsVersion` 1 → 2, existing re-prompt machinery):
   new section for channel publishing — publisher's sole responsibility,
   prohibited-content restatement, irrevocability, the app neither hosts
   nor indexes channels. (Dev-written, still not lawyer-reviewed — flag as
   such.)
6. **Subscriber-side note** on Add channel: content comes from the channel
   owner, not from Watch-It; standing prohibited-use terms apply to what
   you re-share.
7. **What we deliberately can't do:** no server-side moderation (there is
   no server), no takedown (Autonomi is permanent). The stance is the
   existing Terms stance — client-only, user responsibility — with the
   friction above making the public/private line impossible to miss.

## Part 4 — Proposed menu layout

Principle: the two **actions** (Upload, Channels) are top-level drawer
doors with opposite color coding; everything configurational lives under
Settings. Subscribed channel *content* is not a separate silo — it lands
on the normal home wall / drawer as badged read-only lists, because
subscribers just want to watch.

```
Home (poster wall — channel lists appear as rows like any list,
 │                   amber "CHANNEL" badge on the row header)
 └ drawer
    ├ [your lists…]                     (as today)
    ├ [subscribed channels…]            amber dot + channel name, read-only
    ├ ──────────
    ├ Media                             (as today; import/export/lists)
    ├ Upload                            ← renamed from Publish. Blue icon,
    │                                     subtitle "Private · only your
    │                                     devices". Flow unchanged.
    ├ Channels                          ← NEW, amber icon
    └ Settings

Channels screen (two segments, mirroring "My lists | Auto" pattern):
    ├ Subscribed                        default segment
    │    ├ channel cards: name, description, item count, updated X ago,
    │    │   auto-update state; tap → channel list page; long-press/menu →
    │    │   Unsubscribe
    │    └ [+ Add channel]              paste wchn1- code / scan QR
    └ My Channel
         ├ (none yet) → "Create channel" + "Restore channel"
         │     Create = name/description → key ceremony (Part 2 backup)
         │     → first-publish warning ceremony (Part 3)
         ├ (exists) → channel name + code + QR ("share this code")
         ├ items list (what subscribers see, manifest order)
         ├ [+ Publish an item] → pick from uploads → Describe this item
         │     (required metadata, Part 2) → rights attestation (Part 3)
         │     → cost preview → publish (new signed manifest + head)
         ├ "Update channel" appears when local items/details changed
         └ Recovery phrase backed up ✓ / Show recovery phrase

Settings
    ├ Home screen                       (as today; channel rows hideable
    │                                    like any list)
    ├ Media                             (as today)
    ├ Metadata                          (as today — TMDB key; note: channel
    │                                    content never queries TMDB)
    ├ Downloads                         (as today; channel entries download
    │                                    like any entry)
    ├ Network
    │    └ My W@tch                     (device sync — unchanged, stays
    │                                    the private-space control panel)
    ├ Wallet                            ← section renamed from PUBLISHING
    │                                    (one wallet funds both Upload and
    │                                    channel manifest updates)
    └ About                             (Terms v2 lives here as today)
```

Deliberate choices:

- **Upload and Channels are separate drawer tiles**, never one screen with
  a mode switch — the "separate doors" wall from Part 3. Upload keeps blue
  everywhere; every Channels surface is amber + "PUBLIC" badged.
- **My Channel lives inside Channels, not Settings** — publishing is an
  activity, not a setting; and the ceremony/attestation gates sit on its
  entry paths.
- **Settings → PUBLISHING renames to Wallet** once "Publish" (the feature
  name) becomes "Upload": the section only ever held the wallet, which now
  serves both spaces.
- Mobile: Channels tile shows Subscribed only (channel *creation* is
  desktop-only in v1, like Upload); Add channel + QR scan work everywhere.

## Suggested build order

1. **Rename release** (Part 1, small): Publish→Upload + copy + docs.
   Ships alone so the vocabulary is settled *before* Channels lands.
2. **Channels core**: identity + key-phrase ceremony/restore + manifest +
   public upload + x0x head topic + subscribe/import + auto-update.
   Desktop publish, all-platform subscribe. Menu layout per Part 4.
3. **Safety rails + metadata step**: attestation, first-publish ceremony,
   the required Describe-this-item page, terms v2, badges (ships in the
   same release as 2 — core never ships without rails).
4. Later: directory (separate repo), mobile publish, channel avatars,
   multi-quality per channel entry (version-picker already folds them).

## Open questions (user)

1. Names: "Upload" for the private flow, "Channels"/"My Channel" for the
   public one — agreed? (Alternatives considered: "Broadcast", "W@tch
   Public"; "Channels" matches the user's own YouTube framing.)
2. v1 with no directory (code-only sharing) — agreed?
3. Subscribe on Android/iOS in v1, or desktop-everything first?
4. Should a channel publish require a minimum wallet balance check + cost
   preview per update (recommend yes, reuse /upload/estimate)?
5. Channel key backup: separate 12-word phrase (recommended, Part 2
   rationale) vs deriving it from the wallet phrase (one backup covers
   both, but couples identity to a disposable hot wallet) — agreed on
   separate?
6. Menu layout in Part 4 (Upload + Channels as sibling drawer tiles,
   My Channel inside Channels, PUBLISHING → Wallet rename) — agreed?
