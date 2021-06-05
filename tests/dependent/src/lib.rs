pub fn hello() {
    assert!(semver::VersionReq::parse(">=1.2.3, <1.8.0")
        .unwrap()
        .matches(&semver::Version::parse("1.3.0").unwrap()));
    println!("Hello, world!");
}
