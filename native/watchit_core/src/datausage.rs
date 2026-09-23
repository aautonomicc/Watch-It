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
//!
//! Beside the period, every add also lands in a **per-local-day
//! bucket** (kept ~35 days, persisted alongside the period, NOT
//! touched by reset — the Data page's daily graph survives a period
//! reset by design). Each bucket splits per component into total and
//! mobile-tagged bytes: the app reports the OS transport over
//! `POST /stats/transport` (`{"mobile": bool}`) whenever it changes,
//! and bytes added while the flag is set count as mobile data. The
//! tagging is an attribution of the moment the bytes are *recorded* —
//! the ant summary arrives every ~5 minutes cumulative, so a transport
//! flip inside that window attributes the whole delta to the newer
//! transport; an accepted approximation.

use std::collections::{BTreeMap, HashMap};
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

/// How many daily buckets are kept (rolling window; a 7-day graph with
/// a month of scroll-back headroom).
const DAYS_KEPT: usize = 35;

/// Up/down period totals for one component, with the mobile-tagged
/// share (`mob_* <= rx/tx` by construction).
#[derive(Default)]
pub struct ComponentUsage {
    pub rx: AtomicU64,
    pub tx: AtomicU64,
    pub mob_rx: AtomicU64,
    pub mob_tx: AtomicU64,
}

impl ComponentUsage {
    fn add(&self, tx: u64, rx: u64, mobile: bool) {
        self.tx.fetch_add(tx, Ordering::Relaxed);
        self.rx.fetch_add(rx, Ordering::Relaxed);
        if mobile {
            self.mob_tx.fetch_add(tx, Ordering::Relaxed);
            self.mob_rx.fetch_add(rx, Ordering::Relaxed);
        }
    }
    fn zero(&self) {
        self.tx.store(0, Ordering::Relaxed);
        self.rx.store(0, Ordering::Relaxed);
        self.mob_tx.store(0, Ordering::Relaxed);
        self.mob_rx.store(0, Ordering::Relaxed);
    }
    fn json(&self) -> serde_json::Value {
        serde_json::json!({
            "rx": self.rx.load(Ordering::Relaxed),
            "tx": self.tx.load(Ordering::Relaxed),
            "mob_rx": self.mob_rx.load(Ordering::Relaxed),
            "mob_tx": self.mob_tx.load(Ordering::Relaxed),
        })
    }
}

/// One component's share of a daily bucket.
#[derive(Default, Clone, Copy)]
struct DaySplit {
    rx: u64,
    tx: u64,
    mob_rx: u64,
    mob_tx: u64,
}

impl DaySplit {
    fn add(&mut self, tx: u64, rx: u64, mobile: bool) {
        self.tx += tx;
        self.rx += rx;
        if mobile {
            self.mob_tx += tx;
            self.mob_rx += rx;
        }
    }
    fn json(&self) -> serde_json::Value {
        serde_json::json!({
            "rx": self.rx, "tx": self.tx,
            "mob_rx": self.mob_rx, "mob_tx": self.mob_tx,
        })
    }
    fn from_json(v: &serde_json::Value) -> Self {
        let g = |k: &str| v[k].as_u64().unwrap_or(0);
        Self {
            rx: g("rx"),
            tx: g("tx"),
            mob_rx: g("mob_rx"),
            mob_tx: g("mob_tx"),
        }
    }
}

/// One local day's usage, per component.
#[derive(Default, Clone, Copy)]
struct DayBucket {
    ant: DaySplit,
    mywatch: DaySplit,
    channels: DaySplit,
}

/// The three metered components.
#[derive(Clone, Copy)]
pub enum Component {
    MyWatch,
    Channels,
}

/// Day-bucket slot (ant has no `Component` variant — it is not an x0x
/// agent — but shares a day bucket).
#[derive(Clone, Copy)]
enum DaySlot {
    Ant,
    MyWatch,
    Channels,
}

/// Today's bucket key, from the device's LOCAL calendar (`2026-09-23`).
/// BTreeMap ordering == chronological ordering by construction.
pub(crate) fn today_key() -> String {
    chrono::Local::now().format("%Y-%m-%d").to_string()
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
    /// Whether the device is currently on mobile data, as last reported
    /// by the app (`POST /stats/transport`). Not persisted: the app
    /// re-reports at every launch, and the pre-report default (false)
    /// only ever under-tags, never over-tags.
    mobile: AtomicBool,
    /// Per-local-day buckets, key `YYYY-MM-DD` (ascending == oldest
    /// first). Survive `reset()`; pruned to [`DAYS_KEPT`].
    days: Mutex<BTreeMap<String, DayBucket>>,
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
            mobile: AtomicBool::new(false),
            days: Mutex::new(BTreeMap::new()),
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
                    c.mob_tx
                        .store(v[key]["mob_tx"].as_u64().unwrap_or(0), Ordering::Relaxed);
                    c.mob_rx
                        .store(v[key]["mob_rx"].as_u64().unwrap_or(0), Ordering::Relaxed);
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
                if let Some(saved) = v["days"].as_object() {
                    let mut days = self.days.lock().unwrap();
                    for (day, b) in saved {
                        days.insert(
                            day.clone(),
                            DayBucket {
                                ant: DaySplit::from_json(&b["ant"]),
                                mywatch: DaySplit::from_json(&b["mywatch"]),
                                channels: DaySplit::from_json(&b["channels"]),
                            },
                        );
                    }
                    while days.len() > DAYS_KEPT {
                        days.pop_first();
                    }
                }
            }
        }
        *self.path.lock().unwrap() = Some(file);
    }

    /// The app reported the OS transport (`POST /stats/transport`).
    pub fn set_mobile(&self, mobile: bool) {
        self.mobile.store(mobile, Ordering::Relaxed);
    }

    /// Whether adds are currently tagged as mobile data.
    pub fn on_mobile(&self) -> bool {
        self.mobile.load(Ordering::Relaxed)
    }

    /// Fold bytes into a day bucket (today's unless a test passes its
    /// own key), pruning the window.
    fn add_day_keyed(&self, day: &str, slot: DaySlot, tx: u64, rx: u64, mobile: bool) {
        let mut days = self.days.lock().unwrap();
        let bucket = days.entry(day.to_string()).or_default();
        match slot {
            DaySlot::Ant => bucket.ant.add(tx, rx, mobile),
            DaySlot::MyWatch => bucket.mywatch.add(tx, rx, mobile),
            DaySlot::Channels => bucket.channels.add(tx, rx, mobile),
        }
        while days.len() > DAYS_KEPT {
            days.pop_first();
        }
        self.dirty.store(true, Ordering::Relaxed);
    }

    fn add_day(&self, slot: DaySlot, tx: u64, rx: u64, mobile: bool) {
        self.add_day_keyed(&today_key(), slot, tx, rx, mobile);
    }

    /// Add x0x sampler deltas for one agent.
    pub fn add_x0x(&self, component: Component, tx: u64, rx: u64) {
        if tx == 0 && rx == 0 {
            return;
        }
        let mobile = self.on_mobile();
        self.component(component).add(tx, rx, mobile);
        let slot = match component {
            Component::MyWatch => DaySlot::MyWatch,
            Component::Channels => DaySlot::Channels,
        };
        self.add_day(slot, tx, rx, mobile);
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
        let mobile = self.on_mobile();
        self.ant.add(dtx, drx, mobile);
        if dtx > 0 || drx > 0 {
            self.add_day(DaySlot::Ant, dtx, drx, mobile);
        }
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
        let sum = |pick: fn(&ComponentUsage) -> &AtomicU64| {
            pick(&self.ant).load(Ordering::Relaxed)
                + pick(&self.mywatch).load(Ordering::Relaxed)
                + pick(&self.channels).load(Ordering::Relaxed)
        };
        let mut ant = self.ant.json();
        ant["media_rx"] = self.media_rx.load(Ordering::Relaxed).into();
        ant["stale_secs"] = serde_json::json!(self.ant_stale_secs());
        let days: Vec<serde_json::Value> = self
            .days
            .lock()
            .unwrap()
            .iter()
            .map(|(day, b)| {
                serde_json::json!({
                    "day": day,
                    "ant": b.ant.json(),
                    "mywatch": b.mywatch.json(),
                    "channels": b.channels.json(),
                })
            })
            .collect();
        serde_json::json!({
            "period_start_ms": self.period_start_ms.load(Ordering::Relaxed),
            "total": {
                "rx": sum(|c| &c.rx),
                "tx": sum(|c| &c.tx),
                "mob_rx": sum(|c| &c.mob_rx),
                "mob_tx": sum(|c| &c.mob_tx),
            },
            "ant": ant,
            "mywatch": self.mywatch.json(),
            "channels": self.channels.json(),
            "days": days,
        })
    }

    /// `POST /stats/reset`: zero every component at once (one period,
    /// one mental model), stamp a fresh period start, persist. The
    /// daily buckets deliberately SURVIVE — reset means "start counting
    /// the period from now", not "forget the history graph".
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
        let days: serde_json::Map<String, serde_json::Value> = self
            .days
            .lock()
            .unwrap()
            .iter()
            .map(|(day, b)| {
                (
                    day.clone(),
                    serde_json::json!({
                        "ant": b.ant.json(),
                        "mywatch": b.mywatch.json(),
                        "channels": b.channels.json(),
                    }),
                )
            })
            .collect();
        let body = serde_json::json!({
            "period_start_ms": self.period_start_ms.load(Ordering::Relaxed),
            "ant": self.ant.json(),
            "mywatch": self.mywatch.json(),
            "channels": self.channels.json(),
            "media_rx": self.media_rx.load(Ordering::Relaxed),
            "days": days,
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
        u.set_mobile(true);
        u.add_x0x(Component::Channels, 33, 44);
        u.set_mobile(false);
        u.record_ant_summary(55, 66);
        u.save_if_dirty();

        let loaded = DataUsage::new();
        loaded.init_storage(&dir);
        assert_eq!(loaded.mywatch.tx.load(Ordering::Relaxed), 11);
        assert_eq!(loaded.mywatch.rx.load(Ordering::Relaxed), 22);
        assert_eq!(loaded.mywatch.mob_tx.load(Ordering::Relaxed), 0);
        assert_eq!(loaded.channels.tx.load(Ordering::Relaxed), 33);
        assert_eq!(loaded.channels.rx.load(Ordering::Relaxed), 44);
        // The mobile-tagged share survives the reload.
        assert_eq!(loaded.channels.mob_tx.load(Ordering::Relaxed), 33);
        assert_eq!(loaded.channels.mob_rx.load(Ordering::Relaxed), 44);
        assert_eq!(loaded.ant.tx.load(Ordering::Relaxed), 55);
        assert_eq!(loaded.ant.rx.load(Ordering::Relaxed), 66);
        assert_eq!(
            loaded.period_start_ms.load(Ordering::Relaxed),
            u.period_start_ms.load(Ordering::Relaxed)
        );
        // A fresh process has no summary yet: stale is unknown.
        assert!(loaded.ant_stale_secs().is_none());
        // The daily buckets came back too.
        {
            let days = loaded.days.lock().unwrap();
            let today = days.get(&today_key()).copied().unwrap();
            assert_eq!(today.mywatch.rx, 22);
            assert_eq!(today.channels.mob_rx, 44);
            assert_eq!(today.ant.rx, 66);
        }

        // Reset zeroes the period (mobile share included) and stamps a
        // new period — but the daily history SURVIVES.
        loaded.reset();
        assert_eq!(loaded.ant.tx.load(Ordering::Relaxed), 0);
        assert_eq!(loaded.mywatch.rx.load(Ordering::Relaxed), 0);
        assert_eq!(loaded.channels.tx.load(Ordering::Relaxed), 0);
        assert_eq!(loaded.channels.mob_rx.load(Ordering::Relaxed), 0);
        let v = loaded.stats_json();
        assert_eq!(v["total"]["rx"].as_u64(), Some(0));
        assert_eq!(v["total"]["mob_rx"].as_u64(), Some(0));
        assert_eq!(v["days"].as_array().unwrap().len(), 1);
        // The reset persisted: a re-load sees zeros AND the history.
        let reloaded = DataUsage::new();
        reloaded.init_storage(&dir);
        assert_eq!(reloaded.ant.rx.load(Ordering::Relaxed), 0);
        assert_eq!(
            reloaded.days.lock().unwrap().get(&today_key()).unwrap().ant.rx,
            66
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn transport_tagging_splits_mobile_bytes_and_days() {
        let u = DataUsage::new();
        u.add_x0x(Component::MyWatch, 10, 20);
        u.set_mobile(true);
        u.add_x0x(Component::MyWatch, 1, 2);
        u.record_ant_summary(100, 200);
        u.set_mobile(false);
        u.add_x0x(Component::Channels, 5, 6);
        let v = u.stats_json();
        assert_eq!(v["mywatch"]["tx"].as_u64(), Some(11));
        assert_eq!(v["mywatch"]["mob_tx"].as_u64(), Some(1));
        assert_eq!(v["mywatch"]["mob_rx"].as_u64(), Some(2));
        assert_eq!(v["ant"]["mob_rx"].as_u64(), Some(200));
        assert_eq!(v["channels"]["mob_rx"].as_u64(), Some(0));
        assert_eq!(v["total"]["mob_rx"].as_u64(), Some(202));
        assert_eq!(v["total"]["mob_tx"].as_u64(), Some(101));
        // Everything above landed in today's single day bucket.
        let days = v["days"].as_array().unwrap();
        assert_eq!(days.len(), 1);
        let d = &days[0];
        assert_eq!(d["day"].as_str(), Some(today_key().as_str()));
        assert_eq!(d["mywatch"]["rx"].as_u64(), Some(22));
        assert_eq!(d["mywatch"]["mob_rx"].as_u64(), Some(2));
        assert_eq!(d["ant"]["rx"].as_u64(), Some(200));
        assert_eq!(d["ant"]["mob_rx"].as_u64(), Some(200));
        assert_eq!(d["channels"]["rx"].as_u64(), Some(6));
        assert_eq!(d["channels"]["mob_rx"].as_u64(), Some(0));
    }

    #[test]
    fn day_buckets_prune_to_the_window() {
        let u = DataUsage::new();
        for i in 0..(DAYS_KEPT + 5) {
            u.add_day_keyed(&format!("day-{i:03}"), DaySlot::Ant, 1, 1, false);
        }
        let days = u.days.lock().unwrap();
        assert_eq!(days.len(), DAYS_KEPT);
        // Oldest keys were dropped, newest kept.
        assert!(!days.contains_key("day-000"));
        assert!(days.contains_key(&format!("day-{:03}", DAYS_KEPT + 4)));
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
