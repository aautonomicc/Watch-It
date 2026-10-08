# Plan: encrypt the My W@tch link store (seal every value under a link-secret-derived key)

**Status: IMPLEMENTED 2026-10-07 (released in v0.1.0-alpha.111),
as planned, with both open-question recommendations adopted (invite
prefix bumped to `wtch2-`, PIN stretching deferred). One deliberate
addition beyond the plan text: the Dart QR scanner still *accepts* old
`wtch1-`/`wtchp1-` codes so the core's specific "update that device
first" rejection reaches the user instead of the scanner silently
ignoring the code. Release notes must say: update every linked device
together.**
Fixes the one real finding of the 2026-10-07 leak-vector review: the
My W@tch sync store is **plaintext on the gossip layer**, and since the
phase-2 backup feature it also carries the backup read keys (pointer
address + the real ChaCha20-Poly1305 content key for the entire backup
line).

## 1. The problem (what leaks today, and to whom)

Everything the link publishes goes into an x0x **SelfKeyed** CRDT KV
store whose values are raw JSON:

- `<agent>/sync` + `<agent>/sync/N` — the sync document: the whole
  library (titles, entries), watch positions, profiles **including PIN
  hashes** (single salted SHA-256 over a 4–6 digit PIN → instant
  offline brute-force), kid allow-lists, user edits, TMDB rows, and
  since phase 2 the `backup` section `{ptr, key}` — the real content
  key that decrypts every past and future backup (keys never rotate by
  design).
- `<agent>/maps/N` — **shrunk data maps = playable decryption keys**
  for every entry.
- `<agent>` (bare key) — the device record: name, platform, counts,
  heartbeat.

x0x's SelfKeyed policy serializes deltas as plain bincode (only
TreeKEM/Encrypted/GroupSigned stores seal), the pub/sub envelope is
signed but NOT encrypted and carries the full topic string in the
clear, full-mode relay nodes pass envelopes through for topics they
aren't subscribed to, and any topic-holder can pull **full state** via
the `<topic>/state-sync` side topic. The only protections are
topic-name secrecy (blake3 of the link secret — unguessable, but
printed in every relayed envelope) and hop-by-hop QUIC.

So a payload-capturing relay/bootstrap node, or anyone who harvests the
topic string, reads everything above. Write-side corollary: a
topic-holder can also **inject** signed records of their own into the
merge (planted entries, profile tombstones) — x0x #1114 only drops
*unsigned* payloads.

The code anticipated the fix: `topic_for`'s doc comment
(mywatch.rs ~1693) says *"a future encrypted payload could key itself
from the same secret independently."* This plan is that payload.

## 2. Design

### 2.1 Key derivation

```
store_key_bytes = blake3::derive_key("watchit.mywatch.store.v1",
                                     &hex::decode(secret_hex))
```

One symmetric ChaCha20-Poly1305 key per link, derived from the 32-byte
link secret — the same secret the invite/pairing already treats as the
crown jewels, so **no new secret to distribute**: every device that can
join the link can derive the key; nobody else can. Domain-separated
from the topic derivation (`"watchit mywatch v1 topic"`) and from the
pairing seal, exactly as the comment anticipated.

### 2.2 Sealed value format

```
value = b"wenc1" ‖ nonce(12 random bytes) ‖ ChaCha20-Poly1305(
            key  = store key,
            nonce,
            aad  = the store KEY string (e.g. "abc…/sync"),
            data = the JSON bytes)
```

- `wenc1` magic + versioned so a future format change is detectable.
- Random 96-bit nonce per seal (values are whole-replace, no
  convergence requirement; the Dart side already skips republishing an
  unchanged doc via its `lastPublished` fingerprint, so random nonces
  add no churn).
- **AAD = the store key string**: a sealed value is bound to its slot,
  so even a link member (or replayer) can't copy device A's sealed
  record under device B's key. Cheap, closes cross-slot replay.
- The crate (`chacha20poly1305 0.10`) and `blake3` are already direct
  deps — the pairing seal uses both. No new dependencies.

### 2.3 Choke points (all in mywatch.rs — no Dart protocol change)

Two helpers, applied at every store touch:

```rust
fn seal_value(secret_hex: &str, store_key: &str, plain: &[u8]) -> Vec<u8>
fn open_value(secret_hex: &str, store_key: &str, value: &[u8]) -> Option<Vec<u8>>
```

Write side (3 sites):
1. `publish_sync` — doc parts (`…/sync`, `…/sync/N`) and map parts
   (`…/maps/N`).
2. `put_own_record` — the device record.
3. The heartbeat `store.put` in `spawn_tasks` (same record).

Read side (2 sites):
4. `sync_docs` — all three suffix kinds (`sync`, `sync/N`, `maps/N`).
5. The status/devices listing (`running.store.keys()` walk at
   ~mywatch.rs:1339) — device records.

`open_value` returning `None` (plaintext, garbage, wrong key, tampered,
replayed into the wrong slot) → the value is **skipped** (debug log).
That is also the injection fix: a topic-holder without the secret can
still write records, but nothing they write ever decrypts, so nothing
reaches the merge. The remote-change watcher compares `content_hash`
only and needs no decrypt.

The art-transfer path is untouched — artwork bytes already travel E2E
over x0x DMs (ML-KEM-768 + ChaCha20), never through the store.

### 2.4 Versioning: new topic domain = clean break, no downgrade

This is a **breaking link-format change** (old builds would see
ciphertext), so instead of a plaintext-fallback mixed state:

- `topic_for` bumps its domain: `"watchit mywatch v1 topic"` →
  `"watchit mywatch v2 topic"`. Same secret → a **different** topic →
  new builds meet in a fresh store, disjoint from old builds.
- No plaintext read fallback, no downgrade path, no mixed-fleet
  garbage. And a nice bonus: anyone who harvested a link's **v1 topic
  string** from relayed envelopes loses the trail — the v2 topic is
  underivable without the secret itself.
- Existing links migrate **automatically**: `link.json` holds only the
  secret; an updated device derives the v2 topic and rejoins. No
  re-link, no re-pairing.
- The store's on-disk snapshots (the lesser "plaintext snapshot on
  disk" finding) now hold sealed values by construction — closed for
  free. (`link.json` itself still holds the secret 0600 in the app
  dir — unchanged trust boundary, same as the wallet file fallback.)

### 2.5 Invite + pairing prefixes bumped for loud cross-version failure

- `INVITE_PREFIX` `wtch1-` → **`wtch2-`**; `PAIR_PREFIX` `wtchp1-` →
  **`wtchp2-`**. Payloads unchanged (same 32-byte secret / same
  rendezvous scheme) — only the labels move.
- New builds emit and accept only the v2 forms. A v1 code is rejected
  with a *specific* message: "this code is from an older W@tch —
  update that device first" (not the generic invalid-code error). Old
  builds reject v2 codes with their generic error — crude, but a hard
  stop instead of a silent never-syncs link.
- Unavoidable residual: an already-linked mixed fleet (one device
  updated, one not) splits across topics and silently stops syncing
  until both update. Surfaced by the existing per-device "Sync data
  updated X ago" tile going stale + release notes ("update every
  linked device together"). A one-release read-only peek at the v1
  topic to detect stragglers was considered and **rejected** — it
  keeps the old topic warm for marginal UX.

### 2.6 Rounding out the review's fix list

- **backup_follow.dart:18** doc comment ("already travels encrypted
  inside the link store") — false today; becomes true with this
  change. Fix the wording with the implementation so the comment names
  the seal explicitly. (Same for the matching ROADMAP phase-2 line.)
- **PIN hashes**: once the store is sealed, PIN hashes only ever reach
  link members (the user's own devices) — the practical exposure is
  closed. Key-stretching them (argon2/PBKDF2) before they enter the
  profiles section stays a separate, optional follow-up: it changes
  the cross-device PIN-verify format and needs its own migration;
  deliberately NOT bundled into this change.
- **x0x encrypted KvStore (#341-B)** re-checked and still not a
  drop-in — it's bound to secure groups, not self-keyed topics. App-
  layer sealing is the right shape; if upstream ever ships encrypted
  self-keyed stores we can migrate behind another topic-domain bump.

## 3. What this fixes / what it deliberately does not

Fixed: every store value unreadable without the link secret (library,
maps/playable keys, watch positions, profiles + PIN hashes, kid
allow-lists, device names/platforms, user edits, TMDB rows, **backup
read keys**); write-injection by topic-holders; plaintext store
snapshots on disk; harvested-topic tracking (via the domain bump).

Not in scope (unchanged trust boundaries, stated honestly):
- The v2 topic string still appears in relayed envelopes → an observer
  sees that *a* link exists, member agent ids, message sizes/timing
  (metadata, not content).
- Anything **already captured** from the v1 plaintext era stays
  readable to its captor forever — sealing is forward-only. For the
  backup keys specifically the honest lever remains: new wallet = new
  backup line. (Note: the 2026-10-07 live test ran single-device —
  no link active — so the fresh wallet's backup section was never
  published to any store; its keys never traveled.)
- Local files (`link.json`, `backup_follow.json`, `backup_state.json`)
  keep plaintext secrets under the app-dir trust boundary.
- Art DMs on the raw-QUIC fallback stay transport-only (pre-existing,
  separate).

## 4. Tests

Cargo (mywatch.rs):
- seal/open round trip; wrong secret refuses; tampered ciphertext
  refuses; **slot binding** — sealed under `<a>/sync` refuses to open
  as `<b>/sync`; plaintext/garbage values open as `None`.
- `topic_for` v2 differs from the v1 derivation for the same secret
  (pin the old string so the break is deliberate).
- publish → `sync_docs` round trip through a store sees the decrypted
  doc/maps; an injected unsealed value is skipped.
- invite/pair prefix matrix: v2 accepted any casing, v1 rejected with
  the update-first message.

Live verify (the standing two-devserver pattern + Xvfb GUI):
- two fresh devservers link over a v2 invite, publish/merge both ways;
  dump a store snapshot `.bin` and grep — **no plaintext titles,
  addresses, or `"ptr"` anywhere**.
- GUI: create link, pair, device tiles + sync all behave as before.

## 5. Effort + rollout

Small: one Rust file (helpers + 5 call sites + prefix/domain bumps +
tests), one Dart doc comment, docs. No schema change, no route change,
no Dart sync-protocol change. Ship as the headline of the next release
with release notes saying **update every linked device together**; the
backup feature is unaffected (its own encryption was always sound —
this protects the *sharing* of its read keys).

## Open questions (with recommendations)

1. Bump the user-visible invite prefix to `wtch2-`? **Recommended yes**
   (loud cross-version failure beats silent no-sync). Cost: printed/
   saved old invite codes die — acceptable, invites are cheap to
   re-show.
2. Stretch PIN hashes in the same release? **Recommended no** —
   separate migration, sealing already closes the practical exposure.
