use std::collections::{BTreeMap, HashSet};
use std::fs::{read_dir, File};
use std::io::Write;
use std::path::{Path, PathBuf};

use anyhow::{bail, ensure, Context, Result};
use askama::Template;
use cargo_toml::{Dependency, Manifest, Product};
use glob::glob;
use once_cell::sync::Lazy;
use regex::Regex;

/// Create or print template `flake.nix` for your rust crate.
#[derive(clap::Args)]
pub struct Args {
    /// Print the content of initial `flake.nix` to stdout rather than to `flake.nix` in
    /// the current directory.
    #[clap(long, short)]
    print: bool,

    /// Force overwrite `flake.nix` even if it exists.
    #[clap(long, short, conflicts_with = "print")]
    force: bool,

    /// The Rust project root directory, where the root `Cargo.toml` lies in,
    /// either a project or a workspace.
    /// Default to be the current directory.
    #[clap(long)]
    root: Option<PathBuf>,
}

impl super::App for Args {
    fn run(self) -> Result<()> {
        let root = self
            .root
            .as_deref()
            .unwrap_or_else(|| Path::new("."))
            .canonicalize()
            .context("Failed locate the current directory")?;

        // Always at CWD.
        let out_path = Path::new("flake.nix");
        // Fail fast.
        ensure!(
            self.print || self.force || !out_path.exists(),
            "flake.nix already exists. Use `--force` to overwrite or `--print` to print to stdout only",
        );

        let manifest =
            Manifest::from_path(root.join("Cargo.toml")).context("Failed to load Cargo.toml")?;

        // Check ancestor manifest files for (maybe) workspace definition.
        if manifest.workspace.is_none() && self.root.is_none() {
            if let Some(parent_manifest) = root
                .ancestors()
                .skip(1)
                .map(|p| p.join("Cargo.toml"))
                .find(|p| p.exists())
            {
                bail!(
                    "Are we in a workspace? Found ancestor manifest at {}\n\
                    Please run `init` in the *workspace root* directory. \n\
                    If you are sure the current directory is the root, use `--root=.`",
                    parent_manifest.display(),
                );
            }
        }

        let out = generate_flake(&root, &manifest)?;

        if self.print {
            println!("{}", out);
        } else {
            (|| {
                let mut f = File::options()
                    .write(true)
                    .create(true)
                    .truncate(self.force)
                    .open(out_path)?;
                f.write_all(out.as_bytes())?;
                f.flush()
            })()
            .with_context(|| format!("Failed write to {:?}", out_path))?;
        }

        Ok(())
    }
}

fn generate_flake(root: &Path, manifest: &Manifest) -> Result<String> {
    ensure!(manifest.patch.is_empty(), "[patch] is not supported yet");

    let is_workspace = manifest.workspace.is_some();
    let mut templ = FlakeTemplate {
        is_workspace,
        main_pkg: None,
        registries: Default::default(),
        git_srcs: Default::default(),
    };

    if let Some(pkg) = &manifest.package {
        templ.main_pkg = Some((
            pkg.name.clone(),
            Products::from_path_manifest(root, manifest)?,
        ));
    }

    match &manifest.workspace {
        Some(ws) => {
            ensure!(
                !ws.members.is_empty(),
                "[workspace] without explicit `members` declarations are not supported yet",
            );

            let member_roots = get_workspace_members(root, &ws.members)?;
            let absolute_member_roots = member_roots
                .iter()
                .map(|p| p.canonicalize())
                .collect::<Result<HashSet<_>, _>>()?;
            ensure!(
                member_roots.len() == absolute_member_roots.len(),
                "Duplicated workspace members"
            );

            let member_manifests = member_roots
                .iter()
                .map(|root| {
                    let manifest_path = root.join("Cargo.toml");
                    let manifest = Manifest::from_path(&manifest_path).with_context(|| {
                        format!(
                            "Failed to load member Cargo.toml at {}",
                            manifest_path.display()
                        )
                    })?;
                    Ok(manifest)
                })
                .collect::<Result<Vec<_>>>()?;

            let root_pkg = manifest
                .package
                .is_some()
                .then(|| (Path::new("."), manifest));
            for (member_root, member_manifest) in member_roots
                .iter()
                .map(|p| &**p)
                .zip(&member_manifests)
                .chain(root_pkg)
            {
                for (dep_name, dep) in get_all_dependencies(member_manifest) {
                    templ
                        .check_dependency(dep, |local_path| {
                            let local_dep_root = member_root.join(local_path).canonicalize()?;
                            ensure!(
                                absolute_member_roots.contains(&local_dep_root),
                                "Local dependency not in workspace: {}",
                                local_path.display(),
                            );
                            Ok(())
                        })
                        .with_context(|| {
                            format!(
                                "In dependency {:?} of workspace member {:?}",
                                dep_name,
                                member_root.display(),
                            )
                        })?;
                }
            }
        }
        None => {
            for (dep_name, dep) in get_all_dependencies(manifest) {
                templ
                    .check_dependency(dep, |local_path| {
                        bail!(
                            "Local dependency is not supported for non-workspace: {}",
                            local_path.display(),
                        )
                    })
                    .with_context(|| format!("In dependency {:?}", dep_name))?;
            }
        }
    }

    // The trailing newline is suppressed by default. Add it back.
    Ok(templ.render().unwrap() + "\n")
}

#[derive(Template)]
#[template(path = "../templates/init-flake.nix", escape = "none")]
struct FlakeTemplate {
    is_workspace: bool,
    main_pkg: Option<(String, Products)>,
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

impl FlakeTemplate {
    fn check_dependency(
        &mut self,
        dep: &Dependency,
        mut on_local_dep: impl FnMut(&Path) -> Result<()>,
    ) -> Result<()> {
        match DepSource::try_from(dep)? {
            // Automatically handled by nocargo.
            DepSource::CratesIo => {}
            DepSource::RegistryName { name } => {
                bail!("External registry with name {:?} is not supported", name)
            }
            DepSource::Path { path } => {
                on_local_dep(path)?;
            }
            DepSource::RegistryUrl { url } => {
                let flake_ref = git_url_to_flake_ref(url, None, None)?;
                self.registries.insert(url.into(), flake_ref);
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
                self.git_srcs.insert(source_url, flake_ref);
            }
        }
        Ok(())
    }
}

fn get_workspace_members(root: &Path, members: &[impl AsRef<str>]) -> Result<Vec<PathBuf>> {
    let mut ret = Vec::new();
    for member in members {
        let pat = root.join(member.as_ref());
        let pat = pat
            .to_str()
            .with_context(|| format!("Non UTF-8 path is not supported: {}", pat.display()))?;
        for path in glob(pat)? {
            ret.push(path?);
        }
    }
    Ok(ret)
}

fn get_all_dependencies(manifest: &Manifest) -> impl Iterator<Item = (&str, &Dependency)> {
    manifest
        .dependencies
        .iter()
        .chain(&manifest.dev_dependencies)
        .chain(&manifest.build_dependencies)
        .chain(manifest.target.values().flat_map(|tgt| {
            tgt.dependencies
                .iter()
                .chain(&tgt.dev_dependencies)
                .chain(&tgt.build_dependencies)
        }))
        .map(|(name, dep)| (&**name, dep))
}

#[allow(dead_code)]
#[derive(Debug, Clone)]
struct Products {
    library: bool,
    binary: bool,
    bench: bool,
    test: bool,
    example: bool,
}

impl Products {
    // https://github.com/rust-lang/cargo/blob/rust-1.63.0/src/cargo/util/toml/targets.rs#L3-L8
    fn from_path_manifest(path: &Path, manifest: &Manifest) -> Result<Self> {
        let pkg = manifest.package.as_ref().context("Missing [product]")?;
        let has_product = |decls: &[Product],
                           allow_discover: bool,
                           extra_path: Option<&str>,
                           convention_dir: &str|
         -> Result<bool> {
            if !decls.is_empty() {
                return Ok(true);
            }
            if allow_discover {
                return Ok(false);
            }
            if matches!(extra_path, Some(p) if Path::new(p).is_file()) {
                return Ok(true);
            }
            for ent in read_dir(path.join(convention_dir))? {
                let ent = ent?;
                let file_type = ent.file_type()?;
                // `<dir>/*.rs`
                if file_type.is_file()
                    && Path::new(&ent.file_name())
                        .extension()
                        .map_or(false, |ext| ext == "rs")
                {
                    return Ok(true);
                }
                // `<dir>/*/main.rs`
                if file_type.is_dir() && ent.path().join("main.rs").is_file() {
                    return Ok(true);
                }
            }
            Ok(false)
        };
        Ok(Self {
            library: manifest.lib.is_some() || path.join("src/lib.rs").exists(),
            binary: has_product(&manifest.bin, pkg.autobins, Some("src/main.rs"), "src/bin")?,
            bench: has_product(&manifest.bin, pkg.autobenches, None, "benches")?,
            test: has_product(&manifest.test, pkg.autotests, None, "tests")?,
            example: has_product(&manifest.example, pkg.autoexamples, None, "examples")?,
        })
    }
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
