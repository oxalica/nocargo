pub fn show(s: String) {
    assert!(s.starts_with(bar::hello()));
    println!("{}", s);
}
