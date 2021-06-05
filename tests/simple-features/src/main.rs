#[cfg(and(feature = "a", not(feature = "b")))]
fn main() {
    println!("Hello, world!");
}
