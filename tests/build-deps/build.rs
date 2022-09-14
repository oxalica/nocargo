fn main() {
    let s = semver::Version::new(1, 2, 3).to_string();
    println!("cargo:rustc-cfg=result={:?}", s);
}
