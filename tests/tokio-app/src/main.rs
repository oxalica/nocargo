#![allow(unused)]
use liboldc::c_int;

#[tokio::main]
async fn main() {
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    println!("hello world");
}
