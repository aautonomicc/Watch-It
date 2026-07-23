//! Embedded Autonomi client for Watch-It.
//!
//! The Flutter app calls [`watchit_core_start`] once over dart:ffi; it
//! brings up a tokio runtime, an ant-core client (connected lazily) and a
//! localhost HTTP server, and returns the bound port. The player then
//! streams `http://127.0.0.1:{port}/xor/{address}` like any HTTP source.

pub mod cache;
pub mod engine;
pub mod mapstore;
pub mod server;

use std::ffi::CStr;
use std::os::raw::c_char;
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::OnceLock;

use engine::Engine;

static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
static ENGINE: OnceLock<Engine> = OnceLock::new();
static PORT: AtomicI32 = AtomicI32::new(0);

/// Route panic messages through tracing so they reach logcat on Android
/// (a bare panic in a tokio task is otherwise swallowed silently).
fn init_panic_hook() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        let prev = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            tracing::error!("panic: {info}");
            prev(info);
        }));
    });
}

fn init_tracing() {
    #[cfg(target_os = "android")]
    {
        use tracing_subscriber::layer::SubscriberExt;
        if let Ok(layer) = tracing_android::layer("watchit_core") {
            let _ = tracing::subscriber::set_global_default(
                tracing_subscriber::registry().with(layer),
            );
        }
    }
    #[cfg(not(target_os = "android"))]
    {
        let _ = tracing_subscriber::fmt()
            .with_env_filter(
                tracing_subscriber::EnvFilter::try_from_default_env()
                    .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
            )
            .try_init();
    }
}

/// ant-core resolves its cache/config paths through `$HOME` / `$XDG_*`
/// and panics (an `unwrap` deep in its `config::data_dir`) when none are
/// set — the normal state for an Android app process, where it killed
/// every connect attempt with `HomeDirNotFound`. Point those variables at
/// the app's own data dir before any ant-core code runs; the peer cache
/// and adaptive-controller snapshots then persist there for free.
fn ensure_dirs_env(data_dir: Option<&str>) {
    match data_dir.filter(|d| !d.trim().is_empty()) {
        Some(dir) => {
            let _ = std::fs::create_dir_all(dir);
            for var in ["HOME", "XDG_DATA_HOME", "XDG_CONFIG_HOME"] {
                if std::env::var_os(var).is_none() {
                    std::env::set_var(var, dir);
                }
            }
        }
        None => {
            // No dir supplied: still guarantee $HOME exists so ant-core
            // cannot panic; its caches just won't persist anywhere useful.
            if std::env::var_os("HOME").is_none() {
                std::env::set_var("HOME", std::env::temp_dir());
            }
        }
    }
}

/// Start the embedded client + streaming server.
///
/// `peers_csv` optionally overrides the built-in bootstrap peer list with a
/// comma-separated `ip:port` list; pass NULL to use the defaults.
/// `data_dir` is the app's writable data directory, used to give ant-core
/// a `$HOME` on platforms without one (Android); pass NULL to leave the
/// process environment alone (desktop).
///
/// Returns the localhost port the server is listening on (>0), or a
/// negative error code. Idempotent: repeat calls return the existing port.
///
/// # Safety
/// `peers_csv` and `data_dir` must each be NULL or a valid NUL-terminated
/// C string.
#[no_mangle]
pub unsafe extern "C" fn watchit_core_start(
    peers_csv: *const c_char,
    data_dir: *const c_char,
) -> i32 {
    let existing = PORT.load(Ordering::SeqCst);
    if existing > 0 {
        return existing;
    }
    init_tracing();
    init_panic_hook();

    let cstr_arg = |p: *const c_char| -> Result<Option<String>, ()> {
        if p.is_null() {
            Ok(None)
        } else {
            CStr::from_ptr(p).to_str().map(|s| Some(s.to_string())).map_err(|_| ())
        }
    };
    let (peers, dir) = match (cstr_arg(peers_csv), cstr_arg(data_dir)) {
        (Ok(p), Ok(d)) => (p, d),
        _ => return -1,
    };
    ensure_dirs_env(dir.as_deref());

    match start(peers.as_deref(), dir.as_deref()) {
        Ok(port) => port,
        Err(e) => {
            tracing::error!("watchit_core_start failed: {e}");
            -2
        }
    }
}

/// Port the server is bound to, or 0 if not started.
#[no_mangle]
pub extern "C" fn watchit_core_port() -> i32 {
    PORT.load(Ordering::SeqCst)
}

/// Rust-side start, shared by the FFI entry point and the dev server.
/// `data_dir` (the app's writable directory) hosts the persistent
/// root-map cache; pass None to run without one (devserver/tests).
pub fn start(peers_override: Option<&str>, data_dir: Option<&str>) -> Result<i32, String> {
    let existing = PORT.load(Ordering::SeqCst);
    if existing > 0 {
        return Ok(existing);
    }
    init_panic_hook();
    ensure_dirs_env(None); // no-op when the FFI entry already set $HOME

    // Multi-threaded runtime is required: ant-core's decrypt paths use
    // block_in_place.
    let runtime = RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .thread_name("watchit-core")
            .build()
            .expect("tokio runtime")
    });
    let engine = ENGINE.get_or_init(|| Engine::new(peers_override, data_dir));

    let listener = runtime.block_on(async {
        tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .map_err(|e| format!("bind failed: {e}"))
    })?;
    let port = listener
        .local_addr()
        .map_err(|e| format!("local_addr failed: {e}"))?
        .port() as i32;

    let app = server::router(engine);
    runtime.spawn(async move {
        // Keep connecting until it sticks. A single warm-up attempt is not
        // enough: nothing else retries until a playback request arrives, so
        // one failed bootstrap left the app stuck on "connecting" forever.
        tokio::spawn(async {
            let mut delay = std::time::Duration::from_secs(2);
            loop {
                match engine.client().await {
                    Ok(_) => break,
                    Err(e) => tracing::warn!("connect failed, retrying in {delay:?}: {e}"),
                }
                tokio::time::sleep(delay).await;
                delay = (delay * 2).min(std::time::Duration::from_secs(60));
            }
        });
        if let Err(e) = axum::serve(listener, app).await {
            tracing::error!("http server exited: {e}");
        }
    });

    PORT.store(port, Ordering::SeqCst);
    tracing::info!("watchit_core listening on 127.0.0.1:{port}");
    Ok(port)
}
