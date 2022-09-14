use std::hash::Hasher;

fn main() {
    assert_eq!(b::B, "🅱️");
    let _ = cc::Build::new();
    assert_eq!(fnv::FnvHasher::with_key(42).finish(), 42);
    assert_eq!(xml::escape("<"), "&lt;");
    println!("Hello, world!");
}
