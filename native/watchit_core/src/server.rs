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
use axum::extract::{DefaultBodyLimit, Path};
use axum::http::{header, HeaderMap, Method, StatusCode};
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

pub fn router(engine: &'static Engine) -> Router {
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
    let body = if engine.is_ready() {
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

/// Kick the reconnect supervisor: cancel its current backoff sleep (or
/// poll interval) so a connect attempt starts now. No-op in effect while
/// connected with peers — the supervisor just re-samples and carries on.
/// Returns the current health JSON so the caller sees where things stand.
async fn reconnect(engine: &'static Engine) -> Response {
    engine.kick_reconnect();
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
/// bare serialized root map — msgpack canonically, legacy ant-gui JSON
/// when the first byte is `{` (the same sniff as ant-core's
/// `read_datamap`) — derive its content address offline, and store it.
/// The derived address is the entry's identity everywhere; for a file
/// that was uploaded publicly it equals the public XOR address, so old
/// entries and new imports of the same content coincide.
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
    let addr = match crate::verify::derive_address(&map) {
        Ok(a) => a,
        Err(e) => return (StatusCode::UNPROCESSABLE_ENTITY, e).into_response(),
    };
    engine.store_root_map(addr, &map);
    let body = serde_json::json!({
        "address": hex::encode(addr),
        "size": map.original_file_size() as u64,
        "chunks": map.len(),
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
    async fn datamap_import_rejects_garbage_and_child_maps() {
        let app = test_router("datamap-bad");
        let (status, _) = send(&app, "POST", "/datamap", b"junk".to_vec()).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);

        let (_, root) = upload();
        let child = DataMap::with_child(root.infos().to_vec(), 1);
        let (status, _) = send(
            &app,
            "POST",
            "/datamap",
            rmp_serde::to_vec(&child).unwrap(),
        )
        .await;
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
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
