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

/// Gossip config for the My W@tch agent, with x0x 0.46.0's Leaf egress
/// controls (upstream tracker #504).
///
/// Default is `shed_normal`: the agent refuses normal-class RELAY
/// sends above the hard egress budget. Upstream guarantees own
/// publishes, targeted sends and Critical topics are never shed, so My
/// W@tch sync docs and the chunked art-transfer DMs are untouched by
/// construction — only pass-through relay traffic for other peers is
/// capped. The 2026-10-03 idle A/B measured 52 MB/min combined vs 142
/// on the stock observe-only meter (and 322 on x0x 0.45.0) with no
/// sync downside, so Watch-It ships it ON despite upstream's
/// experimental label (field escape hatch below).
/// `WATCHIT_X0X_BYTE_POLICY=observe` reverts to the stock observe-only
/// METER; `WATCHIT_X0X_EGRESS_HARD_BPS` / `_SOFT_BPS` override the
/// thresholds (bytes/sec; x0x defaults 131072 / 65536).
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
    match std::env::var("WATCHIT_X0X_BYTE_POLICY").as_deref() {
        Ok("observe") | Ok("observe_only") | Ok("off") => {
            cfg.byte_policy = x0x::gossip::LeafBytePolicy::ObserveOnly;
            tracing::info!(
                "{label}: shed_normal byte policy OFF by env — observe-only meter"
            );
        }
        _ => {
            cfg.byte_policy = x0x::gossip::LeafBytePolicy::ShedNormal;
            tracing::info!(
                "{label}: shed_normal byte policy ON (soft {} / hard {} B/s)",
                cfg.leaf_egress_soft_bytes_per_sec,
                cfg.leaf_egress_hard_bytes_per_sec,
            );
        }
    }
    cfg
}

#[cfg(all(
    test,
    any(
        target_os = "linux",
        target_os = "windows",
        target_os = "macos",
        target_os = "android"
    )
))]
mod tests {
    use super::*;

    /// shed_normal is the shipped DEFAULT (the 2026-10-03 idle A/B win);
    /// `WATCHIT_X0X_BYTE_POLICY=observe` is the field escape hatch back
    /// to the stock observe-only meter. One test so the env mutations
    /// can't race a parallel sibling.
    #[test]
    fn byte_policy_defaults_shed_normal_with_observe_escape_hatch() {
        std::env::remove_var("WATCHIT_X0X_BYTE_POLICY");
        assert_eq!(
            gossip_config("test").byte_policy,
            x0x::gossip::LeafBytePolicy::ShedNormal
        );
        std::env::set_var("WATCHIT_X0X_BYTE_POLICY", "observe");
        assert_eq!(
            gossip_config("test").byte_policy,
            x0x::gossip::LeafBytePolicy::ObserveOnly
        );
        // Unknown values keep the shipped default.
        std::env::set_var("WATCHIT_X0X_BYTE_POLICY", "shed_normal");
        assert_eq!(
            gossip_config("test").byte_policy,
            x0x::gossip::LeafBytePolicy::ShedNormal
        );
        std::env::remove_var("WATCHIT_X0X_BYTE_POLICY");
    }
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
