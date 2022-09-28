use std::env::var;

fn main() {
    if var("CARGO_FEATURE_QUUX").is_err() {
        if let Ok(s) = var("CARGO_FEATURE_FOO_BAR") {
            println!("cargo:rustc-cfg=result={:?}", s);
        }
    }
}
