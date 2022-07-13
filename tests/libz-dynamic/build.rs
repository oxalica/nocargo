fn main() {
    std::env::var("DEP_Z_INCLUDE").expect_err("Dynamic linking should not set DEP_Z_INCLUDE");
    println!("cargo:rustc-env=OKAY=");
}
