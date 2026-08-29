# Plan — Channel profile: avatar, name, author

Status: **PLANNED 2026-08-29 — not implemented.** Follows the "Later: channel avatars"
item in PLAN-personal-vs-channels.md. Read that plan first; nothing here weakens its
safety rails — it extends them to two new public facts (avatar, author).

Rev 2 (2026-08-29): animated GIF support **dropped** (user: would look cheap and
tacky) — avatars are still images only; added the explicit "Keeping the profile up
to date" section (§2a).

## Goal

A channel gets a face. When creating (or later editing) a channel the owner sets:

- **Avatar** — a still image (no animation — considered and dropped, it would read
  cheap next to the poster wall). Rendered **circular** everywhere.
- **Channel name** — already exists (≤80 chars).
- **Author** — a display name *or* handle for whoever runs the channel (one free-text
  field, ≤80 chars, e.g. `Neil` or `@neil`). Shown as "by <author>".
- **Description** — already exists (≤500 chars).

Subscribers see all of it, kept current by the normal head/manifest update flow.

## 1. Data model

### channel.json (stays `version: 1` — additive, old clients ignore unknown keys)

```json
{
  "version": 1,
  "name": "...", "description": "...", "pubkey": "...",
  "seq": 4, "previous": "...", "updated_at_ms": 0,
  "author": "Neil",                                   // NEW, optional
  "avatar": "channel_avatar_<sha256-8>.img"           // NEW, optional; zip member name
}
```

### Avatar bytes in the manifest zip

Ride the existing poster machinery: the avatar is one more `posters/` member, written
with the posters at the **end** of the bundle, named by content hash:
`posters/channel_avatar_<first-8-hex-of-sha256>.img` (the bytes are the 1:1 crop
output — jpg; Flutter decodes by content, not extension).

Why this placement wins, for free:

- **Delta-aware updates** — channel_manifest_delta.dart already skips `posters/`
  members whose file exists on disk. Unchanged avatar → never re-downloaded.
  Changed avatar → new hash → new member name → fetched. Zero delta-code changes.
- **Import/storage** — seedBundle already lands `posters/` members in the posters dir
  with existing-file-wins gap-fill. Content-hash naming makes that correct (a new
  avatar is a new file, never blocked by the old one).
- **Old clients** — they store an unused small file in the posters dir. Harmless.

Constraints: accept jpg/png/webp (a picked gif is fine too — the crop flattens it to
its first frame, by design); **hard cap 2 MB** on the crop output (it's in every
subscriber's manifest fetch and the owner pays to upload it); recommend square ≥256px
in the picker copy. Every avatar goes through the existing crop dialog forced to
**1:1**, so the stored bytes are always square and the circle render never surprises.

### Rust — OwnConfig (channels.rs)

- `OwnConfig` gains `author: String` (≤80, same cap style as name). Avatar bytes are
  Dart-side only (Dart builds the manifest); the owner's current avatar file lives in
  app-support next to other channel state, path persisted in Dart prefs — Rust never
  sees the image.
- `create(name, description, phrase)` → `+ author`; `set_meta(name, description)` →
  `+ author`. `/channel/create` and `/channel/meta` routes pass it through.
- **Restore path**: after `restore()` the app already recovers name/description from
  the fetched manifest via `set_meta` — extend to author, and copy the avatar member
  from the fetched manifest back into place, so a restored channel republishes with
  its face intact.

### Dart — build / parse / persist

- `buildMyManifest()` (channel_service.dart): write `author` + `avatar` into
  channel.json; hand the avatar file to `buildBundle` as an extra poster member.
- `ChannelManifestInfo` + `parseChannelManifestMembers()`: read the two new optional
  fields.
- **DB (drift, schema v11)**: `media_lists` gains `channelAuthor` (text, nullable) and
  `channelAvatar` (text, nullable — poster member name; resolve to the posters dir at
  render time). Subscription import updates both on every accepted head, same as the
  name/description refresh today.

## 2. Create ceremony (channels_screen.dart)

Order unchanged: **form → 12-word backup → retype-3 → typed-name gate → first publish.**

The create form becomes the channel profile form:

- Circular avatar picker at the top — 96px circle, amber 1px ring, camera overlay
  icon; empty state is the podcasts icon in a dim circle. Optional but encouraged.
- Channel name (required, as today).
- **Author name or handle** (required — public attribution is the point; helper text:
  *"Shown as 'by <author>' on your channel. Public and permanent."*).
- Description (optional, as today).

Safety-wall additions (per the personal-vs-channels philosophy):

- The `FirstPublishGateScreen` warning list gains a line: *"Your channel name, author
  name and avatar are published publicly and permanently alongside everything in the
  channel."*
- **No handle registry, no uniqueness, no verification.** The author field is free
  text; anyone can type `@neil`. The `wchn1-…` code remains the only real identity —
  which is why the info card (below) always shows the code. State this plainly in
  UI-DESIGN.md when implementing.

## 2a. Keeping the profile up to date (yes — it rides every publish)

The whole profile is **mutable by construction**: it lives in the manifest
(channel.json fields + the avatar member), and the manifest is rebuilt and republished
with every head. So updating the avatar, author, name or description needs **no new
mechanism** — it's the same flow that updates the channel's items:

- "My Channel" gains *Edit channel details* (avatar / name / author / description).
  Edits are staged locally, exactly like staged items.
- The **next publish** (whether triggered by the edit alone or bundled with new items)
  writes the current profile into channel.json, packs the current avatar member, signs
  a new head. Subscribers' 5-min head-follow loop imports it and refreshes
  name/description/author/avatar on the list — same as the name/description refresh
  that ships today.
- **Cost**: a changed avatar is a new content-hash member → fetched by subscribers and
  paid for once by the owner (≤2 MB). An *unchanged* avatar keeps its hash → the
  delta fetch skips it entirely and re-publishing held chunks is free (dedup). So a
  profile-text-only update costs roughly one small manifest, nothing per subscriber
  beyond the changed ranges.
- A profile-only edit with no new items is a legitimate publish: seq bumps, items
  unchanged. The cost-preview dialog covers it like any other publish.
- **Caveat to state in the UI**: old manifests are content-addressed and permanent —
  updating the avatar doesn't erase the previous one from the network, it only stops
  being referenced. The FirstPublishGate wording ("public and permanent") already
  covers this; the edit screen repeats it in one line.

## 3. Display surfaces

### 3a. Channel info card — first thing on a channel's list page (the headline change)

`ListHomeScreen`, when `isChannel`: a **full-width profile card above the poster
grid** — adapting the "first card in the list" idea, because grid cells are 2:3
poster-shaped and a profile crammed into one would fight the grid. Full-width header,
`ink2` background, 1px `line` border, radius 6 (poster-card conventions):

```
┌──────────────────────────────────────────────────────┐
│  ◯ 72px avatar   Channel Name            [CHANNEL]   │
│                  by Author · 34 entries              │
│                  Description, 2 lines, "more" expand │
│                  wchn1-abc…xyz  [copy]               │
└──────────────────────────────────────────────────────┘
```

- Avatar: `ClipOval` + `Image.file`, `BoxFit.cover` (first circular artwork in the
  app — note it in UI-DESIGN.md as *the* channel-avatar idiom: circles mean channel
  identity, rectangles mean media). Fallback: podcasts icon on amber-tinted circle.
- Name in `bone` 18px; "by author · N entries" in `ash`; amber `ChannelBadge` top-right.
- The code line is deliberate anti-impersonation UI: mono font, amber, tap-to-copy —
  matching how the code is shown in the QR dialog today.
- The AppBar entry-count subtitle can drop for channels (the card owns it).
- Own channel viewing its own list gets the same card plus an *Edit* pencil.

### 3b. Everywhere else — consistent mini-avatar, icon fallback

- **Channels screen cards** (Subscribed + My Channel): leading `Icons.podcasts` →
  40px circular avatar (podcasts-icon fallback); subtitle gains "by <author>".
- **Add-channel confirm**: after the manifest fetch, the confirm dialog shows avatar +
  name + "by author" + code, so you see who you're subscribing to *before* the list
  lands.
- **Drawer**: channel rows swap the amber podcasts icon for a 20px mini avatar
  (fallback keeps the icon). Same on the Media page row list.
- **Home wall**: channel row titles get an 18px avatar beside the existing
  `ChannelBadge`. Smallest surface — cut this one first if it looks busy.

## 4. Compatibility & cost

- Old client reads new manifest: unknown channel.json keys ignored, avatar file inert
  in posters dir → today's rendering, nothing breaks.
- New client reads old manifest: fields absent → icon fallback + no author line.
- Cost: ≤2 MB once per avatar change, skipped by delta fetch when unchanged. Live
  quote in the publish cost preview already covers it (bundle got bigger, that's all).

## 5. Build order (single release, ~4 stages)

1. **Rust**: `OwnConfig.author`, `create`/`set_meta`/routes, restore recovers author.
   Cargo tests for caps + round-trip.
2. **Dart data**: channel.json build/parse, avatar-as-poster member, drift v11
   columns + import refresh, restore copies avatar back. Unit tests incl. a
   delta-fetch test proving an unchanged avatar isn't re-fetched.
3. **Dart UI**: profile form (picker + forced 1:1 crop + 2MB gate), gate wording,
   info card, channels-screen / dialog / drawer / home-wall avatars, edit screen.
   Widget tests.
4. **Live verify** (Xvfb + devserver): create ceremony with a real avatar → publish →
   subscribe from devserver → info card renders avatar + author → **edit the profile
   (new avatar + new author) → republish → subscriber refreshes both and the delta
   skips the unchanged posters** (this leg proves §2a end to end). Then docs
   (UI-DESIGN §9, BUNDLE-FORMAT, ARCHITECTURE, this file → IMPLEMENTED).

## Open questions (defaults chosen, say if you want different)

1. Author **required** at create (default) or optional?
2. Home-wall mini avatar: in (default) or out?

Resolved: animated GIFs — dropped (rev 2, user call: cheap and tacky). Profile
updates on republish — confirmed in, see §2a.
