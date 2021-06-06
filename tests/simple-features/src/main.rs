#[cfg(all(feature = "a", not(feature = "b")))]
fn main() {
    println!("Hello, world!");
}
