fn main() {
    // Only available in the build script.
    assert!(option_env!("DEP_Z_INCLUDE").is_none());

    let crc_init = unsafe { libz_sys::crc32(0, "foo".as_ptr() as _, 3) };
    assert_eq!(crc_init, 2356372769);
    assert_eq!(env!("OKAY"), "");
    println!("Hello, world!");
}
