fn main() {
    let header =
        std::fs::read_to_string(std::env::var("DEP_Z_INCLUDE").unwrap() + "/zlib.h").unwrap();
    assert!(header
        .starts_with("/* zlib.h -- interface of the 'zlib' general purpose compression library"));
    println!("cargo:rustc-env=OKAY=");
}
