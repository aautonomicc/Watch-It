# Add to W@tch — intake

Add to W@tch (home toolbar button, and a tile on the My Media page) is the
intake desk for media that is **not on the network yet**. It works on laptop
and phone; the TV layout keeps its watch-only surface. Kid profiles do not
see it — adding media is an adult action, the same law as editing credits.

## The flow

1. **Choose**: pick media files from this device, or paste a source link.
   On desktop the picked file's path is kept; on a phone the picker hands
   out cache copies that vanish, so the draft records the name and size
   only and says to upload from a laptop.
2. **Review**: one card per item — title (required), creator, original
   source URL (required for links), language, collection, and optional
   artwork picked and cropped like Edit details artwork. Advanced details
   (source title, licence name/URL, attribution, changes) are collapsed.
   The fields reuse the creator-credits model (`MediaCredits`); the
   card's URL field is the single provenance authority.
3. **Save on this device**: drafts persist in the local database
   (schema 15, `intake_drafts`). Saving performs no network call, no
   payment and no publish. Edits survive back, reopen and restart.

## What a draft is — and is not

- A **link draft** is a reference record. W@tch never downloads from
  links; no YouTube downloader or transcription is added.
- A **file draft** remembers a local file and its details. It has **no
  Autonomi address**: it is not a library entry, never playable on TV,
  and never marked as available.
- Drafts are device-local and not synced. Other devices see media only
  after a real upload plus a `.watch-list` transfer (or a channel
  publication — a separate, public step; uploads themselves stay
  private to you and your linked devices).

## Upload handoff

A file draft on desktop offers *Upload this file…*, which opens the
existing batch upload flow with the path and collection pre-filled.
Everything about price quotes, permanence, wallet approval, resume and
dedup stays inside that flow, unchanged. When an upload really
succeeds, the draft's credits are re-keyed onto each resulting file
address (tier encodes produce several addresses for one source; all
carry the same credits) with gap-fill semantics — a local record at
that address always wins — and the draft is consumed. Failed or partial
uploads leave the draft in place.

## Limits

- Android Share/`SEND` intake is not wired: there is no existing
  receive route to reuse, so it is pending rather than bolted on.
- Desktop drag-and-drop onto the window is pending (the picker covers
  files and folders today).
- Credits live sync (`My W@tch`) does not cover drafts or the credits
  table; `.watch-list` bundles remain the transfer route.
- Draft artwork seeds nothing until ingestion; it is displayed on the
  card/rows only.
