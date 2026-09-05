/// Bake the pinned network-stack versions out of Cargo.lock into the
/// binary (rustc-env), served by the open `GET /versions` route so the
/// Settings → Built-in clients page always shows what was actually
/// compiled in. Never hardcode these anywhere else — the lockfile is
/// the single source of truth and a missing package fails the build.
fn dep_versions() {
    let lock = std::fs::read_to_string("Cargo.lock").expect("Cargo.lock unreadable");
    println!("cargo:rerun-if-changed=Cargo.lock");
    // saorsa-gossip publishes as a sub-crate family (all one version);
    // -runtime stands in for it.
    for (want, lock_name) in [
        ("x0x", "x0x"),
        ("ant-core", "ant-core"),
        ("saorsa-core", "saorsa-core"),
        ("saorsa-gossip", "saorsa-gossip-runtime"),
        ("ant-quic", "ant-quic"),
    ] {
        let block = lock
            .split("[[package]]")
            .find(|b| b.contains(&format!("name = \"{lock_name}\"")))
            .unwrap_or_else(|| panic!("{lock_name} missing from Cargo.lock"));
        let field = |key: &str| {
            block.lines().find_map(|l| {
                l.strip_prefix(&format!("{key} = \""))?.strip_suffix('"').map(str::to_owned)
            })
        };
        let mut version = field("version").unwrap_or_else(|| panic!("{want} has no version"));
        // Git pins (ant-core) carry the short rev so "0.8.1" from a repo
        // is distinguishable from the crates.io release of that number.
        if let Some(source) = field("source") {
            if let Some(rev) = source.strip_prefix("git+").and_then(|s| s.split('#').nth(1)) {
                version = format!("{version} (git {})", &rev[..rev.len().min(8)]);
            }
        }
        let env_name = want.to_uppercase().replace('-', "_");
        println!("cargo:rustc-env=WATCHIT_DEP_{env_name}={version}");
    }
}

fn main() {
    dep_versions();
    // Linux-gnu only: Android/bionic and musl have no __isoc23_* versioning.
    let target = std::env::var("TARGET").unwrap_or_default();
    if target.contains("linux") && target.contains("gnu") {
        cc::Build::new()
            .file("compat/isoc23_shim.c")
            .flag("-std=gnu17")
            .compile("isoc23_shim");
        println!("cargo:rerun-if-changed=compat/isoc23_shim.c");
    }
}
