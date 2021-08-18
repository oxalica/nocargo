use std::process::Command;

use anyhow::{ensure, Result};
use structopt::StructOpt;

use super::App;

/// Build the crate with nocargo.
#[derive(StructOpt)]
pub struct Opt {
    /// Use profile `release` instead of `dev`.
    #[structopt(long)]
    release: bool,
}

impl App for Opt {
    fn run(self) -> Result<()> {
        let expr = "
            { profile }:
            let
                pkgs = (builtins.getFlake ''nocargo'').outputs.legacyPackages.${builtins.currentSystem};
                drv = pkgs.nocargo.buildRustCrateFromSrcAndLock { src = ./.; inherit profile; };
            in
                pkgs.symlinkJoin { name = drv.name; paths = [ drv.out drv.dev drv.bin ]; }
        ";
        let profile = if self.release { "release" } else { "dev" };
        let code = Command::new("nix")
            .args(&["build", "-v", "-L", "--impure", "--expr", expr])
            .args(&["--argstr", "profile", profile])
            .spawn()?
            .wait()?;
        ensure!(code.success(), "Exited with {:?}", code.code());
        Ok(())
    }
}
