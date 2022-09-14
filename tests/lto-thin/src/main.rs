fn main() {
    assert_eq!(
        semver::Version::parse("1.2.3").unwrap().to_string(),
        "1.2.3"
    );
    println!("Hello, world!");
}
