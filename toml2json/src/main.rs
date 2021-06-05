use std::io::{stdin, stdout, Read, Write};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut input = Vec::new();
    stdin().lock().read_to_end(&mut input)?;
    let data: serde_json::Value = toml::from_slice(&input)?;
    let mut output = serde_json::to_vec(&data)?;
    output.push(b'\n');
    stdout().lock().write_all(&output)?;
    Ok(())
}
