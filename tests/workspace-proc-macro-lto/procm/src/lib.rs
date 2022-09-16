use proc_macro::TokenStream;

#[proc_macro]
pub fn acro(input: TokenStream) -> TokenStream {
    format!(r#"fn main() {{ println!({}) }}"#, input).parse().unwrap()
}
