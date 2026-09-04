# Plan: Data usage screen (Settings → Network)

Status: **IMPLEMENTED** (2026-09-04, same day as planned — v1 with the
Option A tracing capture; the capture becomes deletable when upstream PR
[WithAutonomi/saorsa-core#160](https://github.com/WithAutonomi/saorsa-core/pull/160)
is merged, released, and reaches us through an ant-core bump). The
implementation session also bumped ant-core 0.5.1 → 0.8.1 (saorsa-core
0.26.4 → 0.27.3 — the exact version #160 targets; the traffic-summary
field contract re-verified against it and pinned by a unit test), x0x
0.40.4 → 0.41.1, and dropped the vendored ant-quic (0.27.48 relaxed its
unicode-width pin upstream).

One deviation from the text below: `/stats` reports `period_start_ms`
(epoch millis) rather than an ISO `period_start` string — no chrono
dependency needed, Dart formats the date.

## Goal

A "Data usage" entry in Settings → NETWORK, placed **above the Buffer size tile**
(`app/lib/screens/settings_screen.dart:536`), opening a screen that shows, top to bottom:

1. **Total data usage** — big number, with **up** and **down** in smaller text side by side below it.
2. The same tile for each of our three network users:
   - **Autonomi client** (ant-core: streaming, downloads, uploads, DHT)
   - **My W@tch** (x0x agent under `<data>/mywatch/`)
   - **Channels** (x0x agent under `<data>/channels/x0x/`)
3. A **"Since <date>"** caption (period start) and a **Reset** button (with confirm dialog).

Motivated by the 2026-09-03 data-usage analysis: the ant client's readahead traffic is ~98% of
usage, with an idle DHT trickle underneath — the screen makes that visible in-app instead of
requiring wi-netmon captures.

## What each component can actually report (survey result)

### x0x agents (My W@tch + Channels) — accurate, zero patching

The two agents are physically separate `x0x::Agent`s / `NetworkNode`s
(`native/watchit_core/src/mywatch.rs:754`, `channels.rs:362`), so the split is exact.

Path: `agent.network()` (x0x `lib.rs:3202`) → `connected_peers()` (x0x `network.rs:3500`) →
per-peer `connection_transport_stats()` (x0x `network.rs:2086` → ant-quic
`p2p_endpoint.rs:1009`) → `udp_tx_bytes` / `udp_rx_bytes` straight from quinn. Real UDP wire
bytes.

**Trap:** `NetworkNode::stats()` looks right but is not — `bytes_sent` is relay-forwarded
bytes for *other* peers and `bytes_received` is hardcoded 0 (x0x `network.rs:2136-2142`).
Do not use it.

**Churn handling:** the counters are per-connection cumulative and the pool evicts idle
connections, so a sampler must accumulate **deltas keyed on `(peer_id, generation)`**
(`generation` exists precisely to detect reconnects). Sample every ~15 s; bytes moved in the
final window before an eviction are lost — accept the small undercount.

### Autonomi client (ant-core 0.5.1) — two imperfect options, no perfect one

- ant-core exposes **no** byte counters. saorsa-core's `TransportHandle` keeps full
  `TrafficCounters` (`wire_tx_bytes`, `wire_rx_bytes`, overhead splits — saorsa-core
  `transport_handle.rs:224`) but they are `pub(crate)` with no public accessor, and the
  `P2pEndpoint` (which has quinn-level `connection_metrics()`) is also unreachable.
- **Option A (recommended for v1): tracing capture.** saorsa-core logs the full counter set
  every **300 s** as a structured tracing event (`target: "saorsa_core::traffic"`, message
  "wire traffic summary (cumulative)" — `dht_network_manager.rs:1876-1922`). We own the
  subscriber (`lib.rs:164` `init_tracing()`), so a custom `tracing` Layer can read the fields
  into atomics. Zero patching. Caveats: 5-minute staleness; `wire_rx_bytes` counts *decoded*
  protocol bytes (excludes UDP framing + rejected frames); log-field contract could break on
  a saorsa-core bump (guard with a test against the vendored source, and the pin is a git rev
  so bumps are deliberate).
- **Option B (upgrade path): patch saorsa-core.** One `pub fn traffic_snapshot()` on
  `TransportHandle`, vendored like ant-quic already is (`Cargo.toml:88` `[patch.crates-io]`),
  reachable via `client.network().node().transport()`. Live + exact, but a second vendored
  crate to maintain. Also worth an **upstream ask** to saorsa-labs (x0x-watch already tracks
  them) — if accepted, Option B becomes free later.
- We keep the existing `FETCHED_BYTES` (`engine.rs:55` — media chunk payload downloaded,
  live) as a secondary "of which media: X" line on the Autonomi tile. It's the number that
  answers "what did watching cost", updates instantly, and is already wired.

Uploads: `upload.rs` counts chunks, not wire bytes — but wire **tx** from Option A/B covers
uploads correctly, so no separate upload counter is needed.

**Honesty note for the UI:** x0x rows are raw UDP bytes; the Autonomi row is decoded protocol
bytes. Both exclude OS/VPN overhead, so totals will read a few % under carrier/OS meters.
One footnote line on the screen covers this.

## Design

### Rust: accounting + `/stats` route

New module `native/watchit_core/src/datausage.rs`:

- `struct ComponentUsage { rx: AtomicU64, tx: AtomicU64 }` × 3 (`ant`, `mywatch`, `channels`)
  + `period_start: RwLock<SystemTime>`. These are **period accumulators** (persisted), fed by:
  - one sampler task per x0x agent (15 s tick, `(peer, generation)` delta fold; started when
    the agent starts, lives alongside it — same lifecycle spot as `x0x_tune::quiet_agent`);
  - the tracing Layer for ant (folds the delta between consecutive 5-min summaries; summary
    counters are process-cumulative so deltas survive our own accumulator resets).
- **Persistence:** `<data>/datausage.json` — `{period_start, ant:{rx,tx}, mywatch:{...},
  channels:{...}, fetched_bytes}` written every 60 s when dirty + on the same shutdown path
  that saves the adaptive-controller snapshot. Loaded on start. This is what makes
  "since <date>" survive app restarts (all current counters are process-lifetime only).
- **`GET /stats`** (beside `/health`, `server.rs:165`; auth-protected like `/network/pause`):
  always populated **even when paused** (unlike `/health`, which collapses to
  `{"state":"paused"}` — the reason the screen gets its own route). Returns:

  ```json
  { "period_start": "2026-09-04T10:00:00Z",
    "total": {"rx": 0, "tx": 0},
    "ant": {"rx": 0, "tx": 0, "media_rx": 0, "stale_secs": 120},
    "mywatch": {"rx": 0, "tx": 0},
    "channels": {"rx": 0, "tx": 0} }
  ```

  `stale_secs` = age of the last traffic summary, so the UI can say "updated 2 min ago".
- **`POST /stats/reset`** — zeroes accumulators, sets `period_start = now`, saves, returns
  the fresh `/stats` body.

### Flutter: tile + screen

- **Settings tile** (above Buffer size, `settings_screen.dart:536`): `ListTile`,
  `Icons.data_usage`, subtitle = period total (from a one-shot `/stats` fetch), chevron →
  `DataUsageScreen` — same navigation pattern as the Mobile data tile (`:651-656`).
- **`app/lib/screens/data_usage_screen.dart`** — modeled on `mobile_data_screen.dart`
  (Stateful, `_load()`, ink AppBar). Polls `GET /stats` every 5 s while visible
  (`x0x_client_screen.dart` timer pattern). Layout top→bottom:
  1. **Total** card: `formatBytes(total.rx + total.tx)` large; below, side by side in
     `t.ash` small text: `↑ formatBytes(tx)` · `↓ formatBytes(rx)`.
  2. Three component tiles, same shape (name + total, up/down beneath):
     **Autonomi client** (+ "of which media: X" + "updated N min ago" when stale),
     **My W@tch**, **Channels**. Disabled agents show "Off" with their period totals kept.
  3. **Current rate** row: derived Dart-side from consecutive polls (`Δbytes/Δt` → "↓ 240 KB/s
     ↑ 12 KB/s"). No Rust work; answers "what's chewing data *right now*".
  4. Footer: `Since 4 Sep 2026` + **Reset** `TextButton` → confirm dialog → `POST
     /stats/reset` → refresh. Plus the one-line measurement footnote.
- `EmbeddedClient` gains `stats()` / `resetStats()` (`embedded_client.dart`, beside
  `health()`); reuse `formatBytes` (`models/media_list.dart:136`), not `byteLabel`.

### Tests

- Rust: sampler delta-fold unit tests (same peer growing, generation bump = reconnect,
  peer vanishing = eviction); tracing-layer parse test against a synthetic event;
  `/stats` + `/stats/reset` route tests (incl. while paused); persistence round-trip.
- Dart: `fake_embedded_http.dart` grows `/stats`; widget tests for tile placement (above
  Buffer size), screen rendering, reset flow; `app_settings`-style test not needed (no new
  prefs — period state lives in `datausage.json` on the Rust side, one source of truth).
- Live verify (Watch-It:verify skill): play NOTLD ~1 min → Autonomi rx climbs and rate row
  moves; toggle My W@tch sync → its row moves; reset → zeros + fresh date.

## Also considered (the "anything else" question)

Worth adding now:
- **Current rate row** — included above; nearly free and the most actionable readout.
- **"Of which media" split on the Autonomi row** — included; separates "you watched stuff"
  from protocol overhead/idle chatter, which is exactly the question the netmon captures
  kept answering.
- **Session vs period**: the screen shows period (since reset); `/stats` can also return
  session-start values later if wanted — defer.

Deliberately deferred:
- **Daily history buckets / graph** (7–30 day trend): real value for spotting the idle
  trickle, but it's a schema + chart commitment. `datausage.json` is shaped so buckets can
  be added without migration. v2.
- **Wi-Fi vs cellular attribution** (tag deltas with `NetworkEvents` transport at sample
  time): Android-centric, cheap once samplers exist. v2, pairs with the Mobile data screen.
- **Budget/alert** (e.g. warn past N GB/month): overkill until history exists.
- **Prefetch vs demand split** inside media bytes: needs a flag threaded through
  `cached_chunk_get`/`fetch_chunk_batch` (`engine.rs:644-716`); skip unless readahead
  tuning reopens.
- **Per-peer / per-list attribution**: not meaningful at chunk level (self-encryption).

## Decisions (2026-09-04 — user accepted all four recommendations)

1. **Autonomi row fidelity**: v1 uses the 5-minute tracing-summary capture (Option A);
   `stale_secs` keeps it honest, media bytes stay live. The upstream accessor request to
   saorsa-labs gets filed either way — if accepted, the capture (and any vendored patch)
   becomes deletable. **FILED 2026-09-04**:
   [WithAutonomi/saorsa-core#160](https://github.com/WithAutonomi/saorsa-core/pull/160)
   (repo moved from saorsa-labs to WithAutonomi) adds
   `TransportHandle::traffic_snapshot()` → public `TrafficSnapshot`, exactly the Option B
   accessor. If merged+released, Option B needs no vendored crate — just an ant-core bump
   past that saorsa-core version.
2. **Reset semantics**: Reset clears all components at once — one period, simple mental
   model.
3. **Settings tile subtitle**: shows the running period total (one extra fetch on
   settings open).
4. **Poll cadence on-screen**: 5 s — enough for a rate row, matches the x0x screen's
   active cadence.

## Build order

1. Rust `datausage.rs` (accumulators + persistence) + x0x samplers + `/stats`,`/stats/reset`.
2. Ant tracing-layer capture + `media_rx` wiring.
3. Dart `EmbeddedClient.stats()` + screen + settings tile + tests.
4. Live verify. (Upstream ask already filed: WithAutonomi/saorsa-core#160.)
