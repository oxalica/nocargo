fn main() {
    let z_include = std::env::var("DEP_Z_INCLUDE").unwrap();
    let header = std::fs::read_to_string(z_include + "/zlib.h").unwrap();
    let mut lines = header.lines();
    assert_eq!(
        lines.next().unwrap(),
        "/* zlib.h -- interface of the 'zlib' general purpose compression library"
    );
    assert_eq!(
        lines.next().unwrap(),
        "  version 1.2.11, January 15th, 2017",
        "bundled libz MUST be 1.2.11",
    );
    println!("cargo:rustc-env=OKAY=");
}
