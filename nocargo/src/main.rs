use anyhow::{ensure, Result};
use std::process::Command;
use structopt::StructOpt;

#[derive(StructOpt)]
enum Opt {
    Build(OptBuild),
}

#[derive(StructOpt)]
struct OptBuild {
    // Use profile `release` instead of `dev`.
    #[structopt(long)]
    release: bool,
}

fn main() -> Result<()> {
    match Opt::from_args() {
        Opt::Build(opt) => main_build(opt),
    }
}

fn main_build(opt: OptBuild) -> Result<()> {
    let expr = "
        { profile }:
        let
            pkgs = (builtins.getFlake ''nocargo'').outputs.legacyPackages.${builtins.currentSystem};
            drv = pkgs.nocargo.buildRustCrateFromSrcAndLock { src = ./.; inherit profile; };
        in
            pkgs.symlinkJoin { name = drv.name; paths = [ drv.out drv.dev drv.bin ]; }
    ";
    let profile = if opt.release { "release" } else { "dev" };
    let code = Command::new("nix")
        .args(&["build", "-v", "-L", "--impure", "--expr", expr])
        .args(&["--argstr", "profile", profile])
        .spawn()?
        .wait()?;
    ensure!(code.success(), "Exited with {:?}", code.code());
    Ok(())
}
