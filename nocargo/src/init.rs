use std::collections::BTreeMap;
use std::fs::File;
use std::io::Write;
use std::path::{Path, PathBuf};

use anyhow::{bail, ensure, Context, Result};
use askama::Template;
use cargo_toml::{Dependency, Manifest};
use once_cell::sync::Lazy;
use regex::Regex;

/// Create or print template `flake.nix` for your rust crate.
#[derive(clap::Args)]
pub struct Args {
    /// Print the content of initial `flake.nix` to stdout rather than to a file.
    #[clap(long, short)]
    print: bool,

    /// Force overwrite `flake.nix` even if it exists.
    #[clap(long, short, conflicts_with = "print")]
    force: bool,

    /// The project root directory, where the root `Cargo.toml` lies in.
    /// Default to be the current directory.
    root: Option<PathBuf>,
}

impl super::App for Args {
    fn run(self) -> Result<()> {
        let root = self.root.unwrap_or_else(|| ".".into());
        let cargo_toml_path = root.join("Cargo.toml");
        let flake_nix_path = root.join("flake.nix");

        // Fast check.
        ensure!(
            self.force || self.print || !flake_nix_path.exists(),
            "flake.nix already exists, use --force to overwrite or --print to print to stdout only",
        );

        // TODO: Assert there is no ancestor Cargo.toml.
        let manifest = Manifest::from_path(&cargo_toml_path)
            .with_context(|| format!("Cannot load Cargo.toml at {:?}", cargo_toml_path))?;

        let out = generate_flake(&manifest)?;

        if self.print {
            println!("{}", out);
        } else {
            let mut f = File::options()
                .write(true)
                .create(true)
                .truncate(self.force)
                .open(&flake_nix_path)
                .with_context(|| format!("Cannot write to flake.nix at {:?}", flake_nix_path))?;
            f.write_all(out.as_bytes())?;
            f.flush()?;
        }

        Ok(())
    }
}

#[derive(Template)]
#[template(path = "../templates/init-flake.nix", escape = "none")]
struct FlakeTemplate {
    main_pkg_name: String,
    // source_id ->  flake_ref
    registries: BTreeMap<String, String>,
    // source_id ->  flake_ref
    git_srcs: BTreeMap<String, String>,
}

mod filters {
    pub fn nix_escape(s: &str) -> askama::Result<String> {
        Ok(s.replace('\\', "\\\\").replace('"', "\\\""))
    }

    pub fn ident_or_str(s: &str) -> askama::Result<String> {
        const KEYWORDS: &[&str] = &[
            "if", "then", "else", "assert", "with", "let", "in", "rec", "inherit", "or",
        ];
        let is_ident_start = |c: char| c.is_ascii_alphabetic() || c == '_';
        let is_ident_char =
            |c: char| c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '\'';
        if s.starts_with(is_ident_start) && s.chars().all(is_ident_char) && !KEYWORDS.contains(&s) {
            Ok(s.into())
        } else {
            Ok(s.replace('\\', "\\\\").replace('"', "\\\""))
        }
    }
}

fn generate_flake(manifest: &Manifest) -> Result<String> {
    // TODO
    ensure!(manifest.patch.is_empty(), "[patch] is not supported yet");
    // TODO
    ensure!(
        manifest.workspace.is_none(),
        "[workspace] is not supported yet",
    );

    let main_pkg_name = manifest
        .package
        .as_ref()
        .context("Missing [package]")?
        .name
        .clone();
    let mut templ = FlakeTemplate {
        main_pkg_name,
        registries: Default::default(),
        git_srcs: Default::default(),
    };

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
        (|| -> Result<()> {
            match DepSource::try_from(dep)? {
                // Automatically handled by nocargo.
                DepSource::CratesIo => {}
                DepSource::RegistryName { name } => {
                    bail!("External registry with name {:?} is not supported", name)
                }
                DepSource::Path { path } => {
                    // TODO
                    bail!(
                        "Local path dependency {:?} is not supported yet",
                        path.display(),
                    )
                }
                DepSource::RegistryUrl { url } => {
                    let flake_ref = git_url_to_flake_ref(url, None, None)?;
                    templ.registries.insert(url.into(), flake_ref);
                }
                DepSource::Git { url, ref_ } => {
                    let source_url = match ref_ {
                        GitRef::NotSpecified => url.to_owned(),
                        GitRef::Tag(tag) => format!("{}?tag={}", url, tag),
                        GitRef::Branch(branch) => format!("{}?branch={}", url, branch),
                        GitRef::Rev(rev) => format!("{}?rev={}", url, rev),
                    };

                    let (ref_name, rev) = match ref_ {
                        GitRef::Tag(ref_name) | GitRef::Branch(ref_name) => (Some(ref_name), None),
                        GitRef::NotSpecified => (None, None),
                        GitRef::Rev(rev) => (None, Some(rev)),
                    };

                    let flake_ref = git_url_to_flake_ref(url, ref_name, rev)?;
                    templ.git_srcs.insert(source_url, flake_ref);
                }
            }
            Ok(())
        })()
        .with_context(|| format!("In dependency {:?}", dep_name))?;
    }

    Ok(templ.render().unwrap())
}

// https://doc.rust-lang.org/cargo/reference/specifying-dependencies.html
#[derive(Debug, Clone, Copy)]
enum DepSource<'a> {
    CratesIo,
    RegistryName { name: &'a str },
    RegistryUrl { url: &'a str },
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

impl<'a> TryFrom<&'a Dependency> for DepSource<'a> {
    type Error = anyhow::Error;

    fn try_from(dep: &'a Dependency) -> Result<Self, Self::Error> {
        match dep {
            Dependency::Simple(_) => Ok(Self::CratesIo),
            Dependency::Detailed(detail) => {
                match (&detail.registry, &detail.registry_index, &detail.path, &detail.git) {
                    (None, None, None, None) => Ok(Self::CratesIo),
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

// https://nixos.org/manual/nix/unstable/command-ref/new-cli/nix3-flake.html?#flake-inputs
pub fn git_url_to_flake_ref(
    url_orig: &str,
    ref_name: Option<&str>,
    rev: Option<&str>,
) -> Result<String> {
    let url = url_orig.strip_prefix("git+").unwrap_or(url_orig);
    ensure!(
        url.starts_with("http://")
            || url.starts_with("https://")
            || url.starts_with("ssh://")
            || url.starts_with("git://"),
        "Only http/https/ssh/git schemas are supported for git url, got: {}",
        url_orig,
    );

    static RE_GITHUB_URL: Lazy<Regex> =
        Lazy::new(|| Regex::new(r"^https?://github.com/([^/?#]+)/([^/?#]+?)(.git)?/?$").unwrap());

    if let Some(cap) = RE_GITHUB_URL.captures(url) {
        let owner = cap.get(1).unwrap().as_str();
        let repo = cap.get(2).unwrap().as_str();
        return Ok(match rev.or(ref_name) {
            Some(rev) => format!("github:{}/{}/{}", owner, repo, rev),
            None => format!("github:{}/{}", owner, repo),
        });
    }

    ensure!(
        !url.contains(|c| c == '?' || c == '#'),
        "Url containing `?` or `#` is not supported yet: {}",
        url_orig,
    );

    let prefix = if url.starts_with("git://") {
        ""
    } else {
        "git+"
    };
    let ret = match (ref_name, rev) {
        (_, Some(rev)) => format!("{}{}?rev={}", prefix, url, rev),
        (Some(ref_name), None) => format!("{}{}?ref={}", prefix, url, ref_name),
        (None, None) => format!("{}{}", prefix, url),
    };
    Ok(ret)
}

#[cfg(test)]
mod tests {
    use super::git_url_to_flake_ref as f;

    #[test]
    fn test_flake_url_schemas() {
        assert_eq!(
            f("https://example.com", Some("dev"), Some("123")).unwrap(),
            "git+https://example.com?rev=123"
        );
        assert_eq!(
            f("https://example.com", None, Some("123")).unwrap(),
            "git+https://example.com?rev=123"
        );
        assert_eq!(
            f("https://example.com", Some("dev"), None).unwrap(),
            "git+https://example.com?ref=dev"
        );
        assert_eq!(
            f("https://example.com", None, None).unwrap(),
            "git+https://example.com"
        );

        assert_eq!(
            f("http://example.com", None, None).unwrap(),
            "git+http://example.com"
        );
        assert_eq!(
            f("git+https://example.com", None, None).unwrap(),
            "git+https://example.com"
        );
        assert_eq!(
            f("git://example.com", None, None).unwrap(),
            "git://example.com"
        );
        assert_eq!(
            f("git+git://example.com", None, None).unwrap(),
            "git://example.com"
        );
        assert_eq!(
            f("git+ssh://git@github.com/foo/bar", None, None).unwrap(),
            "git+ssh://git@github.com/foo/bar"
        );
        f("ws://example.com", None, None).unwrap_err();
    }

    #[test]
    fn test_flake_url_github() {
        assert_eq!(
            f("https://github.com/foo/bar", Some("dev"), Some("123")).unwrap(),
            "github:foo/bar/123"
        );
        assert_eq!(
            f("https://github.com/foo/bar", None, Some("123")).unwrap(),
            "github:foo/bar/123"
        );
        assert_eq!(
            f("https://github.com/foo/bar", Some("dev"), None).unwrap(),
            "github:foo/bar/dev"
        );
        assert_eq!(
            f("https://github.com/foo/bar", None, None).unwrap(),
            "github:foo/bar"
        );

        assert_eq!(
            f("https://github.com/foo/bar.git", None, None).unwrap(),
            "github:foo/bar"
        );
        assert_eq!(
            f("https://github.com/foo/bar/", None, None).unwrap(),
            "github:foo/bar"
        );
        assert_eq!(
            f("http://github.com/foo/bar.git", None, None).unwrap(),
            "github:foo/bar"
        );
        assert_eq!(
            f("git+https://github.com/foo/bar.git", None, None).unwrap(),
            "github:foo/bar"
        );
    }
}
