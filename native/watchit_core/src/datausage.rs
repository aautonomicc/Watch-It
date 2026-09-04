//! Period data-usage accounting (Settings → Network → Data usage).
//!
//! Three network components are metered separately:
//!
//! * **ant** — the Autonomi client (streaming, downloads, uploads, DHT).
//!   ant-core exposes no public byte counters (saorsa-core's
//!   `TrafficCounters` are `pub(crate)`), so v1 captures the structured
//!   tracing event saorsa-core emits every 300 s (`target:
//!   "saorsa_core::traffic"`, message "wire traffic summary
//!   (cumulative)") through [`AntTrafficLayer`] — we own the subscriber,
//!   so this needs no patching. Values are decoded protocol bytes, up to
//!   5 minutes stale (`stale_secs` keeps the UI honest). Upstream PR
//!   WithAutonomi/saorsa-core#160 adds a live public accessor; once it
//!   is merged and released past our ant-core pin, this capture becomes
//!   deletable. The field contract (`wire_tx_bytes` / `wire_rx_bytes`
//!   u64s on that target) is pinned by `layer_parses_traffic_summary`
//!   below — re-verify against the saorsa-core source on every bump.
//! * **mywatch** / **channels** — the two x0x agents. Exact per-agent
//!   UDP wire bytes from per-connection quinn counters
//!   (`connection_transport_stats`), delta-folded on `(peer,
//!   generation)` by a 15 s sampler task per agent (the pool evicts idle
//!   connections; `generation` detects reconnects). Bytes moved in the
//!   final window before an eviction are lost — a small, accepted
//!   undercount. (`NetworkNode::stats()` is NOT usable: its
//!   `bytes_sent` counts relay-forwarded bytes and `bytes_received` is
//!   hardcoded 0.)
//!
//! All counters are **period accumulators**: they survive restarts via
//! `<data>/datausage.json` (written every 60 s when dirty) and only
//! reset on `POST /stats/reset`. `media_rx` additionally folds the live
//! [`crate::engine::FETCHED_BYTES`] counter into the period so the
//! Autonomi tile can show "of which media".

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{LazyLock, Mutex};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use tracing::field::{Field, Visit};
use tracing::{Event, Subscriber};
use tracing_subscriber::layer::{Context, Layer};

/// How often a dirty accumulator set is persisted.
const SAVE_INTERVAL: std::time::Duration = std::time::Duration::from_secs(60);

/// x0x sampler cadence. Comfortably inside the pool's idle-eviction
/// window so per-connection deltas are rarely lost.
#[cfg(any(
    target_os = "linux",
    target_os = "windows",
    target_os = "macos",
    target_os = "android"
))]
const X0X_SAMPLE_INTERVAL: std::time::Duration = std::time::Duration::from_secs(15);

/// Drop `(peer, generation)` baselines unseen for this long. A key that
/// reappears sooner keeps its baseline (a missed snapshot must not
/// re-count history); one that reappears later is treated as new.
#[cfg(any(
    target_os = "linux",
    target_os = "windows",
    target_os = "macos",
    target_os = "android"
))]
const X0X_KEY_TTL: std::time::Duration = std::time::Duration::from_secs(600);

/// Up/down period totals for one component.
#[derive(Default)]
pub struct ComponentUsage {
    pub rx: AtomicU64,
    pub tx: AtomicU64,
}

impl ComponentUsage {
    fn add(&self, tx: u64, rx: u64) {
        self.tx.fetch_add(tx, Ordering::Relaxed);
        self.rx.fetch_add(rx, Ordering::Relaxed);
    }
    fn zero(&self) {
        self.tx.store(0, Ordering::Relaxed);
        self.rx.store(0, Ordering::Relaxed);
    }
    fn json(&self) -> serde_json::Value {
        serde_json::json!({
            "rx": self.rx.load(Ordering::Relaxed),
            "tx": self.tx.load(Ordering::Relaxed),
        })
    }
}

/// The three metered components.
#[derive(Clone, Copy)]
pub enum Component {
    MyWatch,
    Channels,
}

/// Process-wide period accounting. One global instance ([`usage()`]);
/// tests construct their own.
pub struct DataUsage {
    pub ant: ComponentUsage,
    pub mywatch: ComponentUsage,
    pub channels: ComponentUsage,
    /// Media chunk payload downloaded this period (folded from the
    /// process-lifetime `FETCHED_BYTES`).
    media_rx: AtomicU64,
    period_start_ms: AtomicU64,
    dirty: AtomicBool,
    path: Mutex<Option<PathBuf>>,
    /// Last ant summary's process-cumulative (tx, rx) — the delta
    /// baseline. NOT persisted and NOT reset on `reset()`: it tracks the
    /// live client's counters, not the period.
    ant_baseline: Mutex<Option<(u64, u64)>>,
    /// When the last ant summary arrived (for `stale_secs`).
    ant_last_at: Mutex<Option<Instant>>,
    /// Last seen `FETCHED_BYTES` value (process-cumulative).
    media_baseline: AtomicU64,
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

impl DataUsage {
    pub fn new() -> Self {
        Self {
            ant: ComponentUsage::default(),
            mywatch: ComponentUsage::default(),
            channels: ComponentUsage::default(),
            media_rx: AtomicU64::new(0),
            period_start_ms: AtomicU64::new(now_ms()),
            dirty: AtomicBool::new(false),
            path: Mutex::new(None),
            ant_baseline: Mutex::new(None),
            ant_last_at: Mutex::new(None),
            media_baseline: AtomicU64::new(0),
        }
    }

    fn component(&self, c: Component) -> &ComponentUsage {
        match c {
            Component::MyWatch => &self.mywatch,
            Component::Channels => &self.channels,
        }
    }

    /// Point persistence at `<dir>/datausage.json` and load any saved
    /// period. Called once from `Engine::new` when a data dir exists.
    pub fn init_storage(&self, dir: &std::path::Path) {
        let file = dir.join("datausage.json");
        if let Ok(bytes) = std::fs::read(&file) {
            if let Ok(v) = serde_json::from_slice::<serde_json::Value>(&bytes) {
                let load = |c: &ComponentUsage, key: &str| {
                    c.tx.store(v[key]["tx"].as_u64().unwrap_or(0), Ordering::Relaxed);
                    c.rx.store(v[key]["rx"].as_u64().unwrap_or(0), Ordering::Relaxed);
                };
                load(&self.ant, "ant");
                load(&self.mywatch, "mywatch");
                load(&self.channels, "channels");
                self.media_rx
                    .store(v["media_rx"].as_u64().unwrap_or(0), Ordering::Relaxed);
                self.period_start_ms.store(
                    v["period_start_ms"].as_u64().unwrap_or_else(now_ms),
                    Ordering::Relaxed,
                );
            }
        }
        *self.path.lock().unwrap() = Some(file);
    }

    /// Add x0x sampler deltas for one agent.
    pub fn add_x0x(&self, component: Component, tx: u64, rx: u64) {
        if tx == 0 && rx == 0 {
            return;
        }
        self.component(component).add(tx, rx);
        self.dirty.store(true, Ordering::Relaxed);
    }

    /// Fold one ant wire-traffic summary (process-cumulative counters)
    /// into the period. A counter smaller than the baseline means a
    /// fresh client (reconnect after pause/drop restarted the transport)
    /// — its whole value belongs to this period.
    pub fn record_ant_summary(&self, tx_cum: u64, rx_cum: u64) {
        let (dtx, drx) = {
            let mut base = self.ant_baseline.lock().unwrap();
            let delta = match *base {
                Some((btx, brx)) if tx_cum >= btx && rx_cum >= brx => {
                    (tx_cum - btx, rx_cum - brx)
                }
                _ => (tx_cum, rx_cum),
            };
            *base = Some((tx_cum, rx_cum));
            delta
        };
        self.ant.add(dtx, drx);
        *self.ant_last_at.lock().unwrap() = Some(Instant::now());
        self.dirty.store(true, Ordering::Relaxed);
    }

    /// Seconds since the last ant traffic summary, or None before the
    /// first one of this process (the first arrives ~5 min after
    /// connect).
    pub fn ant_stale_secs(&self) -> Option<u64> {
        self.ant_last_at
            .lock()
            .unwrap()
            .map(|t| t.elapsed().as_secs())
    }

    /// Fold the live media counter into the period accumulator.
    fn fold_media(&self) {
        let cur = crate::engine::FETCHED_BYTES.load(Ordering::Relaxed);
        let prev = self.media_baseline.swap(cur, Ordering::Relaxed);
        let delta = cur.saturating_sub(prev);
        if delta > 0 {
            self.media_rx.fetch_add(delta, Ordering::Relaxed);
            self.dirty.store(true, Ordering::Relaxed);
        }
    }

    /// The `GET /stats` body. Always fully populated — unlike `/health`,
    /// which collapses to `{"state":"paused"}` while the network is
    /// paused.
    pub fn stats_json(&self) -> serde_json::Value {
        self.fold_media();
        let (ant_rx, ant_tx) = (
            self.ant.rx.load(Ordering::Relaxed),
            self.ant.tx.load(Ordering::Relaxed),
        );
        let (mw_rx, mw_tx) = (
            self.mywatch.rx.load(Ordering::Relaxed),
            self.mywatch.tx.load(Ordering::Relaxed),
        );
        let (ch_rx, ch_tx) = (
            self.channels.rx.load(Ordering::Relaxed),
            self.channels.tx.load(Ordering::Relaxed),
        );
        serde_json::json!({
            "period_start_ms": self.period_start_ms.load(Ordering::Relaxed),
            "total": { "rx": ant_rx + mw_rx + ch_rx, "tx": ant_tx + mw_tx + ch_tx },
            "ant": {
                "rx": ant_rx,
                "tx": ant_tx,
                "media_rx": self.media_rx.load(Ordering::Relaxed),
                "stale_secs": self.ant_stale_secs(),
            },
            "mywatch": self.mywatch.json(),
            "channels": self.channels.json(),
        })
    }

    /// `POST /stats/reset`: zero every component at once (one period,
    /// one mental model), stamp a fresh period start, persist.
    pub fn reset(&self) {
        // Re-baseline media first so bytes fetched before the reset
        // can't leak into the new period on the next fold.
        self.media_baseline
            .store(crate::engine::FETCHED_BYTES.load(Ordering::Relaxed), Ordering::Relaxed);
        self.ant.zero();
        self.mywatch.zero();
        self.channels.zero();
        self.media_rx.store(0, Ordering::Relaxed);
        self.period_start_ms.store(now_ms(), Ordering::Relaxed);
        self.dirty.store(true, Ordering::Relaxed);
        self.save_if_dirty();
    }

    /// Persist when anything changed since the last save.
    pub fn save_if_dirty(&self) {
        self.fold_media();
        if !self.dirty.swap(false, Ordering::Relaxed) {
            return;
        }
        let Some(path) = self.path.lock().unwrap().clone() else {
            return;
        };
        let body = serde_json::json!({
            "period_start_ms": self.period_start_ms.load(Ordering::Relaxed),
            "ant": self.ant.json(),
            "mywatch": self.mywatch.json(),
            "channels": self.channels.json(),
            "media_rx": self.media_rx.load(Ordering::Relaxed),
        });
        if let Err(e) = std::fs::write(&path, body.to_string()) {
            tracing::warn!("datausage save failed: {e}");
        }
    }
}

/// The process-wide accumulator set.
pub fn usage() -> &'static DataUsage {
    static USAGE: LazyLock<DataUsage> = LazyLock::new(DataUsage::new);
    LazyLock::force(&USAGE)
}

/// Periodic dirty-save loop; spawned once at server start.
pub async fn save_task() {
    loop {
        tokio::time::sleep(SAVE_INTERVAL).await;
        usage().save_if_dirty();
    }
}

/// Tracing layer capturing saorsa-core's 300 s wire-traffic summary into
/// the ant accumulators (see module docs).
pub struct AntTrafficLayer {
    usage: &'static DataUsage,
}

/// The layer wired to the global accumulators, for `init_tracing`.
///
/// Wrapped in a per-layer filter scoped to the one traffic target: a
/// raw `Layer::enabled` override would be ANDed across the WHOLE
/// subscriber stack and silence every other layer's events (it did —
/// the first live run logged nothing), while a `Filter` applies to this
/// layer alone and keeps unrelated callsites disabled for it.
pub fn ant_traffic_layer<S>() -> impl Layer<S>
where
    S: Subscriber + for<'a> tracing_subscriber::registry::LookupSpan<'a>,
{
    AntTrafficLayer { usage: usage() }.with_filter(
        tracing_subscriber::filter::filter_fn(|meta| {
            meta.is_event() && meta.target() == TRAFFIC_TARGET
        }),
    )
}

impl AntTrafficLayer {
    /// A layer writing into a caller-owned instance (tests).
    pub fn for_usage(usage: &'static DataUsage) -> Self {
        Self { usage }
    }
}

const TRAFFIC_TARGET: &str = "saorsa_core::traffic";

#[derive(Default)]
struct TrafficVisitor {
    tx: Option<u64>,
    rx: Option<u64>,
}

impl Visit for TrafficVisitor {
    fn record_u64(&mut self, field: &Field, value: u64) {
        match field.name() {
            "wire_tx_bytes" => self.tx = Some(value),
            "wire_rx_bytes" => self.rx = Some(value),
            _ => {}
        }
    }
    fn record_i64(&mut self, field: &Field, value: i64) {
        if value >= 0 {
            self.record_u64(field, value as u64);
        }
    }
    fn record_debug(&mut self, _field: &Field, _value: &dyn std::fmt::Debug) {}
}

impl<S: Subscriber> Layer<S> for AntTrafficLayer {
    // NOTE: no `enabled`/`register_callsite` overrides — those are
    // ANDed across the whole subscriber stack and would silence the log
    // layers. Target scoping lives in [`ant_traffic_layer`]'s per-layer
    // filter (and defensively in the check below, for tests that mount
    // the layer bare).
    fn on_event(&self, event: &Event<'_>, _ctx: Context<'_, S>) {
        if event.metadata().target() != TRAFFIC_TARGET {
            return;
        }
        let mut v = TrafficVisitor::default();
        event.record(&mut v);
        if let (Some(tx), Some(rx)) = (v.tx, v.rx) {
            self.usage.record_ant_summary(tx, rx);
        }
    }
}

/// Delta-fold one x0x per-connection sample into the running baselines.
/// Returns the (tx, rx) delta to add to the period. A vacant key is a
/// connection observed for the first time — all its bytes so far belong
/// to this period (per-connection counters start at 0 at connect).
pub fn fold_x0x_sample(
    seen: &mut HashMap<([u8; 32], u64), (u64, u64)>,
    key: ([u8; 32], u64),
    tx: u64,
    rx: u64,
) -> (u64, u64) {
    match seen.entry(key) {
        std::collections::hash_map::Entry::Occupied(mut o) => {
            let (btx, brx) = *o.get();
            let delta = (tx.saturating_sub(btx), rx.saturating_sub(brx));
            // Counters are monotonic per (peer, generation); keep the max
            // so a stale out-of-order snapshot can never re-count bytes.
            o.insert((tx.max(btx), rx.max(brx)));
            delta
        }
        std::collections::hash_map::Entry::Vacant(v) => {
            v.insert((tx, rx));
            (tx, rx)
        }
    }
}

/// Per-agent UDP byte sampler. Spawned right after an agent joins the
/// network; exits when the agent is dropped (the store holds the only
/// strong references).
#[cfg(any(
    target_os = "linux",
    target_os = "windows",
    target_os = "macos",
    target_os = "android"
))]
pub fn spawn_x0x_sampler(component: Component, agent: std::sync::Weak<x0x::Agent>) {
    tokio::spawn(async move {
        let mut seen: HashMap<([u8; 32], u64), (u64, u64)> = HashMap::new();
        let mut last_seen: HashMap<([u8; 32], u64), Instant> = HashMap::new();
        loop {
            tokio::time::sleep(X0X_SAMPLE_INTERVAL).await;
            let Some(agent) = agent.upgrade() else { break };
            let Some(net) = agent.network() else { continue };
            let (mut dtx, mut drx) = (0u64, 0u64);
            for peer in net.connected_peers().await {
                let Some(stats) = net.connection_transport_stats(peer).await else {
                    continue;
                };
                if !stats.connected {
                    continue;
                }
                let key = (peer.0, stats.generation.unwrap_or(0));
                let (tx, rx) =
                    fold_x0x_sample(&mut seen, key, stats.udp_tx_bytes, stats.udp_rx_bytes);
                dtx += tx;
                drx += rx;
                last_seen.insert(key, Instant::now());
            }
            usage().add_x0x(component, dtx, drx);
            // Prune baselines of long-gone connections (evicted peers
            // reconnect under a new generation, so old keys never come
            // back — but keep recent ones so one missed snapshot can't
            // re-count a connection's history).
            last_seen.retain(|key, at| {
                let keep = at.elapsed() < X0X_KEY_TTL;
                if !keep {
                    seen.remove(key);
                }
                keep
            });
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fold_x0x_sample_counts_new_growth_and_reconnect() {
        let mut seen = HashMap::new();
        let peer = [1u8; 32];
        // First observation: everything counts.
        assert_eq!(fold_x0x_sample(&mut seen, (peer, 1), 100, 200), (100, 200));
        // Growth: only the delta.
        assert_eq!(fold_x0x_sample(&mut seen, (peer, 1), 150, 260), (50, 60));
        // No movement: zero.
        assert_eq!(fold_x0x_sample(&mut seen, (peer, 1), 150, 260), (0, 0));
        // Stale out-of-order snapshot: never negative, never re-counted.
        assert_eq!(fold_x0x_sample(&mut seen, (peer, 1), 120, 260), (0, 0));
        assert_eq!(fold_x0x_sample(&mut seen, (peer, 1), 160, 300), (10, 40));
        // Generation bump = reconnect: fresh counters all count.
        assert_eq!(fold_x0x_sample(&mut seen, (peer, 2), 30, 40), (30, 40));
        // A different peer is independent.
        assert_eq!(fold_x0x_sample(&mut seen, ([2u8; 32], 7), 5, 6), (5, 6));
        // An evicted peer simply stops appearing — nothing to assert
        // beyond the baselines not affecting others.
        assert_eq!(seen.len(), 3);
    }

    #[test]
    fn record_ant_summary_folds_deltas_and_counter_restarts() {
        let u = DataUsage::new();
        u.record_ant_summary(1000, 2000);
        assert_eq!(u.ant.tx.load(Ordering::Relaxed), 1000);
        assert_eq!(u.ant.rx.load(Ordering::Relaxed), 2000);
        u.record_ant_summary(1500, 2600);
        assert_eq!(u.ant.tx.load(Ordering::Relaxed), 1500);
        assert_eq!(u.ant.rx.load(Ordering::Relaxed), 2600);
        // Fresh client after a reconnect: counters restarted below the
        // baseline — the whole new value belongs to the period.
        u.record_ant_summary(100, 50);
        assert_eq!(u.ant.tx.load(Ordering::Relaxed), 1600);
        assert_eq!(u.ant.rx.load(Ordering::Relaxed), 2650);
        assert!(u.ant_stale_secs().is_some());
    }

    #[test]
    fn layer_parses_traffic_summary() {
        // Pins the field contract this capture depends on: u64
        // `wire_tx_bytes` / `wire_rx_bytes` on target
        // "saorsa_core::traffic" (saorsa-core 0.27.3
        // dht_network_manager.rs `spawn_traffic_summary_task`).
        use tracing_subscriber::layer::SubscriberExt;
        let usage: &'static DataUsage = Box::leak(Box::new(DataUsage::new()));
        let subscriber =
            tracing_subscriber::registry().with(AntTrafficLayer::for_usage(usage));
        tracing::subscriber::with_default(subscriber, || {
            tracing::info!(
                target: "saorsa_core::traffic",
                wire_tx_bytes = 10u64,
                wire_rx_bytes = 20u64,
                wire_tx_count = 3u64,
                "wire traffic summary (cumulative)"
            );
            // Unrelated events on other targets change nothing.
            tracing::info!(wire_tx_bytes = 999u64, "not the traffic summary");
            tracing::info!(
                target: "saorsa_core::traffic",
                wire_tx_bytes = 25u64,
                wire_rx_bytes = 45u64,
                "wire traffic summary (cumulative)"
            );
        });
        assert_eq!(usage.ant.tx.load(Ordering::Relaxed), 25);
        assert_eq!(usage.ant.rx.load(Ordering::Relaxed), 45);
        assert!(usage.ant_stale_secs().is_some());
    }

    #[test]
    fn persistence_round_trip() {
        let dir = std::env::temp_dir().join(format!(
            "wi-datausage-test-{}-{}",
            std::process::id(),
            now_ms()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let u = DataUsage::new();
        u.init_storage(&dir);
        u.add_x0x(Component::MyWatch, 11, 22);
        u.add_x0x(Component::Channels, 33, 44);
        u.record_ant_summary(55, 66);
        u.save_if_dirty();

        let loaded = DataUsage::new();
        loaded.init_storage(&dir);
        assert_eq!(loaded.mywatch.tx.load(Ordering::Relaxed), 11);
        assert_eq!(loaded.mywatch.rx.load(Ordering::Relaxed), 22);
        assert_eq!(loaded.channels.tx.load(Ordering::Relaxed), 33);
        assert_eq!(loaded.channels.rx.load(Ordering::Relaxed), 44);
        assert_eq!(loaded.ant.tx.load(Ordering::Relaxed), 55);
        assert_eq!(loaded.ant.rx.load(Ordering::Relaxed), 66);
        assert_eq!(
            loaded.period_start_ms.load(Ordering::Relaxed),
            u.period_start_ms.load(Ordering::Relaxed)
        );
        // A fresh process has no summary yet: stale is unknown.
        assert!(loaded.ant_stale_secs().is_none());

        // Reset zeroes everything and stamps a new period.
        loaded.reset();
        assert_eq!(loaded.ant.tx.load(Ordering::Relaxed), 0);
        assert_eq!(loaded.mywatch.rx.load(Ordering::Relaxed), 0);
        assert_eq!(loaded.channels.tx.load(Ordering::Relaxed), 0);
        let v = loaded.stats_json();
        assert_eq!(v["total"]["rx"].as_u64(), Some(0));
        // The reset persisted: a re-load sees zeros too.
        let reloaded = DataUsage::new();
        reloaded.init_storage(&dir);
        assert_eq!(reloaded.ant.rx.load(Ordering::Relaxed), 0);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn stats_json_shape() {
        let u = DataUsage::new();
        u.add_x0x(Component::MyWatch, 1, 2);
        u.add_x0x(Component::Channels, 3, 4);
        u.record_ant_summary(5, 6);
        let v = u.stats_json();
        assert_eq!(v["total"]["tx"].as_u64(), Some(9));
        assert_eq!(v["total"]["rx"].as_u64(), Some(12));
        assert_eq!(v["ant"]["tx"].as_u64(), Some(5));
        assert_eq!(v["mywatch"]["rx"].as_u64(), Some(2));
        assert_eq!(v["channels"]["rx"].as_u64(), Some(4));
        assert_eq!(v["ant"]["stale_secs"].as_u64(), Some(0));
        assert!(v["period_start_ms"].as_u64().unwrap() > 0);
        assert!(v["ant"]["media_rx"].is_u64());
    }
}
