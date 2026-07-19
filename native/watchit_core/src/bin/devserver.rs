//! Host-side harness: starts the embedded server and prints the port, so
//! streaming can be exercised with curl/mpv before touching Android.
//!
//!     cargo run --release --bin devserver
//!     curl -H 'Range: bytes=0-1023' http://127.0.0.1:PORT/xor/ADDR

fn main() {
    // WATCHIT_PEERS="ip:port,ip:port" overrides the bootstrap list — handy
    // for exercising the connect-failure/retry path with a dead peer.
    let peers = std::env::var("WATCHIT_PEERS").ok();
    let port = watchit_core::start(peers.as_deref()).expect("start embedded server");
    println!("PORT={port}");
    println!("try: curl http://127.0.0.1:{port}/health");
    loop {
        std::thread::sleep(std::time::Duration::from_secs(3600));
    }
}
