# Plan: Personal media (My W@tch) vs public Channels

**Status: PLAN ONLY (2026-08-27). Nothing implemented.** Defines the two
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
  OS keychain beside the wallet key.
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

## Suggested build order

1. **Rename release** (Part 1, small): Publish→Upload + copy + docs.
   Ships alone so the vocabulary is settled *before* Channels lands.
2. **Channels core**: identity + manifest + public upload + x0x head topic
   + subscribe/import + auto-update. Desktop publish, all-platform
   subscribe.
3. **Safety rails**: attestation, first-publish ceremony, terms v2, badges
   (ships in the same release as 2 — core never ships without rails).
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
