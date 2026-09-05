//! Post-join tuning shared by the My W@tch and Channels x0x agents.
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
