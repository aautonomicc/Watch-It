fn main() {
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
