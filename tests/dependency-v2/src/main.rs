fn main() {
    cratesio::Version::parse("1.2.3").unwrap();
    registry_index::Version::parse("1.2.3").unwrap();
    git_tag::Version::parse("1.2.3").unwrap();
    git_branch::Version::parse("1.2.3").unwrap();
    git_rev::Version::parse("1.2.3").unwrap();
    git_head::Version::parse("1.2.3").unwrap();
    println!("Hello, world!");
}
