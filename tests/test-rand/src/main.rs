fn main() {
    let x: f64 = rand::random();
    assert!(0.0 <= x && x < 1.0);
    println!("Hello, world!");
}
