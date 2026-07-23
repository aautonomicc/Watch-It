//! Localhost HTTP server the media player streams from.
//!
//! `GET /xor/{address}` serves a public Autonomi file as decrypted bytes
//! with byte-range support (`Accept-Ranges: bytes`), which is what libmpv
//! needs for seeking. `GET /health` reports client connection state.

use axum::body::Body;
use axum::extract::Path;
use axum::http::{header, HeaderMap, Method, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::Router;
use tokio_stream::wrappers::ReceiverStream;
use tokio_stream::StreamExt as _;

use crate::engine::Engine;

pub fn router(engine: &'static Engine) -> Router {
    Router::new()
        .route("/health", get(move || health(engine)))
        .route(
            "/resolve/{addr}",
            get(move |path: Path<String>| resolve_map(engine, path)),
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

/// Resolve (and persist) the root data map for an address without
/// streaming any content — the prefetch path. Second-ever play of the
/// title then skips resolution entirely, even across app restarts.
async fn resolve_map(engine: &'static Engine, Path(addr_hex): Path<String>) -> Response {
    let mut addr = [0u8; 32];
    if hex::decode_to_slice(addr_hex.trim(), &mut addr).is_err() {
        return (StatusCode::BAD_REQUEST, "address must be 64 hex chars").into_response();
    }
    match engine.root_map(addr).await {
        Ok(root) => {
            let body = serde_json::json!({
                "size": root.original_file_size() as u64,
                "chunks": root.len(),
            });
            ([(header::CONTENT_TYPE, "application/json")], body.to_string())
                .into_response()
        }
        Err(e) => {
            tracing::warn!("resolve {addr_hex}: {e}");
            (StatusCode::BAD_GATEWAY, e).into_response()
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

    let root = match engine.root_map(addr).await {
        Ok(dm) => dm,
        Err(e) => {
            tracing::warn!("{addr_hex}: {e}");
            return (StatusCode::BAD_GATEWAY, e).into_response();
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
