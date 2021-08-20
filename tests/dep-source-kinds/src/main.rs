bitflags::bitflags! {
    struct Flags: u32 {
        const A = 0b01;
    }
}

// cfg_if1::cfg_if! {
//     if #[cfg(not(feature = "wtf"))] {
//         fn bar2() {}
//     }
// }

cfg_if2::cfg_if! {
    if #[cfg(not(feature = "wtf"))] {
        fn bar2() {}
    }
}

fn main() {
    assert_eq!(Flags::A | Flags::A, Flags::A);
    // bar1();
    bar2();
    // assert_eq!(local::foo(), 42);
    assert_eq!(semver1::Version::parse("1.2.3").unwrap(), semver1::Version::new(1, 2, 3));
    assert_eq!(semver2::Version::parse("1.2.3").unwrap(), semver2::Version::new(1, 2, 3));
    assert_eq!(semver3::Version::parse("1.2.3").unwrap(), semver3::Version::new(1, 2, 3));
    assert_eq!(semver4::Version::parse("1.2.3").unwrap(), semver4::Version::new(1, 2, 3));
    println!("Hello, world!");
}
