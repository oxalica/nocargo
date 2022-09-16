#[derive(Debug, thiserror::Error)]
enum Error {
    #[error("Hello, {0}!")]
    Hello(&'static str),
}

fn main() {
    println!("{}", Error::Hello("world"));
}
