use std::collections::BTreeSet;
use std::io::Write;
use std::path::{Path, PathBuf};

use anyhow::{bail, ensure, Context, Result};
use askama::Template;
use cargo_toml::{Dependency, Manifest};
use once_cell::sync::Lazy;
use regex::Regex;
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
#[derive(Debug, Clone, Copy)]
enum DepSource<'a> {
    CratesIo,
    RegistryName { name: &'a str },
    RegistryUrl { url: &'a str, },
    Path { path: &'a Path },
    Git { url: &'a str, ref_: GitRef<'a> },
}

#[derive(Debug, Clone, Copy)]
enum GitRef<'a> {
    NotSpecified,
    Tag(&'a str),
    Branch(&'a str),
    Rev(&'a str),
}

impl<'a> DepSource<'a> {
    fn try_from_dep(dep: &'a Dependency) -> Result<Self> {
        match dep {
            Dependency::Simple(_) => Ok(Self::CratesIo),
            Dependency::Detailed(detail) => {
                match (&detail.registry, &detail.registry_index, &detail.path, &detail.git) {
                    (Some(name), None, None, None) => Ok(Self::RegistryName { name }),
                    (None, Some(url), None, None) => Ok(Self::RegistryUrl { url }),
                    (None, None, Some(path), None) => Ok(Self::Path {
                        path: Path::new(path),
                    }),
                    (None, None, None, Some(url)) => {
                        let ref_ = match (&detail.branch, &detail.tag, &detail.rev) {
                            (None, None, None) => GitRef::NotSpecified,
                            (Some(b), None, None) => GitRef::Branch(b),
                            (None, Some(t), None) => GitRef::Tag(t),
                            (None, None, Some(r)) => GitRef::Rev(r),
                            _ => bail!("For git dependency, at most one of `branch`, `rev` and `tag` is allowed"),
                        };
                        Ok(Self::Git { url, ref_ })
                    }
                    _ => bail!(
                        "Only one of `registry`, `registry-index`, `path`, `git` can be specified: {:?}",
                        dep,
                    ),
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

pub fn generate_flake(manifest: &Manifest) -> Result<String> {
    ensure!(manifest.patch.is_empty(), "[patch] is not supported yet");
    ensure!(
        manifest.workspace.is_none(),
        "[workspace] is not supported yet",
    );

    let crate_name = &manifest.package.as_ref().context("Missing [package]")?.name;
    let mut templ = FlakeNixTemplate::new(crate_name.clone());

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
            DepSource::RegistryName { .. } => {
                bail!("External registry with name is not supported yet for {:?}", dep_name)
            }
            DepSource::Path { .. } => {
                bail!("Local path dependency is not supported yet for {:?}", dep_name)
            }
            DepSource::RegistryUrl { url } => {
                let flake_ref = git_url_to_flake_ref(url, "master", None)?;
                templ.add_registry(url.to_owned(), flake_ref)?;
            }
            DepSource::Git { url, ref_ } => {
                let (ref_name, rev) = match ref_ {
                    GitRef::Tag(ref_name) | GitRef::Branch(ref_name) => (ref_name, None),
                    // FIXME: Need a warning if ref is missing.
                    GitRef::NotSpecified => ("master", None),
                    GitRef::Rev(rev) => ("master", Some(rev)),
                };
                let flake_ref = git_url_to_flake_ref(url, ref_name, rev)?;

                let source_url = match ref_ {
                    GitRef::NotSpecified => url.to_owned(),
                    GitRef::Tag(tag) => format!("{}?tag={}", url, tag),
                    GitRef::Branch(branch) => format!("{}?branch={}", url, branch),
                    GitRef::Rev(rev) => format!("{}?rev={}", url, rev),
                };

                templ.add_git_src(source_url, flake_ref)?;
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
    // (source_id, flake_ref)
    registries: BTreeSet<(String, String)>,
    // (source_id, flake_ref)
    git_srcs: BTreeSet<(String, String)>,
}

// https://djc.github.io/askama/filters.html
mod filters {
    pub fn nix_str(s: &str) -> askama::Result<String> {
        Ok(s.escape_default().to_string())
    }
}

impl FlakeNixTemplate {
    fn new(crate_name: String) -> Self {
        Self {
            crate_name,
            registries: BTreeSet::new(),
            git_srcs: BTreeSet::new(),
        }
    }

    fn add_registry(&mut self, source_id: String, flake_url: String) -> Result<()> {
        self.registries.insert((source_id, flake_url));
        Ok(())
    }

    fn add_git_src(&mut self, source_id: String, flake_url: String) -> Result<()> {
        self.git_srcs.insert((source_id, flake_url));
        Ok(())
    }
}

// https://nixos.org/manual/nix/unstable/command-ref/new-cli/nix3-flake.html?#flake-inputs
pub fn git_url_to_flake_ref(url_orig: &str, ref_name: &str, rev: Option<&str>) -> Result<String> {
    let url = url_orig.strip_prefix("git+").unwrap_or(url_orig);
    ensure!(
        url.starts_with("http://") ||
        url.starts_with("https://") ||
        url.starts_with("ssh://") ||
        url.starts_with("git://"),
        "Only http/https/ssh/git schema are supported for git url: {:?}",
        url_orig,
    );

    static RE_GITHUB_URL: Lazy<Regex> = Lazy::new(|| {
        Regex::new(r"^https?://github.com/([^/?#]+)/([^/?#]+?)(.git)?/?$").unwrap()
    });

    if let Some(cap) = RE_GITHUB_URL.captures(url) {
        let owner = cap.get(1).unwrap().as_str();
        let repo = cap.get(2).unwrap().as_str();
        let rev = rev.unwrap_or(ref_name);
        return Ok(format!("github:{}/{}/{}", owner, repo, rev));
    }

    ensure!(
        !url.contains(|c| c == '?' || c == '#'),
        "Url containing `?` or `#` is not supported yet: {:?}",
        url_orig,
    );

    let prefix = if url.starts_with("git://") { "" } else { "git+" };

    match rev {
        None => Ok(format!("{}{}?ref={}", prefix, url, ref_name)),
        Some(rev) => Ok(format!("{}{}?ref={}&rev={}", prefix, url, ref_name, rev)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_flake_url() {
        let f = git_url_to_flake_ref;
        // Schemas.
        assert_eq!(f("https://example.com", "ref", None).unwrap(), "git+https://example.com?ref=ref");
        assert_eq!(f("https://example.com", "ref", Some("123")).unwrap(), "git+https://example.com?ref=ref&rev=123");
        assert_eq!(f("git://example.com", "ref", None).unwrap(), "git://example.com?ref=ref");
        assert_eq!(f("git+git://example.com", "ref", None).unwrap(), "git://example.com?ref=ref");
        assert_eq!(f("git+ssh://git@github.com/foo/bar", "ref", None).unwrap(), "git+ssh://git@github.com/foo/bar?ref=ref");

        // GitHub.
        assert_eq!(f("https://github.com/foo/bar", "ref", None).unwrap(), "github:foo/bar/ref");
        assert_eq!(f("https://github.com/foo/bar", "ref", Some("123")).unwrap(), "github:foo/bar/123");
        assert_eq!(f("https://github.com/foo/bar.git", "ref", Some("123")).unwrap(), "github:foo/bar/123");
        assert_eq!(f("https://github.com/foo/bar/", "ref", Some("123")).unwrap(), "github:foo/bar/123");
        assert_eq!(f("http://github.com/foo/bar.git", "ref", Some("123")).unwrap(), "github:foo/bar/123");
        assert_eq!(f("git+https://github.com/foo/bar.git", "ref", Some("123")).unwrap(), "github:foo/bar/123");
    }
}
