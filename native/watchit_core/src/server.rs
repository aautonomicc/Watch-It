//! Localhost HTTP server the media player streams from.
//!
//! `GET /xor/{address}` serves the content behind a locally stored root
//! data map as decrypted bytes with byte-range support
//! (`Accept-Ranges: bytes`), which is what libmpv needs for seeking; a
//! missing map fast-fails (maps arrive at import time — datamap-first
//! entry model). `POST /datamap` imports an ant-cli `.datamap` file and
//! returns its derived address; `GET /datamap/{addr}` exports the stored
//! map in the same format. `GET /health` reports client connection state;
//! `POST /reconnect` nudges the reconnect supervisor (phone wake, cable
//! replug) so recovery does not wait for the next poll interval.

use axum::body::{Body, Bytes};
use axum::extract::{DefaultBodyLimit, Path, Request};
use axum::http::{header, HeaderMap, Method, StatusCode};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::Router;
use tokio_stream::wrappers::ReceiverStream;
use tokio_stream::StreamExt as _;

use ant_core::data::DataMap;

use crate::engine::Engine;

/// Serialized root maps are ~100 bytes per content chunk, so even a
/// terabyte-scale file stays far under this — anything bigger is not a
/// data map (zip-bomb guard on the bundle import path).
const MAX_ROOTMAP_BYTES: usize = 32 * 1024 * 1024;

/// Full router with the wallet/upload routes guarded by a shared-secret
/// header. Those endpoints spend money or manage the wallet key, and the
/// server port is reachable by every local process — only the app itself
/// (which gets the token over FFI) may call them. The streaming/import
/// routes stay open: libmpv fetches them without custom headers.
pub fn router_with_auth(engine: &'static Engine, token: &'static str) -> Router {
    open_router(engine).merge(protected_router(engine).layer(middleware::from_fn(
        move |req: Request, next: Next| async move {
            let presented = req
                .headers()
                .get("x-watchit-auth")
                .and_then(|v| v.to_str().ok());
            if presented == Some(token) {
                next.run(req).await
            } else {
                (StatusCode::UNAUTHORIZED, "auth token required").into_response()
            }
        },
    )))
}

/// Tokenless router (tests, devserver without WATCHIT_AUTH_TOKEN).
pub fn router(engine: &'static Engine) -> Router {
    open_router(engine).merge(protected_router(engine))
}

fn protected_router(engine: &'static Engine) -> Router {
    Router::new()
        .route(
            "/wallet",
            get(move || wallet_status(engine))
                .post(move |body: Bytes| wallet_import(engine, body))
                .delete(move || wallet_delete(engine)),
        )
        .route("/wallet/generate", post(wallet_generate))
        // Pause/resume all network use. Protected: only the app should
        // be able to silence (or wake) the user's network client.
        .route(
            "/network/pause",
            post(move |body: Bytes| set_network_pause(engine, body)),
        )
        .route("/wallet/balances", get(move || wallet_balances(engine)))
        // Data-usage period counters. Protected like the pause switch:
        // usage patterns are the user's own business, and reset mutates
        // state. Always fully populated — even while the network is
        // paused (/health collapses to {"state":"paused"} then, which is
        // why the Data usage screen gets its own route).
        .route("/stats", get(stats))
        .route("/stats/reset", post(stats_reset))
        .route(
            "/upload/estimate",
            post(move |body: Bytes| upload_estimate(engine, body)),
        )
        .route("/upload", post(move |body: Bytes| upload_start(engine, body)))
        .route(
            "/upload/{id}",
            get(move |path: Path<u64>| upload_status(engine, path)),
        )
        // My W@tch device linking. Protected: the invite secret admits a
        // device to the user's private link, so only the app may read it.
        .route(
            "/mywatch",
            get(move || mywatch_status(engine)).delete(move || mywatch_unlink(engine)),
        )
        .route(
            "/mywatch/link",
            post(move |body: Bytes| mywatch_link(engine, body)),
        )
        .route(
            "/mywatch/join",
            post(move |body: Bytes| mywatch_join(engine, body)),
        )
        .route("/mywatch/invite", get(move || mywatch_invite(engine)))
        .route(
            "/mywatch/enabled",
            post(move |body: Bytes| mywatch_set_enabled(engine, body)),
        )
        .route(
            "/mywatch/announce",
            post(move |body: Bytes| mywatch_announce(engine, body)),
        )
        .route(
            "/mywatch/sync",
            get(move || mywatch_sync_get(engine))
                .post(move |body: Bytes| mywatch_sync_put(engine, body)),
        )
        .route(
            "/mywatch/art/index",
            post(move |body: Bytes| mywatch_art_index(engine, body)),
        )
        .route(
            "/mywatch/art/fetch",
            post(move |body: Bytes| mywatch_art_fetch(engine, body)),
        )
        // Channels. Protected: creating/publishing spends money and
        // handles the channel signing key; even subscribe mutates
        // persistent state only the app should touch.
        .route("/channels", get(move || channels_status(engine)))
        .route(
            "/channel/enabled",
            post(move |body: Bytes| channel_set_enabled(engine, body)),
        )
        .route("/channel", axum::routing::delete(move || channel_remove(engine)))
        .route("/channel/generate", post(channel_generate))
        .route(
            "/channel/create",
            post(move |body: Bytes| channel_create(engine, body)),
        )
        .route(
            "/channel/restore",
            post(move |body: Bytes| channel_restore(engine, body)),
        )
        .route(
            "/channel/meta",
            post(move |body: Bytes| channel_meta(engine, body)),
        )
        .route(
            "/channel/publish",
            post(move |body: Bytes| channel_publish(engine, body)),
        )
        .route(
            "/channel/subscribe",
            post(move |body: Bytes| channel_subscribe(engine, body)),
        )
        .route(
            "/channel/subscribe/{pubkey}",
            axum::routing::delete(move |path: Path<String>| {
                channel_unsubscribe(engine, path)
            }),
        )
        .route(
            "/channel/manifest/{addr}",
            get(move |method: Method, path: Path<String>, headers: HeaderMap| {
                channel_manifest(engine, method, path, headers)
            }),
        )
}

fn open_router(engine: &'static Engine) -> Router {
    Router::new()
        .route("/health", get(move || health(engine)))
        .route("/reconnect", post(move || reconnect(engine)))
        .route(
            "/resolve/{addr}",
            get(move |path: Path<String>| resolve_map(engine, path)),
        )
        .route(
            "/datamap",
            post(move |body: Bytes| import_datamap(engine, body))
                .layer(DefaultBodyLimit::max(MAX_ROOTMAP_BYTES)),
        )
        .route(
            "/datamap/{addr}",
            get(move |path: Path<String>| get_datamap(engine, path)),
        )
        .route(
            "/rootmap/{addr}",
            get(move |path: Path<String>| get_rootmap(engine, path))
                .put(move |path: Path<String>, body: Bytes| {
                    put_rootmap(engine, path, body)
                })
                .layer(DefaultBodyLimit::max(MAX_ROOTMAP_BYTES)),
        )
        .route(
            "/xor/{addr}",
            get(move |method: Method, path: Path<String>, headers: HeaderMap| {
                serve_xor(engine, method, path, headers)
            }),
        )
}

async fn health(engine: &'static Engine) -> Response {
    use std::sync::atomic::Ordering;
    let body = if engine.paused() {
        // User-requested quiet: not an error, not "connecting" — the UI
        // shows it as its own state with no spinner.
        serde_json::json!({ "state": "paused" })
    } else if engine.is_ready() {
        serde_json::json!({
            "state": "ready",
            "peers": engine.connected_peer_count().await,
            "fetched_chunks": crate::engine::FETCHED_CHUNKS.load(Ordering::Relaxed),
            "fetched_bytes": crate::engine::FETCHED_BYTES.load(Ordering::Relaxed),
            "cache_hit_chunks": crate::engine::CACHE_HIT_CHUNKS.load(Ordering::Relaxed),
            "cache_bytes": crate::engine::cache_resident_bytes(),
            "stored_maps": engine.stored_maps(),
        })
    } else {
        // The engine retries forever in the background, so a recorded
        // error is a *transient* condition of the connecting state, not a
        // terminal one — report it as detail so the UI can show why.
        serde_json::json!({
            "state": "connecting",
            "attempts": engine.attempts(),
            "message": engine.last_error(),
        })
    };
    ([(header::CONTENT_TYPE, "application/json")], body.to_string()).into_response()
}

/// `GET /stats` — the Data usage screen's period counters (per-component
/// up/down bytes since the last reset; see datausage.rs).
async fn stats() -> Response {
    let body = crate::datausage::usage().stats_json();
    ([(header::CONTENT_TYPE, "application/json")], body.to_string()).into_response()
}

/// `POST /stats/reset` — zero every component, stamp a fresh period
/// start, persist; returns the fresh `/stats` body.
async fn stats_reset() -> Response {
    crate::datausage::usage().reset();
    tracing::info!("data-usage period reset");
    stats().await
}

/// Kick the reconnect supervisor: cancel its current backoff sleep (or
/// poll interval) so a connect attempt starts now. No-op in effect while
/// connected with peers — the supervisor just re-samples and carries on.
/// Returns the current health JSON so the caller sees where things stand.
async fn reconnect(engine: &'static Engine) -> Response {
    engine.kick_reconnect();
    health(engine).await
}

/// `POST /network/pause` — `{"paused": bool}`: pause or resume all
/// network use (the Settings toggle). Pausing evicts the client and
/// parks the reconnect supervisor; resuming dials again immediately.
/// Returns the resulting health JSON so the caller sees the new state.
async fn set_network_pause(engine: &'static Engine, body: Bytes) -> Response {
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(&body) else {
        return (StatusCode::BAD_REQUEST, "body must be JSON").into_response();
    };
    let Some(paused) = v["paused"].as_bool() else {
        return (StatusCode::BAD_REQUEST, "\"paused\" must be a boolean")
            .into_response();
    };
    engine.set_paused(paused);
    tracing::info!("network pause set to {paused}");
    health(engine).await
}

/// Size/chunk-count of a locally stored root map (the download manager's
/// pre-fill probe). Local only — the network map fetch was deleted with
/// the datamap-first cleanup (docs/PLAN-datamap-privacy.md release 3);
/// an address whose map was never imported is 404, not resolvable.
async fn resolve_map(engine: &'static Engine, Path(addr_hex): Path<String>) -> Response {
    let mut addr = [0u8; 32];
    if hex::decode_to_slice(addr_hex.trim(), &mut addr).is_err() {
        return (StatusCode::BAD_REQUEST, "address must be 64 hex chars").into_response();
    }
    match engine.stored_root_map(&addr) {
        Some(root) => {
            let body = serde_json::json!({
                "size": root.original_file_size() as u64,
                "chunks": root.len(),
            });
            ([(header::CONTENT_TYPE, "application/json")], body.to_string())
                .into_response()
        }
        None => (
            StatusCode::NOT_FOUND,
            "data map missing — re-import the list or bundle",
        )
            .into_response(),
    }
}

/// Import a `.datamap` file (ant-cli private-upload output): parse the
/// bare serialized map — msgpack canonically, legacy ant-gui JSON
/// when the first byte is `{` (the same sniff as ant-core's
/// `read_datamap`) — derive its content address, and store the root map.
/// The derived address is the entry's identity everywhere; for a file
/// that was uploaded publicly it equals the public XOR address, so old
/// entries and new imports of the same content coincide.
///
/// ant-cli persists the SHRUNK map, so for any file over 3 chunks
/// (~12 MiB) the file carries a child map — the normal case for real
/// media, not an error. Its own hash is the address (that is exactly
/// what the uploader computed); the root map is recovered by fetching
/// the few wrapper chunks the upload stored — the only import path that
/// touches the network, once per map, then verified against the address
/// before storing.
async fn import_datamap(engine: &'static Engine, body: Bytes) -> Response {
    let map: Result<DataMap, String> = if body.first() == Some(&b'{') {
        serde_json::from_slice(&body).map_err(|e| format!("JSON decode failed: {e}"))
    } else {
        rmp_serde::from_slice(&body).map_err(|e| format!("msgpack decode failed: {e}"))
    };
    let map = match map {
        Ok(m) => m,
        Err(e) => {
            return (StatusCode::BAD_REQUEST, format!("not a data map: {e}"))
                .into_response()
        }
    };
    let (addr, root) = if map.is_child() {
        let addr = match crate::verify::shrunk_map_address(&map) {
            Ok(a) => a,
            Err(e) => return (StatusCode::UNPROCESSABLE_ENTITY, e).into_response(),
        };
        // Re-import of a known map: the stored root already went through
        // expand+verify — succeed offline instead of re-fetching.
        if let Some(root) = engine.stored_root_map(&addr) {
            (addr, root)
        } else {
            if !engine.is_ready() {
                return (
                    StatusCode::SERVICE_UNAVAILABLE,
                    "this data map needs a one-time network lookup to finish \
                     importing, and the Autonomi client is not connected yet \
                     — try again once connected",
                )
                    .into_response();
            }
            let root = match engine.expand_child_map(map).await {
                Ok(r) => r,
                Err(e) => {
                    return (
                        StatusCode::BAD_GATEWAY,
                        format!("the network lookup for this data map failed: {e}"),
                    )
                        .into_response()
                }
            };
            if let Err(e) = crate::verify::verify_root_map(&addr, &root) {
                return (StatusCode::UNPROCESSABLE_ENTITY, e).into_response();
            }
            (addr, root)
        }
    } else {
        match crate::verify::derive_address(&map) {
            Ok(a) => (a, map),
            Err(e) => return (StatusCode::UNPROCESSABLE_ENTITY, e).into_response(),
        }
    };
    engine.store_root_map(addr, &root);
    let body = serde_json::json!({
        "address": hex::encode(addr),
        "size": root.original_file_size() as u64,
        "chunks": root.len(),
    });
    ([(header::CONTENT_TYPE, "application/json")], body.to_string()).into_response()
}

/// Export side of `.datamap` bundle members: the locally stored root map
/// in ant-cli's canonical wire format (bare msgpack), byte-usable as a
/// standalone `.datamap` file. 404 when the map was never stored.
async fn get_datamap(engine: &'static Engine, Path(addr_hex): Path<String>) -> Response {
    let mut addr = [0u8; 32];
    if hex::decode_to_slice(addr_hex.trim(), &mut addr).is_err() {
        return (StatusCode::BAD_REQUEST, "address must be 64 hex chars").into_response();
    }
    match engine.stored_root_map(&addr) {
        Some(map) => match rmp_serde::to_vec(&map) {
            Ok(bytes) => (
                [(header::CONTENT_TYPE, "application/octet-stream")],
                bytes,
            )
                .into_response(),
            Err(e) => {
                (StatusCode::INTERNAL_SERVER_ERROR, format!("serialize failed: {e}"))
                    .into_response()
            }
        },
        None => (StatusCode::NOT_FOUND, "no stored data map").into_response(),
    }
}

/// Export side of bundle root maps: the locally stored root map for an
/// address in `DataMap::to_bytes` form, 404 when it was never resolved
/// (the exporter then skips it — never a network resolve from here).
async fn get_rootmap(engine: &'static Engine, Path(addr_hex): Path<String>) -> Response {
    let mut addr = [0u8; 32];
    if hex::decode_to_slice(addr_hex.trim(), &mut addr).is_err() {
        return (StatusCode::BAD_REQUEST, "address must be 64 hex chars").into_response();
    }
    match engine.stored_root_map(&addr) {
        Some(map) => match map.to_bytes() {
            Ok(bytes) => (
                [(header::CONTENT_TYPE, "application/octet-stream")],
                bytes,
            )
                .into_response(),
            Err(e) => {
                (StatusCode::INTERNAL_SERVER_ERROR, format!("serialize failed: {e}"))
                    .into_response()
            }
        },
        None => (StatusCode::NOT_FOUND, "no stored root map").into_response(),
    }
}

/// Import side of bundle root maps: verify the supplied map offline
/// (verify-then-store, see `verify::verify_root_map`) and persist it.
/// 422 on any verification failure so the importer falls back to a
/// normal network resolve for that entry.
async fn put_rootmap(
    engine: &'static Engine,
    Path(addr_hex): Path<String>,
    body: Bytes,
) -> Response {
    let mut addr = [0u8; 32];
    if hex::decode_to_slice(addr_hex.trim(), &mut addr).is_err() {
        return (StatusCode::BAD_REQUEST, "address must be 64 hex chars").into_response();
    }
    let map = match DataMap::from_bytes(&body) {
        Ok(m) => m,
        Err(e) => {
            return (StatusCode::BAD_REQUEST, format!("not a data map: {e}"))
                .into_response()
        }
    };
    match engine.import_root_map(addr, map) {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => {
            tracing::warn!("rootmap import rejected for {addr_hex}: {e}");
            (StatusCode::UNPROCESSABLE_ENTITY, e).into_response()
        }
    }
}

fn json_ok(body: serde_json::Value) -> Response {
    ([(header::CONTENT_TYPE, "application/json")], body.to_string()).into_response()
}

/// First keychain touch can block on the Secret Service D-Bus round
/// trip, so wallet-store reads/writes run off the async workers.
async fn load_wallet(engine: &'static Engine) -> Option<(String, crate::wallet::Storage)> {
    tokio::task::spawn_blocking(move || engine.wallet.load())
        .await
        .ok()
        .flatten()
}

/// `GET /wallet` — configured?, address, storage backend. Never returns
/// key material.
async fn wallet_status(engine: &'static Engine) -> Response {
    let body = match load_wallet(engine).await {
        Some((key, storage)) => match crate::wallet::address_of(&key) {
            Ok(address) => serde_json::json!({
                "configured": true,
                "address": address,
                "storage": storage.as_str(),
            }),
            Err(e) => serde_json::json!({ "configured": false, "error": e }),
        },
        None => serde_json::json!({ "configured": false }),
    };
    json_ok(body)
}

/// `POST /wallet/generate` — a fresh 12-word mnemonic + its address for
/// the backup ceremony. Nothing is stored (and nothing logged); the app
/// POSTs the phrase back to `/wallet` once the user confirms the words.
async fn wallet_generate() -> Response {
    match crate::wallet::generate() {
        Ok((mnemonic, _key, address)) => json_ok(serde_json::json!({
            "mnemonic": mnemonic,
            "address": address,
        })),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e).into_response(),
    }
}

/// `POST /wallet` — import `{"private_key": …}` or `{"mnemonic": …}`,
/// persist the key, and reconnect so the client picks the wallet up.
async fn wallet_import(engine: &'static Engine, body: Bytes) -> Response {
    let json: serde_json::Value = match serde_json::from_slice(&body) {
        Ok(v) => v,
        Err(e) => return (StatusCode::BAD_REQUEST, format!("bad JSON: {e}")).into_response(),
    };
    let derived = if let Some(pk) = json.get("private_key").and_then(|v| v.as_str()) {
        crate::wallet::normalize_private_key(pk)
    } else if let Some(phrase) = json.get("mnemonic").and_then(|v| v.as_str()) {
        crate::wallet::key_from_mnemonic(phrase)
    } else {
        Err("body must have \"private_key\" or \"mnemonic\"".to_string())
    };
    let key = match derived {
        Ok(k) => k,
        Err(e) => return (StatusCode::BAD_REQUEST, e).into_response(),
    };
    let address = match crate::wallet::address_of(&key) {
        Ok(a) => a,
        Err(e) => return (StatusCode::BAD_REQUEST, e).into_response(),
    };
    let stored = tokio::task::spawn_blocking({
        let key = key.clone();
        move || engine.wallet.store(&key)
    })
    .await
    .map_err(|e| e.to_string())
    .and_then(|r| r);
    match stored {
        Ok(storage) => {
            engine.reconnect_for_wallet();
            json_ok(serde_json::json!({
                "address": address,
                "storage": storage.as_str(),
            }))
        }
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e).into_response(),
    }
}

/// `DELETE /wallet` — remove the key from every backend and drop the
/// wallet from the live client.
async fn wallet_delete(engine: &'static Engine) -> Response {
    let _ = tokio::task::spawn_blocking(move || engine.wallet.remove()).await;
    engine.reconnect_for_wallet();
    StatusCode::NO_CONTENT.into_response()
}

/// `GET /wallet/balances` — ANT + ETH on Arbitrum One as raw base-unit
/// decimal strings (UI formats; ANT and ETH are both 18 decimals).
async fn wallet_balances(engine: &'static Engine) -> Response {
    let Some((key, _)) = load_wallet(engine).await else {
        return (StatusCode::NOT_FOUND, "no wallet configured").into_response();
    };
    match crate::wallet::balances(&key).await {
        Ok((ant_atto, eth_wei)) => json_ok(serde_json::json!({
            "ant_atto": ant_atto,
            "eth_wei": eth_wei,
        })),
        Err(e) => (StatusCode::BAD_GATEWAY, e).into_response(),
    }
}

/// `POST /upload/estimate` `{"path": …}` — live per-chunk quotes from the
/// network (fast, no wallet needed, no chain traffic; gas is a static
/// heuristic on ant-core's side).
async fn upload_estimate(engine: &'static Engine, body: Bytes) -> Response {
    let json: serde_json::Value = match serde_json::from_slice(&body) {
        Ok(v) => v,
        Err(e) => return (StatusCode::BAD_REQUEST, format!("bad JSON: {e}")).into_response(),
    };
    let Some(path) = json.get("path").and_then(|v| v.as_str()) else {
        return (StatusCode::BAD_REQUEST, "body must have \"path\"").into_response();
    };
    let path = std::path::PathBuf::from(path);
    if !path.is_file() {
        return (StatusCode::BAD_REQUEST, format!("no such file: {}", path.display()))
            .into_response();
    }
    let client = match engine.client().await {
        Ok(c) => c,
        Err(e) => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                format!("not connected to the network yet: {e}"),
            )
                .into_response()
        }
    };
    use ant_core::data::PaymentMode;
    match client
        .estimate_upload_cost(&path, PaymentMode::Auto, None)
        .await
    {
        Ok(est) => json_ok(serde_json::json!({
            "file_size": est.file_size,
            "chunk_count": est.chunk_count,
            "storage_cost_atto": est.storage_cost_atto,
            "estimated_gas_cost_wei": est.estimated_gas_cost_wei,
            "confidence": format!("{:?}", est.confidence),
        })),
        Err(e) => (StatusCode::BAD_GATEWAY, format!("estimate failed: {e}")).into_response(),
    }
}

/// `POST /upload` `{"path": …, "name": …?}` — start the one paid upload
/// slot; returns `{"id": N}` to poll on `GET /upload/{id}`.
async fn upload_start(engine: &'static Engine, body: Bytes) -> Response {
    let json: serde_json::Value = match serde_json::from_slice(&body) {
        Ok(v) => v,
        Err(e) => return (StatusCode::BAD_REQUEST, format!("bad JSON: {e}")).into_response(),
    };
    let Some(path) = json.get("path").and_then(|v| v.as_str()) else {
        return (StatusCode::BAD_REQUEST, "body must have \"path\"").into_response();
    };
    let path = std::path::PathBuf::from(path);
    let name = json
        .get("name")
        .and_then(|v| v.as_str())
        .map(str::to_string)
        .or_else(|| path.file_name().map(|n| n.to_string_lossy().into_owned()))
        .unwrap_or_default();
    match engine.start_upload(path, name) {
        Ok(id) => json_ok(serde_json::json!({ "id": id })),
        Err(e) if e.contains("already running") => {
            (StatusCode::CONFLICT, e).into_response()
        }
        Err(e) => (StatusCode::BAD_REQUEST, e).into_response(),
    }
}

/// `GET /upload/{id}` — current job state (phase/progress/result/error).
async fn upload_status(engine: &'static Engine, Path(id): Path<u64>) -> Response {
    match engine.uploads.state(id) {
        Some(state) => json_ok(state.to_json(id)),
        None => (StatusCode::NOT_FOUND, "no such upload job").into_response(),
    }
}

// ---- My W@tch device linking -------------------------------------------

fn mywatch_result(result: Result<serde_json::Value, String>) -> Response {
    match result {
        Ok(body) => json_ok(body),
        Err(e) => (StatusCode::BAD_REQUEST, e).into_response(),
    }
}

/// `GET /mywatch` — link state, this device, every linked device's
/// record, and the persisted last-sync stamp.
async fn mywatch_status(engine: &'static Engine) -> Response {
    json_ok(engine.mywatch.status().await)
}

/// `POST /mywatch/link` — `{"device_name": …}`: create a new link on
/// this device; returns the invite other devices join with.
async fn mywatch_link(engine: &'static Engine, body: Bytes) -> Response {
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(&body) else {
        return (StatusCode::BAD_REQUEST, "body must be JSON").into_response();
    };
    let name = v["device_name"].as_str().unwrap_or("");
    mywatch_result(engine.mywatch.create_link(name).await)
}

/// `POST /mywatch/join` — `{"device_name": …, "invite": …}`: join a link
/// created on another device.
async fn mywatch_join(engine: &'static Engine, body: Bytes) -> Response {
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(&body) else {
        return (StatusCode::BAD_REQUEST, "body must be JSON").into_response();
    };
    let name = v["device_name"].as_str().unwrap_or("");
    let invite = v["invite"].as_str().unwrap_or("");
    mywatch_result(engine.mywatch.join_link(name, invite).await)
}

/// `GET /mywatch/invite` — the invite string for the existing link (QR
/// display / adding another device).
async fn mywatch_invite(engine: &'static Engine) -> Response {
    mywatch_result(engine.mywatch.invite().await)
}

/// `POST /mywatch/announce` — `{"lists": n, "entries": n}`: the app's
/// current library summary, published into this device's record.
async fn mywatch_announce(engine: &'static Engine, body: Bytes) -> Response {
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(&body) else {
        return (StatusCode::BAD_REQUEST, "body must be JSON").into_response();
    };
    let lists = v["lists"].as_u64().unwrap_or(0);
    let entries = v["entries"].as_u64().unwrap_or(0);
    mywatch_result(engine.mywatch.announce(lists, entries).await)
}

/// `DELETE /mywatch` — unlink this device and wipe its link artefacts.
async fn mywatch_unlink(engine: &'static Engine) -> Response {
    mywatch_result(engine.mywatch.unlink().await)
}

/// `POST /mywatch/enabled` — `{"enabled": bool}`: the Settings switch.
/// Off stops the My W@tch x0x agent (and its traffic) without touching
/// the link; on starts it again.
async fn mywatch_set_enabled(engine: &'static Engine, body: Bytes) -> Response {
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(&body) else {
        return (StatusCode::BAD_REQUEST, "body must be JSON").into_response();
    };
    let Some(on) = v["enabled"].as_bool() else {
        return (StatusCode::BAD_REQUEST, "\"enabled\" must be a boolean")
            .into_response();
    };
    mywatch_result(engine.mywatch.set_enabled(on).await)
}

/// `POST /mywatch/sync` — `{"doc": …}`: publish this device's library
/// sync document. The route walks the doc's entry addresses, attaches
/// the shrunk data map for every one held in the local map store (small
/// — the ant-cli `.datamap`-file form, base64), and hands both to the
/// link store, so another device can import a synced entry and actually
/// play it.
async fn mywatch_sync_put(engine: &'static Engine, body: Bytes) -> Response {
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(&body) else {
        return (StatusCode::BAD_REQUEST, "body must be JSON").into_response();
    };
    let doc = v["doc"].clone();
    if !doc.is_object() {
        return (StatusCode::BAD_REQUEST, "\"doc\" must be an object").into_response();
    }
    use base64::Engine as _;
    let mut seen = std::collections::HashSet::new();
    let mut maps = Vec::new();
    for list in doc["lists"].as_array().into_iter().flatten() {
        for entry in list["entries"].as_array().into_iter().flatten() {
            let Some(addr_hex) = entry["address"].as_str() else { continue };
            let addr_hex = addr_hex.trim().to_lowercase();
            let mut addr = [0u8; 32];
            if hex::decode_to_slice(&addr_hex, &mut addr).is_err()
                || !seen.insert(addr_hex.clone())
            {
                continue;
            }
            let Some(root) = engine.stored_root_map(&addr) else { continue };
            match crate::verify::shrunk_map_bytes(&root) {
                Ok(bytes) => maps.push((
                    addr_hex,
                    base64::engine::general_purpose::STANDARD.encode(bytes),
                )),
                Err(e) => tracing::debug!("mywatch sync: map for {addr_hex} skipped: {e}"),
            }
        }
    }
    mywatch_result(engine.mywatch.publish_sync(doc, maps).await)
}

/// `GET /mywatch/sync` — every remote device's sync document and entry
/// maps, for the app's merge pass.
async fn mywatch_sync_get(engine: &'static Engine) -> Response {
    mywatch_result(engine.mywatch.sync_docs().await)
}

/// `POST /mywatch/art/index` — `{"files": [{"sha256": …, "path": …}]}`:
/// replace the set of user-artwork files this device serves to linked
/// peers. The app refreshes it every sync cycle.
async fn mywatch_art_index(engine: &'static Engine, body: Bytes) -> Response {
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(&body) else {
        return (StatusCode::BAD_REQUEST, "body must be JSON").into_response();
    };
    let files: Vec<(String, std::path::PathBuf)> = v["files"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|f| {
            Some((
                f["sha256"].as_str()?.to_string(),
                std::path::PathBuf::from(f["path"].as_str()?),
            ))
        })
        .collect();
    mywatch_result(engine.mywatch.set_art_index(files))
}

/// `POST /mywatch/art/fetch` — `{"agent_id": …, "sha256": …}`: pull one
/// artwork file from the (online) linked device that owns it, verify
/// its hash, and return `{"path": …, "size": n}` of the received copy.
async fn mywatch_art_fetch(engine: &'static Engine, body: Bytes) -> Response {
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(&body) else {
        return (StatusCode::BAD_REQUEST, "body must be JSON").into_response();
    };
    let (Some(agent), Some(sha)) = (v["agent_id"].as_str(), v["sha256"].as_str()) else {
        return (
            StatusCode::BAD_REQUEST,
            "\"agent_id\" and \"sha256\" are required",
        )
            .into_response();
    };
    mywatch_result(engine.mywatch.fetch_art(agent, sha).await)
}

// ---- Channels -----------------------------------------------------------

/// `GET /channels` — own channel, subscriptions, verified heads, agent
/// state. Heads are signature-checked in the store; junk written into
/// the public topics never surfaces here.
async fn channels_status(engine: &'static Engine) -> Response {
    json_ok(engine.channels.status().await)
}

/// `POST /channel/enabled` — `{"enabled": bool}`: the Settings switch.
/// Off stops the channels x0x agent (topic gossip and relay traffic)
/// without touching the key, config or subscriptions; on restarts it.
async fn channel_set_enabled(engine: &'static Engine, body: Bytes) -> Response {
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(&body) else {
        return (StatusCode::BAD_REQUEST, "body must be JSON").into_response();
    };
    let Some(on) = v["enabled"].as_bool() else {
        return (StatusCode::BAD_REQUEST, "\"enabled\" must be a boolean")
            .into_response();
    };
    mywatch_result(engine.channels.set_enabled(on).await)
}

/// `POST /channel/generate` — a fresh 12-word channel phrase + the code
/// it derives. Nothing is stored (the backup ceremony runs first); the
/// app POSTs the phrase back to `/channel/create` on confirm.
async fn channel_generate() -> Response {
    match crate::channel::generate() {
        Ok((mnemonic, _secret, code)) => json_ok(serde_json::json!({
            "mnemonic": mnemonic,
            "code": code,
        })),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e).into_response(),
    }
}

/// `POST /channel/create` — `{"name", "description", "author",
/// "mnemonic"}`: derive + store the channel key, persist the config,
/// join the topic. `author` is optional (empty = unset).
async fn channel_create(engine: &'static Engine, body: Bytes) -> Response {
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(&body) else {
        return (StatusCode::BAD_REQUEST, "body must be JSON").into_response();
    };
    mywatch_result(
        engine
            .channels
            .create(
                v["name"].as_str().unwrap_or(""),
                v["description"].as_str().unwrap_or(""),
                v["author"].as_str().unwrap_or(""),
                v["mnemonic"].as_str().unwrap_or(""),
            )
            .await,
    )
}

/// `POST /channel/restore` — `{"mnemonic"}`: same key, same code,
/// publishing resumes on this machine.
async fn channel_restore(engine: &'static Engine, body: Bytes) -> Response {
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(&body) else {
        return (StatusCode::BAD_REQUEST, "body must be JSON").into_response();
    };
    mywatch_result(
        engine
            .channels
            .restore(v["mnemonic"].as_str().unwrap_or(""))
            .await,
    )
}

/// `POST /channel/meta` — `{"name", "description", "author"}`: update
/// the locally displayed copy (the canonical copy is in the published
/// manifest). `author` is optional (empty = unset).
async fn channel_meta(engine: &'static Engine, body: Bytes) -> Response {
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(&body) else {
        return (StatusCode::BAD_REQUEST, "body must be JSON").into_response();
    };
    mywatch_result(
        engine
            .channels
            .set_meta(
                v["name"].as_str().unwrap_or(""),
                v["description"].as_str().unwrap_or(""),
                v["author"].as_str().unwrap_or(""),
            )
            .await,
    )
}

/// `DELETE /channel` — remove the channel key + config from this device
/// (the channel itself is frozen at its last head until restored).
async fn channel_remove(engine: &'static Engine) -> Response {
    mywatch_result(engine.channels.remove_own().await)
}

/// `POST /channel/publish` — `{"path": …}`: publish the manifest zip at
/// `path` publicly and announce the signed head; `{"id": N}` to poll on
/// `GET /upload/{id}` (same job surface as private uploads).
async fn channel_publish(engine: &'static Engine, body: Bytes) -> Response {
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(&body) else {
        return (StatusCode::BAD_REQUEST, "body must be JSON").into_response();
    };
    let Some(path) = v["path"].as_str() else {
        return (StatusCode::BAD_REQUEST, "body must have \"path\"").into_response();
    };
    let path = std::path::PathBuf::from(path);
    let name = v["name"]
        .as_str()
        .map(str::to_string)
        .unwrap_or_else(|| "channel manifest".to_string());
    match engine.start_channel_publish(path, name) {
        Ok(id) => json_ok(serde_json::json!({ "id": id })),
        Err(e) if e.contains("already running") => (StatusCode::CONFLICT, e).into_response(),
        Err(e) => (StatusCode::BAD_REQUEST, e).into_response(),
    }
}

/// `POST /channel/subscribe` — `{"code": "wchn1-…"}`.
async fn channel_subscribe(engine: &'static Engine, body: Bytes) -> Response {
    let Ok(v) = serde_json::from_slice::<serde_json::Value>(&body) else {
        return (StatusCode::BAD_REQUEST, "body must be JSON").into_response();
    };
    mywatch_result(
        engine
            .channels
            .subscribe(v["code"].as_str().unwrap_or(""))
            .await,
    )
}

/// `DELETE /channel/subscribe/{pubkey}`.
async fn channel_unsubscribe(
    engine: &'static Engine,
    Path(pubkey): Path<String>,
) -> Response {
    mywatch_result(engine.channels.unsubscribe(&pubkey).await)
}

/// `GET /channel/manifest/{addr}` — fetch a channel manifest from the
/// network by its public address: data-map chunk first, then the content
/// itself, streamed as the zip bytes. The only place the app fetches a
/// *data map* over the network — manifests are public by intent
/// (entries stay datamap-first, docs/PLAN-datamap-privacy.md).
///
/// The route honours `Range` (and `HEAD`) exactly like `/xor`: manifests
/// are content-addressed and immutable, so the root map is stored in the
/// mapstore on first fetch and every request after that — including the
/// delta import's ranged reads of the zip's central directory and
/// individual members — serves from the stored map through the chunk
/// cache without another network map lookup.
async fn channel_manifest(
    engine: &'static Engine,
    method: Method,
    Path(addr_hex): Path<String>,
    headers: HeaderMap,
) -> Response {
    /// Matches the app-side bundle cap (kMaxBundleBytes).
    const MAX_MANIFEST_BYTES: u64 = 200 * 1024 * 1024;
    let mut addr = [0u8; 32];
    if hex::decode_to_slice(addr_hex.trim(), &mut addr).is_err() {
        return (StatusCode::BAD_REQUEST, "address must be 64 hex chars").into_response();
    }
    let root = match engine.stored_root_map(&addr) {
        Some(r) => r,
        None => {
            let client = match engine.client().await {
                Ok(c) => c,
                Err(e) => {
                    return (
                        StatusCode::SERVICE_UNAVAILABLE,
                        format!("not connected to the network yet: {e}"),
                    )
                        .into_response()
                }
            };
            let map = match client.data_map_fetch(&addr).await {
                Ok(m) => m,
                Err(e) => {
                    return (
                        StatusCode::BAD_GATEWAY,
                        format!("manifest lookup failed: {e}"),
                    )
                        .into_response()
                }
            };
            // For a child map this is the serialized-root size, not the
            // content size — the real cap check runs again on the
            // expanded root below.
            if map.original_file_size() as u64 > MAX_MANIFEST_BYTES {
                return (
                    StatusCode::UNPROCESSABLE_ENTITY,
                    "that address points at something too large to be a channel manifest",
                )
                    .into_response();
            }
            // Mirror the POST /datamap import: a >3-chunk manifest's
            // fetched map is the shrunk child form; expand it over the
            // wrapper chunks and verify the root against the address.
            let (derived, root) = if map.is_child() {
                let derived = match crate::verify::shrunk_map_address(&map) {
                    Ok(a) => a,
                    Err(e) => return (StatusCode::UNPROCESSABLE_ENTITY, e).into_response(),
                };
                let root = match engine.expand_child_map(map).await {
                    Ok(r) => r,
                    Err(e) => {
                        return (
                            StatusCode::BAD_GATEWAY,
                            format!("manifest lookup failed: {e}"),
                        )
                            .into_response()
                    }
                };
                if let Err(e) = crate::verify::verify_root_map(&derived, &root) {
                    return (StatusCode::UNPROCESSABLE_ENTITY, e).into_response();
                }
                (derived, root)
            } else {
                match crate::verify::derive_address(&map) {
                    Ok(a) => (a, map),
                    Err(e) => return (StatusCode::UNPROCESSABLE_ENTITY, e).into_response(),
                }
            };
            if derived != addr {
                return (
                    StatusCode::UNPROCESSABLE_ENTITY,
                    "the fetched manifest does not match its address",
                )
                    .into_response();
            }
            if root.original_file_size() as u64 > MAX_MANIFEST_BYTES {
                return (
                    StatusCode::UNPROCESSABLE_ENTITY,
                    "that address points at something too large to be a channel manifest",
                )
                    .into_response();
            }
            engine.store_root_map(addr, &root);
            root
        }
    };
    serve_stored_map(engine, root, method, &headers)
}

async fn serve_xor(
    engine: &'static Engine,
    method: Method,
    Path(addr_hex): Path<String>,
    headers: HeaderMap,
) -> Response {
    let mut addr = [0u8; 32];
    if hex::decode_to_slice(addr_hex.trim(), &mut addr).is_err() {
        return (StatusCode::BAD_REQUEST, "address must be 64 hex chars").into_response();
    }

    // Local maps only — every entry's map arrives at import time, so a
    // miss here is a broken entry, not a resolvable one. Fast-fail beats
    // the old doomed 20-30s network resolve (the network fetch path no
    // longer exists anywhere in the crate).
    let root = match engine.stored_root_map(&addr) {
        Some(dm) => dm,
        None => {
            tracing::warn!("{addr_hex}: no stored data map");
            return (
                StatusCode::NOT_FOUND,
                "data map missing — re-import the list or bundle",
            )
                .into_response();
        }
    };
    serve_stored_map(engine, root, method, &headers)
}

/// Stream a stored root map's content, honouring `Range` and `HEAD` —
/// the serving half of `/xor`, shared with `/channel/manifest` (which
/// resolves its map over the network first).
fn serve_stored_map(
    engine: &'static Engine,
    root: DataMap,
    method: Method,
    headers: &HeaderMap,
) -> Response {
    let size = root.original_file_size() as u64;

    let range = headers
        .get(header::RANGE)
        .and_then(|v| v.to_str().ok())
        .map(|v| parse_range(v, size));

    match range {
        None => {
            let resp = Response::builder()
                .status(StatusCode::OK)
                .header(header::CONTENT_LENGTH, size)
                .header(header::ACCEPT_RANGES, "bytes")
                .header(header::CONTENT_TYPE, "application/octet-stream");
            if method == Method::HEAD {
                return resp.body(Body::empty()).unwrap();
            }
            let rx = engine.stream_full(root);
            let stream = ReceiverStream::new(rx)
                .map(|r| r.map_err(|e| std::io::Error::other(e.to_string())));
            resp.body(Body::from_stream(stream)).unwrap()
        }
        Some(Some((start, end))) => {
            let len = end - start + 1;
            let builder = Response::builder()
                .status(StatusCode::PARTIAL_CONTENT)
                .header(header::CONTENT_LENGTH, len)
                .header(header::CONTENT_RANGE, format!("bytes {start}-{end}/{size}"))
                .header(header::ACCEPT_RANGES, "bytes")
                .header(header::CONTENT_TYPE, "application/octet-stream");
            if method == Method::HEAD {
                return builder.body(Body::empty()).unwrap();
            }
            let rx = engine.stream_range(root, start, end);
            let stream =
                ReceiverStream::new(rx).map(|r| r.map_err(std::io::Error::other));
            builder.body(Body::from_stream(stream)).unwrap()
        }
        Some(None) => (
            StatusCode::RANGE_NOT_SATISFIABLE,
            [(header::CONTENT_RANGE, format!("bytes */{size}"))],
        )
            .into_response(),
    }
}

/// Parse a `Range` header value against a resource of `size` bytes.
/// Returns `None` for unsatisfiable/unsupported ranges, else the inclusive
/// `(start, end)` pair. Multi-range requests are not supported (players
/// never send them); only the first range is honoured.
fn parse_range(value: &str, size: u64) -> Option<(u64, u64)> {
    if size == 0 {
        return None;
    }
    let spec = value.trim().strip_prefix("bytes=")?;
    let first = spec.split(',').next()?.trim();
    let (start_s, end_s) = first.split_once('-')?;
    if start_s.is_empty() {
        // suffix form: last N bytes
        let n: u64 = end_s.parse().ok()?;
        if n == 0 {
            return None;
        }
        let start = size.saturating_sub(n);
        return Some((start, size - 1));
    }
    let start: u64 = start_s.parse().ok()?;
    if start >= size {
        return None;
    }
    let end = if end_s.is_empty() {
        size - 1
    } else {
        std::cmp::min(end_s.parse().ok()?, size - 1)
    };
    if end < start {
        return None;
    }
    Some((start, end))
}

#[cfg(test)]
mod rootmap_tests {
    use super::*;
    use http_body_util::BodyExt;
    use std::collections::HashMap;
    use tower::ServiceExt;
    use xor_name::XorName;

    /// Offline upload-equivalent (same as verify.rs tests): encrypt
    /// deterministic content, derive the public address, resolve the root.
    fn upload() -> ([u8; 32], DataMap) {
        let mut v = Vec::with_capacity(10 * 1024);
        let mut x = 0x9E3779B9u64;
        while v.len() < 10 * 1024 {
            x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            v.extend_from_slice(&x.to_le_bytes());
        }
        let (shrunk, chunks) = self_encryption::encrypt(v.into()).unwrap();
        let addr = *blake3::hash(&rmp_serde::to_vec(&shrunk).unwrap()).as_bytes();
        let by_name: HashMap<XorName, bytes::Bytes> = chunks
            .iter()
            .map(|c| (self_encryption::hash::content_hash(&c.content), c.content.clone()))
            .collect();
        let mut fetch = |name: XorName| {
            by_name
                .get(&name)
                .cloned()
                .ok_or_else(|| self_encryption::Error::Generic("missing chunk".into()))
        };
        let root = self_encryption::get_root_data_map(shrunk, &mut fetch).unwrap();
        (addr, root)
    }

    fn test_router(name: &str) -> Router {
        let dir = std::env::temp_dir().join(format!(
            "wi-rootmap-api-{name}-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        // Engine::new never touches the network; the client connects only
        // when a request needs it, which these endpoints never do.
        let engine: &'static Engine =
            Box::leak(Box::new(Engine::new(None, dir.to_str())));
        router(engine)
    }

    async fn send(
        app: &Router,
        method: &str,
        uri: &str,
        body: Vec<u8>,
    ) -> (StatusCode, Vec<u8>) {
        let res = app
            .clone()
            .oneshot(
                axum::http::Request::builder()
                    .method(method)
                    .uri(uri)
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();
        let status = res.status();
        let bytes = res.into_body().collect().await.unwrap().to_bytes();
        (status, bytes.to_vec())
    }

    #[tokio::test]
    async fn put_verifies_then_get_round_trips() {
        let app = test_router("roundtrip");
        let (addr, root) = upload();
        let hexaddr = hex::encode(addr);

        // Unknown map: 404 before import.
        let (status, _) = send(&app, "GET", &format!("/rootmap/{hexaddr}"), vec![]).await;
        assert_eq!(status, StatusCode::NOT_FOUND);

        let (status, _) = send(
            &app,
            "PUT",
            &format!("/rootmap/{hexaddr}"),
            root.to_bytes().unwrap(),
        )
        .await;
        assert_eq!(status, StatusCode::NO_CONTENT);

        let (status, body) =
            send(&app, "GET", &format!("/rootmap/{hexaddr}"), vec![]).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(DataMap::from_bytes(&body).unwrap(), root);
    }

    #[tokio::test]
    async fn datamap_import_derives_address_and_round_trips() {
        let app = test_router("datamap-import");
        let (addr, root) = upload();
        let hexaddr = hex::encode(addr);

        // ant-cli canonical wire format: bare msgpack.
        let (status, body) = send(
            &app,
            "POST",
            "/datamap",
            rmp_serde::to_vec(&root).unwrap(),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let json: serde_json::Value =
            serde_json::from_slice(&body).unwrap();
        assert_eq!(json["address"], serde_json::json!(hexaddr));
        assert_eq!(json["chunks"], serde_json::json!(root.len()));

        // Export returns the same canonical bytes; the map is now stored.
        let (status, body) =
            send(&app, "GET", &format!("/datamap/{hexaddr}"), vec![]).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(rmp_serde::from_slice::<DataMap>(&body).unwrap(), root);
        let (status, _) =
            send(&app, "GET", &format!("/rootmap/{hexaddr}"), vec![]).await;
        assert_eq!(status, StatusCode::OK);
    }

    #[tokio::test]
    async fn datamap_import_accepts_legacy_json() {
        let app = test_router("datamap-json");
        let (addr, root) = upload();
        let (status, body) = send(
            &app,
            "POST",
            "/datamap",
            serde_json::to_vec(&root).unwrap(),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(json["address"], serde_json::json!(hex::encode(addr)));
    }

    #[tokio::test]
    async fn datamap_import_rejects_garbage() {
        let app = test_router("datamap-bad");
        let (status, _) = send(&app, "POST", "/datamap", b"junk".to_vec()).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    async fn child_datamap_offline_gets_clear_retry_error() {
        // A shrunk (child) map is what ant-cli writes for any >3-chunk
        // file. Expanding it needs the network; with no client connected
        // the import must fail fast with an actionable message, not 422.
        let app = test_router("datamap-child-offline");
        let (_, root) = upload();
        let child = DataMap::with_child(root.infos().to_vec(), 1);
        let (status, body) = send(
            &app,
            "POST",
            "/datamap",
            rmp_serde::to_vec(&child).unwrap(),
        )
        .await;
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
        assert!(String::from_utf8_lossy(&body).contains("not connected"));
    }

    #[tokio::test]
    async fn child_datamap_reimport_succeeds_offline_once_root_is_stored() {
        // First import expanded and stored the root (simulated here via
        // the root-map PUT); re-posting the same child map must succeed
        // without touching the network — duplicate imports stay offline.
        let app = test_router("datamap-child-reimport");
        // A ≤3-chunk root shrinks to itself, so hand-build the shrunk
        // form ant-cli would have written for a bigger file: mark the
        // stored root's own map as the child level. shrunk_map_address
        // of that child is then the address the root must live under.
        let (_, root) = upload();
        let child = DataMap::with_child(root.infos().to_vec(), 1);
        let addr = crate::verify::shrunk_map_address(&child).unwrap();
        // No stored root yet: offline import fails.
        let (status, _) = send(
            &app,
            "POST",
            "/datamap",
            rmp_serde::to_vec(&child).unwrap(),
        )
        .await;
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
        // Pretend the one-time expand happened: store a root at that
        // address directly through the engine (PUT /rootmap verifies the
        // derived address, which a hand-built child can't satisfy).
        let dir = std::env::temp_dir().join(format!(
            "wi-rootmap-api-datamap-child-reimport-{}",
            std::process::id()
        ));
        let engine: &'static Engine =
            Box::leak(Box::new(Engine::new(None, dir.to_str())));
        engine.store_root_map(addr, &root);
        let app = router(engine);
        let (status, body) = send(
            &app,
            "POST",
            "/datamap",
            rmp_serde::to_vec(&child).unwrap(),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(json["address"], serde_json::json!(hex::encode(addr)));
        assert_eq!(json["chunks"], serde_json::json!(root.len()));
    }

    #[tokio::test]
    async fn xor_fast_fails_without_stored_map() {
        // No stored map, no network client: the stream path must 404
        // immediately instead of attempting a resolve.
        let app = test_router("xor-fastfail");
        let (status, body) = send(
            &app,
            "GET",
            &format!("/xor/{}", hex::encode([7u8; 32])),
            vec![],
        )
        .await;
        assert_eq!(status, StatusCode::NOT_FOUND);
        assert!(String::from_utf8_lossy(&body).contains("re-import"));
    }

    #[tokio::test]
    async fn tampered_put_rejected() {
        let app = test_router("tampered");
        let (addr, root) = upload();
        let mut infos = root.infos().to_vec();
        infos[0].src_size += 1;
        let tampered = DataMap::new(infos);
        let (status, _) = send(
            &app,
            "PUT",
            &format!("/rootmap/{}", hex::encode(addr)),
            tampered.to_bytes().unwrap(),
        )
        .await;
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
        // Nothing stored.
        let (status, _) = send(
            &app,
            "GET",
            &format!("/rootmap/{}", hex::encode(addr)),
            vec![],
        )
        .await;
        assert_eq!(status, StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn garbage_body_and_address_rejected() {
        let app = test_router("garbage");
        let (status, _) =
            send(&app, "PUT", "/rootmap/nothex", b"junk".to_vec()).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        let (status, _) = send(
            &app,
            "PUT",
            &format!("/rootmap/{}", hex::encode([1u8; 32])),
            b"junk".to_vec(),
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
    }
}

#[cfg(test)]
mod wallet_api_tests {
    use super::*;
    use http_body_util::BodyExt;
    use tower::ServiceExt;

    // hardhat/foundry account 0 — same vector as the wallet module tests.
    const KEY: &str = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
    const ADDR: &str = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
    const PHRASE: &str = "test test test test test test test test test test test junk";

    /// Engine with a temp data dir and the keychain disabled — API tests
    /// must never write a developer's real keychain, and the file
    /// fallback is the deterministic backend.
    fn test_engine(name: &str) -> &'static Engine {
        let dir = std::env::temp_dir().join(format!(
            "wi-wallet-api-{name}-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        let engine: &'static Engine =
            Box::leak(Box::new(Engine::new(None, dir.to_str())));
        engine.wallet.disable_keychain();
        engine
    }

    async fn send_auth(
        app: &Router,
        method: &str,
        uri: &str,
        body: Vec<u8>,
        token: Option<&str>,
    ) -> (StatusCode, Vec<u8>) {
        let mut req = axum::http::Request::builder().method(method).uri(uri);
        if let Some(t) = token {
            req = req.header("x-watchit-auth", t);
        }
        let res = app
            .clone()
            .oneshot(req.body(Body::from(body)).unwrap())
            .await
            .unwrap();
        let status = res.status();
        let bytes = res.into_body().collect().await.unwrap().to_bytes();
        (status, bytes.to_vec())
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn wallet_import_status_delete_round_trip() {
        let app = router(test_engine("roundtrip"));

        let (status, body) = send_auth(&app, "GET", "/wallet", vec![], None).await;
        assert_eq!(status, StatusCode::OK);
        let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(json["configured"], serde_json::json!(false));

        // Import by private key.
        let (status, body) = send_auth(
            &app,
            "POST",
            "/wallet",
            serde_json::json!({ "private_key": KEY }).to_string().into_bytes(),
            None,
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{}", String::from_utf8_lossy(&body));
        let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(json["address"], serde_json::json!(ADDR));
        assert_eq!(json["storage"], serde_json::json!("file"));

        let (status, body) = send_auth(&app, "GET", "/wallet", vec![], None).await;
        assert_eq!(status, StatusCode::OK);
        let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(json["configured"], serde_json::json!(true));
        assert_eq!(json["address"], serde_json::json!(ADDR));

        let (status, _) = send_auth(&app, "DELETE", "/wallet", vec![], None).await;
        assert_eq!(status, StatusCode::NO_CONTENT);
        let (_, body) = send_auth(&app, "GET", "/wallet", vec![], None).await;
        let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(json["configured"], serde_json::json!(false));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn wallet_import_by_mnemonic_and_bad_input() {
        let app = router(test_engine("mnemonic"));
        let (status, body) = send_auth(
            &app,
            "POST",
            "/wallet",
            serde_json::json!({ "mnemonic": PHRASE }).to_string().into_bytes(),
            None,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(json["address"], serde_json::json!(ADDR));

        for bad in [
            serde_json::json!({ "private_key": "0x1234" }),
            serde_json::json!({ "mnemonic": "junk words here" }),
            serde_json::json!({ "somethingelse": 1 }),
        ] {
            let (status, _) = send_auth(
                &app,
                "POST",
                "/wallet",
                bad.to_string().into_bytes(),
                None,
            )
            .await;
            assert_eq!(status, StatusCode::BAD_REQUEST, "{bad}");
        }
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn generate_returns_importable_wallet_without_storing() {
        let app = router(test_engine("generate"));
        let (status, body) =
            send_auth(&app, "POST", "/wallet/generate", vec![], None).await;
        assert_eq!(status, StatusCode::OK);
        let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
        let phrase = json["mnemonic"].as_str().unwrap();
        assert_eq!(phrase.split_whitespace().count(), 12);
        // Nothing stored by generate.
        let (_, body) = send_auth(&app, "GET", "/wallet", vec![], None).await;
        let status_json: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(status_json["configured"], serde_json::json!(false));
        // Importing the phrase lands on the promised address.
        let (status, body) = send_auth(
            &app,
            "POST",
            "/wallet",
            serde_json::json!({ "mnemonic": phrase }).to_string().into_bytes(),
            None,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let imported: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(imported["address"], json["address"]);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn auth_token_guards_wallet_routes_but_not_streaming() {
        let engine = test_engine("auth");
        let app = router_with_auth(engine, "sekrit");
        // No token / wrong token → 401.
        let (status, _) = send_auth(&app, "GET", "/wallet", vec![], None).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        let (status, _) =
            send_auth(&app, "GET", "/wallet", vec![], Some("wrong")).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        // Right token → 200.
        let (status, _) =
            send_auth(&app, "GET", "/wallet", vec![], Some("sekrit")).await;
        assert_eq!(status, StatusCode::OK);
        // Open routes stay tokenless.
        let (status, _) = send_auth(&app, "GET", "/health", vec![], None).await;
        assert_eq!(status, StatusCode::OK);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn network_pause_flips_health_and_is_guarded() {
        let engine = test_engine("netpause");
        let app = router_with_auth(engine, "sekrit");
        let pause = |p: bool| format!("{{\"paused\":{p}}}").into_bytes();
        // Tokenless → 401 (the route can silence the network).
        let (status, _) =
            send_auth(&app, "POST", "/network/pause", pause(true), None).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        // Pause: the route returns the new health, and /health agrees.
        let (status, body) = send_auth(
            &app, "POST", "/network/pause", pause(true), Some("sekrit"),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(json["state"], serde_json::json!("paused"));
        let (_, body) = send_auth(&app, "GET", "/health", vec![], None).await;
        let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(json["state"], serde_json::json!("paused"));
        // client() refuses instantly while paused (no dial attempt).
        let err = engine.client().await.err().unwrap();
        assert!(err.contains("paused"), "{err}");
        // Malformed body → 400, state unchanged.
        let (status, _) = send_auth(
            &app, "POST", "/network/pause", b"{}".to_vec(), Some("sekrit"),
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert!(engine.paused());
        // Resume: health reports connecting again.
        let (_, body) = send_auth(
            &app, "POST", "/network/pause", pause(false), Some("sekrit"),
        )
        .await;
        let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(json["state"], serde_json::json!("connecting"));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn stats_guarded_populated_while_paused_and_resettable() {
        let engine = test_engine("stats");
        let app = router_with_auth(engine, "sekrit");
        // Tokenless → 401 (usage is the user's own business, reset mutates).
        let (status, _) = send_auth(&app, "GET", "/stats", vec![], None).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        let (status, _) =
            send_auth(&app, "POST", "/stats/reset", vec![], None).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        // Seed the global accumulators (this is the one server test that
        // touches them, so the values are deterministic here).
        crate::datausage::usage().add_x0x(crate::datausage::Component::MyWatch, 7, 9);
        // /stats stays fully populated even while the network is paused —
        // the reason the screen doesn't read /health.
        engine.set_paused(true);
        let (status, body) =
            send_auth(&app, "GET", "/stats", vec![], Some("sekrit")).await;
        assert_eq!(status, StatusCode::OK);
        let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert!(json["mywatch"]["tx"].as_u64().unwrap() >= 7);
        assert!(json["mywatch"]["rx"].as_u64().unwrap() >= 9);
        assert!(json["total"]["tx"].as_u64().unwrap() >= 7);
        assert!(json["period_start_ms"].as_u64().unwrap() > 0);
        assert!(json["ant"].get("stale_secs").is_some());
        assert!(json["ant"].get("media_rx").is_some());
        assert!(json["channels"].is_object());
        // Reset returns the fresh zeroed body and a new period start.
        let (status, body) =
            send_auth(&app, "POST", "/stats/reset", vec![], Some("sekrit")).await;
        assert_eq!(status, StatusCode::OK);
        let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(json["mywatch"]["tx"].as_u64(), Some(0));
        assert_eq!(json["mywatch"]["rx"].as_u64(), Some(0));
        assert_eq!(json["ant"]["rx"].as_u64(), Some(0));
        assert_eq!(json["total"]["rx"].as_u64(), Some(0));
        engine.set_paused(false);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn upload_refused_without_wallet_and_missing_file() {
        let app = router(test_engine("upload-guards"));
        // No wallet configured → 400 with the settings hint.
        let file = std::env::temp_dir().join("wi-upload-guard-test.bin");
        std::fs::write(&file, b"hello").unwrap();
        let (status, body) = send_auth(
            &app,
            "POST",
            "/upload",
            serde_json::json!({ "path": file.to_str().unwrap() })
                .to_string()
                .into_bytes(),
            None,
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert!(String::from_utf8_lossy(&body).contains("no upload wallet"));
        // Missing file → 400 either way.
        let (status, _) = send_auth(
            &app,
            "POST",
            "/upload",
            serde_json::json!({ "path": "/does/not/exist" })
                .to_string()
                .into_bytes(),
            None,
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        // Unknown job id → 404.
        let (status, _) = send_auth(&app, "GET", "/upload/99", vec![], None).await;
        assert_eq!(status, StatusCode::NOT_FOUND);
        let _ = std::fs::remove_file(&file);
    }
}

#[cfg(test)]
mod channel_api_tests {
    use super::*;
    use http_body_util::BodyExt;
    use tower::ServiceExt;

    fn test_engine(name: &str) -> &'static Engine {
        let dir = std::env::temp_dir().join(format!(
            "wi-channel-api-{name}-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        let engine: &'static Engine =
            Box::leak(Box::new(Engine::new(None, dir.to_str())));
        engine.wallet.disable_keychain();
        engine.channels.disable_keychain();
        engine
    }

    async fn send(
        app: &Router,
        method: &str,
        uri: &str,
        body: Vec<u8>,
        token: Option<&str>,
    ) -> (StatusCode, Vec<u8>) {
        let mut req = axum::http::Request::builder().method(method).uri(uri);
        if let Some(t) = token {
            req = req.header("x-watchit-auth", t);
        }
        let res = app
            .clone()
            .oneshot(req.body(Body::from(body)).unwrap())
            .await
            .unwrap();
        let status = res.status();
        let bytes = res.into_body().collect().await.unwrap().to_bytes();
        (status, bytes.to_vec())
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn generate_returns_phrase_and_code_without_storing() {
        let app = router(test_engine("generate"));
        let (status, body) =
            send(&app, "POST", "/channel/generate", vec![], None).await;
        assert_eq!(status, StatusCode::OK);
        let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(
            json["mnemonic"].as_str().unwrap().split_whitespace().count(),
            12
        );
        let code = json["code"].as_str().unwrap();
        assert!(code.starts_with(crate::channel::CODE_PREFIX));
        crate::channel::pubkey_from_code(code).unwrap();
        // Nothing was stored: status still reports no channel.
        let (status, body) = send(&app, "GET", "/channels", vec![], None).await;
        assert_eq!(status, StatusCode::OK);
        let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(json["state"], serde_json::json!("off"));
        assert!(json["own"].is_null());
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn bad_inputs_rejected() {
        let app = router(test_engine("bad-inputs"));
        // Subscribe with a My W@tch invite / garbage → 400 with the
        // channel-code hint.
        for code in ["wtch1-abcdef", "garbage", ""] {
            let (status, body) = send(
                &app,
                "POST",
                "/channel/subscribe",
                serde_json::json!({ "code": code }).to_string().into_bytes(),
                None,
            )
            .await;
            assert_eq!(status, StatusCode::BAD_REQUEST, "{code}");
            assert!(String::from_utf8_lossy(&body).contains("channel code"));
        }
        // Create with a bad phrase → 400; nothing stored.
        let (status, _) = send(
            &app,
            "POST",
            "/channel/create",
            serde_json::json!({ "name": "x", "mnemonic": "not real words" })
                .to_string()
                .into_bytes(),
            None,
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        // Create with no name → 400.
        let (status, body) = send(
            &app,
            "POST",
            "/channel/create",
            serde_json::json!({
                "name": " ",
                "mnemonic": "test test test test test test test test test test test junk",
            })
            .to_string()
            .into_bytes(),
            None,
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert!(String::from_utf8_lossy(&body).contains("name"));
        // Publish without a channel → 400.
        let file = std::env::temp_dir().join("wi-channel-guard-test.zip");
        std::fs::write(&file, b"PK").unwrap();
        let (status, body) = send(
            &app,
            "POST",
            "/channel/publish",
            serde_json::json!({ "path": file.to_str().unwrap() })
                .to_string()
                .into_bytes(),
            None,
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert!(String::from_utf8_lossy(&body).contains("wallet")
            || String::from_utf8_lossy(&body).contains("channel"));
        // Unsubscribe from nothing → 400.
        let (status, _) = send(
            &app,
            "DELETE",
            &format!("/channel/subscribe/{}", "ab".repeat(32)),
            vec![],
            None,
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        let _ = std::fs::remove_file(&file);
    }

    /// HEAD keeps the body empty, so serving headers are assertable
    /// offline (a GET body would stream chunks the test engine cannot
    /// fetch).
    async fn send_head(
        app: &Router,
        uri: &str,
        range: Option<&str>,
    ) -> (StatusCode, axum::http::HeaderMap) {
        let mut req = axum::http::Request::builder().method("HEAD").uri(uri);
        if let Some(r) = range {
            req = req.header("range", r);
        }
        let res = app
            .clone()
            .oneshot(req.body(Body::empty()).unwrap())
            .await
            .unwrap();
        (res.status(), res.headers().clone())
    }

    /// Offline upload-equivalent (same as rootmap_tests): encrypt
    /// deterministic content, derive the public address and root map.
    fn upload() -> ([u8; 32], DataMap) {
        let mut v = Vec::with_capacity(10 * 1024);
        let mut x = 0x51ED270Bu64;
        while v.len() < 10 * 1024 {
            x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            v.extend_from_slice(&x.to_le_bytes());
        }
        let (shrunk, _chunks) = self_encryption::encrypt(v.into()).unwrap();
        let addr = *blake3::hash(&rmp_serde::to_vec(&shrunk).unwrap()).as_bytes();
        (addr, shrunk)
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn manifest_serves_stored_map_with_ranges() {
        let engine = test_engine("manifest-range");
        let (addr, root) = upload();
        engine.store_root_map(addr, &root);
        let app = router(engine);
        let size = root.original_file_size() as u64;
        let uri = format!("/channel/manifest/{}", hex::encode(addr));

        // Full request: 200 with the manifest size + range capability.
        let (status, headers) = send_head(&app, &uri, None).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(
            headers[header::CONTENT_LENGTH],
            size.to_string().parse::<axum::http::HeaderValue>().unwrap()
        );
        assert_eq!(headers[header::ACCEPT_RANGES], "bytes");

        // Suffix range (the delta import's central-directory read).
        let (status, headers) = send_head(&app, &uri, Some("bytes=-100")).await;
        assert_eq!(status, StatusCode::PARTIAL_CONTENT);
        assert_eq!(
            headers[header::CONTENT_RANGE],
            format!("bytes {}-{}/{size}", size - 100, size - 1)
        );

        // Explicit member range.
        let (status, headers) = send_head(&app, &uri, Some("bytes=10-19")).await;
        assert_eq!(status, StatusCode::PARTIAL_CONTENT);
        assert_eq!(headers[header::CONTENT_LENGTH], "10");
        assert_eq!(
            headers[header::CONTENT_RANGE],
            format!("bytes 10-19/{size}")
        );

        // Unsatisfiable range.
        let (status, _) =
            send_head(&app, &uri, Some(&format!("bytes={size}-"))).await;
        assert_eq!(status, StatusCode::RANGE_NOT_SATISFIABLE);

        // Bad address is rejected before any lookup.
        let (status, _) =
            send_head(&app, "/channel/manifest/nothex", None).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn channel_routes_are_token_guarded() {
        let engine = test_engine("auth");
        let app = router_with_auth(engine, "sekrit");
        for (method, uri) in [
            ("GET", "/channels"),
            ("POST", "/channel/generate"),
            ("POST", "/channel/subscribe"),
            ("POST", "/channel/enabled"),
            ("POST", "/mywatch/enabled"),
            ("GET", &format!("/channel/manifest/{}", "11".repeat(32))[..]),
        ] {
            let (status, _) = send(&app, method, uri, vec![], None).await;
            assert_eq!(status, StatusCode::UNAUTHORIZED, "{method} {uri}");
        }
        let (status, _) =
            send(&app, "GET", "/channels", vec![], Some("sekrit")).await;
        assert_eq!(status, StatusCode::OK);
    }
}

#[cfg(test)]
mod tests {
    use super::parse_range;

    #[test]
    fn open_ended_range() {
        assert_eq!(parse_range("bytes=100-", 1000), Some((100, 999)));
    }

    #[test]
    fn closed_range_clamped_to_size() {
        assert_eq!(parse_range("bytes=0-4095", 1000), Some((0, 999)));
    }

    #[test]
    fn suffix_range() {
        assert_eq!(parse_range("bytes=-100", 1000), Some((900, 999)));
    }

    #[test]
    fn unsatisfiable_start_past_eof() {
        assert_eq!(parse_range("bytes=1000-", 1000), None);
    }

    #[test]
    fn garbage_rejected() {
        assert_eq!(parse_range("bites=0-1", 1000), None);
        assert_eq!(parse_range("bytes=a-b", 1000), None);
    }
}
