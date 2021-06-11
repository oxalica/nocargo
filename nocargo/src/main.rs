use anyhow::{ensure, Result};
use std::process::Command;
use structopt::StructOpt;

#[derive(StructOpt)]
enum Opt {
    Build(OptBuild),
}

#[derive(StructOpt)]
struct OptBuild {}

fn main() -> Result<()> {
    match Opt::from_args() {
        Opt::Build(opt) => main_build(opt),
    }
}

fn main_build(_: OptBuild) -> Result<()> {
    let expr = "let \
        pkgs = (builtins.getFlake ''nocargo'').outputs.legacyPackages.${builtins.currentSystem}; \
        drv = pkgs.nocargo.buildRustCrateFromSrcAndLock { src = ./.; }; \
        in pkgs.symlinkJoin { name = drv.name; paths = [ drv.out drv.dev drv.bin ]; }\
    ";
    let code = Command::new("nix")
        .args(&["build", "-v", "-L", "--impure", "--expr", expr])
        .spawn()?
        .wait()?;
    ensure!(code.success(), "Exited with {:?}", code.code());
    Ok(())
}
