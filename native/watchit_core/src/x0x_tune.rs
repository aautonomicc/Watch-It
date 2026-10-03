//! Post-join tuning for the My W@tch x0x agent.
//!
//! x0x 0.40.4's presence beacons fan a ~5.5KB ML-DSA-signed record to
//! every open QUIC connection per joined group every 30s — the one
//! idle-bandwidth hotspot the upstream issue-#380 campaign left
//! untouched. Watch-It has no feature riding them: the My W@tch device
//! rows' online dot comes from the CRDT store heartbeat, and the art
//! transfer only uses `Agent::presence()` to ORDER candidate owners
//! (it tries them regardless). The `AgentBuilder` exposes no
//! `enable_beacons` knob, but `join_network()` starts the broadcaster
//! synchronously, so stopping it right afterwards through the public
//! presence API is race-free and spares us a vendored x0x patch.
//! Inbound beacons from unquieted peers still process normally.

#[cfg(any(
    target_os = "linux",
    target_os = "windows",
    target_os = "macos",
    target_os = "android"
))]
pub(crate) async fn quiet_agent(agent: &x0x::Agent, label: &str) {
    if let Some(pw) = agent.presence_system() {
        match pw.manager().stop_beacons().await {
            Ok(()) => tracing::info!("{label}: presence beacons stopped"),
            Err(e) => tracing::warn!("{label}: stopping presence beacons failed: {e}"),
        }
    } else {
        tracing::warn!("{label}: no presence system; beacons assumed off");
    }
    // Leaf participation (the client default since x0x 0.39.8) is the
    // biggest idle-traffic win — it drops pass-through relaying of
    // unsubscribed topics. Log the live selection so any config drift
    // back to full relay mode is visible in the field.
    match gossip_mode(agent) {
        Some(mode) => {
            if mode == "leaf" {
                tracing::info!("{label}: gossip participation {mode}");
            } else {
                tracing::warn!("{label}: gossip participation {mode} (expected leaf)");
            }
        }
        None => tracing::warn!("{label}: gossip participation unknown"),
    }
}

/// Live Leaf/Full selection of this agent's gossip layer, for status
/// JSON ("leaf" on every correctly configured client).
#[cfg(any(
    target_os = "linux",
    target_os = "windows",
    target_os = "macos",
    target_os = "android"
))]
pub(crate) fn gossip_mode(agent: &x0x::Agent) -> Option<String> {
    agent
        .gossip_participation()
        .map(|p| p.mode.to_string())
}

/// Gossip config for the My W@tch agent, with x0x 0.46.0's opt-in Leaf
/// egress controls (upstream tracker #504) behind environment variables.
///
/// Default (no env set) is the stock config: the egress byte budget
/// runs as an observe-only METER, so shipped behavior is unchanged.
/// `WATCHIT_X0X_BYTE_POLICY=shed_normal` opts the agent into refusing
/// normal-class RELAY sends above the hard budget — upstream guarantees
/// own publishes, targeted sends and Critical topics are never shed, so
/// My W@tch sync docs and the chunked art-transfer DMs are untouched by
/// construction. `WATCHIT_X0X_EGRESS_HARD_BPS` / `_SOFT_BPS` override
/// the thresholds (bytes/sec; x0x defaults 131072 / 65536).
/// Harness/devserver experiment only for now — deliberately NOT a
/// Settings surface while upstream labels the policy experimental.
#[cfg(any(
    target_os = "linux",
    target_os = "windows",
    target_os = "macos",
    target_os = "android"
))]
pub(crate) fn gossip_config(label: &str) -> x0x::gossip::GossipConfig {
    let mut cfg = x0x::gossip::GossipConfig::default();
    if let Some(n) = std::env::var("WATCHIT_X0X_EGRESS_SOFT_BPS")
        .ok()
        .and_then(|v| v.parse().ok())
    {
        cfg.leaf_egress_soft_bytes_per_sec = n;
    }
    if let Some(n) = std::env::var("WATCHIT_X0X_EGRESS_HARD_BPS")
        .ok()
        .and_then(|v| v.parse().ok())
    {
        cfg.leaf_egress_hard_bytes_per_sec = n;
    }
    if std::env::var("WATCHIT_X0X_BYTE_POLICY").as_deref() == Ok("shed_normal") {
        cfg.byte_policy = x0x::gossip::LeafBytePolicy::ShedNormal;
        tracing::info!(
            "{label}: EXPERIMENTAL shed_normal byte policy ON (soft {} / hard {} B/s)",
            cfg.leaf_egress_soft_bytes_per_sec,
            cfg.leaf_egress_hard_bytes_per_sec,
        );
    }
    cfg
}

/// Bounded agent shutdown for the pause/switch-off/unlink paths.
/// x0x's `Agent::shutdown` can hang indefinitely once an agent gets
/// stuck "disconnecting" (seen live in the 2026-09-05 idle test) —
/// callers must NEVER await it while holding the phase mutex, or every
/// status route wedges with it. This gives the graceful path a bounded
/// window, then abandons the future and lets the caller drop the agent
/// Arc: a leaked background task beats a wedged app.
#[cfg(any(
    target_os = "linux",
    target_os = "windows",
    target_os = "macos",
    target_os = "android"
))]
pub(crate) async fn shutdown_agent(agent: &x0x::Agent, label: &str) {
    const GRACE: std::time::Duration = std::time::Duration::from_secs(10);
    if tokio::time::timeout(GRACE, agent.shutdown()).await.is_err() {
        tracing::warn!(
            "{label}: agent shutdown still hanging after {GRACE:?} — dropping it"
        );
    }
}
