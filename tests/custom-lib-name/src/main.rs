fn main() {
    assert_eq!(color::consts::PURPLE, color::Rgb::new(0x80, 0x00, 0x80));
    assert_eq!(renamed::consts::PURPLE, renamed::Rgb::new(0x80, 0x00, 0x80));
    assert_eq!(custom::custom(), 42);
    println!("Hello, world!");
}
