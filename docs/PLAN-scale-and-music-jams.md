# Plan: long-horizon scale and Music Jams

This lane extends the W@tch and Buzz design to very large populations and
long-lived cultural archives. The target is a system that can represent
10-billion-user populations and century-scale history without making every
peer replicate every object or requiring a global index.

## Invariants

- Autonomi stores immutable, content-addressed media, captions, translations,
  stems, artwork, and encrypted private payloads.
- x0x/Buzz carries identity, membership, presence, subscriptions, and small
  live announcements. It never becomes the archive.
- A channel head is signed and bounded. Long histories rotate into
  epoch-segmented manifests with signed checkpoints and hash links.
- Clients keep local indexes and bounded caches. No client operation requires
  enumerating all users, channels, or media.
- Public publication is deliberate and attributable. Private drafts and
  linked-device libraries remain separate from public channels.
- Payment, quotas, and rate limits are explicit protocol inputs. Wallet UI
  cannot silently turn a private draft into a paid public upload.

## Build sequence

1. **Segmented data model:** define stable channel, epoch, segment, and item
   identifiers; make late joiners recover from the newest checkpoint plus a
   bounded delta.
2. **Deterministic routing:** shard announcements by channel and epoch; keep
   fanout proportional to subscribers of that shard rather than the entire
   network.
3. **Durability and recovery:** add signed snapshots, replay detection,
   idempotent writes, corruption checks, and restart recovery for writers and
   subscribers.
4. **Identity and cryptography:** version envelopes, rotate channel and device
   keys, support algorithm migration, and preserve creator/source/licence
   records across migrations.
5. **Economic guardrails:** meter storage, bandwidth, and fanout; enforce
   per-identity and per-channel quotas; batch payments where possible; keep
   Trezor as an external signer for physical approval.
6. **Scale validation:** run property tests and workload simulations with
   synthetic users, channels, subscribers, media sizes, and long histories.
   Measure recovery time, hot-shard behavior, write amplification, and cost.

## Music Jams as the stress case

A Music Jam uses the same primitives at a higher event rate:

- live room membership, reactions, and short notifications stay on x0x;
- the recording, stems, captions, dubbed audio, artwork, and session notes
  enter Autonomi as separate content-addressed artifacts;
- a signed session manifest ties those artifacts to performers, engineers,
  venues, timestamps, source links, and licence or permission records;
- private rehearsal material can remain device or member-only, while an
  intentional public release becomes a channel update;
- a late listener can fetch the latest checkpoint and selected versions
  without replaying every live event from the beginning.

## Acceptance criteria

The first implementation is ready when one channel can rotate its manifest
without breaking subscribers, a late joiner can recover from a checkpoint,
duplicate announcements are harmless, and a busy Music Jam does not require
global peer fanout. Every published artifact must retain its creator,
original source, licence state, and version history.
