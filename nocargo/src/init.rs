use std::io::Write;
use std::path::{Path, PathBuf};

use anyhow::{bail, ensure, Context, Result};
use askama::Template;
use cargo_toml::{Dependency, Manifest};
use structopt::StructOpt;

use crate::App;

/// Create or print template `flake.nix` for your rust crate.
#[derive(StructOpt)]
pub struct Opt {
    /// Print the content of initial `flake.nix` to stdout rather than to file.
    #[structopt(long, short)]
    print: bool,
    /// Force overwrite `flake.nix` if exists.
    #[structopt(long, short, conflicts_with = "print")]
    force: bool,

    /// The project root directory.
    #[structopt(default_value = ".")]
    path: PathBuf,
}

// https://doc.rust-lang.org/cargo/reference/specifying-dependencies.html
// TODO: Support more sources.
#[allow(dead_code)]
enum DepSource<'a> {
    CratesIo,
    ExternalRegistry { registry: &'a str },
    Path { path: &'a Path },
    Git { url: &'a str, rev: Option<&'a str> },
}

impl<'a> DepSource<'a> {
    fn try_from_dep(dep: &'a Dependency) -> Result<Self> {
        match dep {
            Dependency::Simple(_) => Ok(Self::CratesIo),
            Dependency::Detailed(detail) => {
                match (&detail.registry, &detail.path, &detail.git) {
                    (Some(registry), None, None) => Ok(Self::ExternalRegistry { registry }),
                    (None, Some(path), None) => Ok(Self::Path {
                        path: Path::new(path),
                    }),
                    (None, None, Some(url)) => {
                        let tot = detail.branch.is_some() as u32
                            + detail.rev.is_some() as u32
                            + detail.tag.is_some() as u32;
                        ensure!(tot <= 1, "For git dependency, at most one of `branch`, `rev` and `tag` is allowed");
                        let rev = detail
                            .branch
                            .as_deref()
                            .or(detail.rev.as_deref())
                            .or(detail.tag.as_deref());
                        Ok(Self::Git { url, rev })
                    }
                    _ => bail!("Ambiguous dependency source: {:?}", dep),
                }
            }
        }
    }
}

impl App for Opt {
    fn run(self) -> Result<()> {
        let cargo_toml_path = self.path.join("Cargo.toml");
        let flake_nix_path = self.path.join("flake.nix");

        // Fast check.
        ensure!(
            self.force || self.print || !flake_nix_path.exists(),
            "flake.nix already exists, use --force to overwrite or --print to print to stdout only",
        );

        let manifest = cargo_toml::Manifest::from_path(&cargo_toml_path)
            .with_context(|| format!("Cannot load Cargo.toml at {:?}", cargo_toml_path))?;
        let out = generate_flake(&manifest)?;

        if self.print {
            println!("{}", out);
        } else {
            let mut f = std::fs::OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(self.force)
                .open(&flake_nix_path)
                .with_context(|| format!("Cannot open flake.nix at {:?}", flake_nix_path))?;
            f.write_all(out.as_bytes())?;
            f.flush()?;
        }

        Ok(())
    }
}

fn generate_flake(manifest: &Manifest) -> Result<String> {
    ensure!(manifest.patch.is_empty(), "[patch] is not supported yet");
    ensure!(
        manifest.workspace.is_none(),
        "[workspace] is not supported yet",
    );

    let crate_name = &manifest.package.as_ref().context("Missing [package]")?.name;
    let templ = FlakeNixTemplate::new(crate_name.clone());

    let deps = manifest
        .dependencies
        .iter()
        .chain(&manifest.dev_dependencies)
        .chain(&manifest.build_dependencies)
        .chain(manifest.target.values().flat_map(|tgt| {
            tgt.dependencies
                .iter()
                .chain(&tgt.dev_dependencies)
                .chain(&tgt.build_dependencies)
        }));

    for (dep_name, dep) in deps {
        let source = DepSource::try_from_dep(dep)
            .with_context(|| format!("In dependency {:?}", dep_name))?;
        match source {
            // Automatically handled.
            DepSource::CratesIo => {}
            DepSource::ExternalRegistry { .. } => {
                bail!("External registry is not supported yet for {:?}", dep_name)
            }
            DepSource::Path { .. } => bail!("Local path is not supported yet for {:?}", dep_name),
            DepSource::Git { .. } => {
                bail!("Git dependency is not supported yet for {:?}", &dep_name)
            }
        }
    }

    let ret = templ.render().expect("Render failed");
    Ok(ret)
}

#[derive(Template)]
#[template(path = "flake.nix", escape = "none")]
struct FlakeNixTemplate {
    crate_name: String,
    crate_name_escaped: String,
}

impl FlakeNixTemplate {
    fn new(crate_name: String) -> Self {
        Self {
            crate_name_escaped: format!("{:?}", crate_name),
            crate_name,
        }
    }
}
