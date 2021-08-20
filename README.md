# nocargo: Cargo in nix

**WIP: The project is still working in progress.**

## Installation

**TODO**

0. Ensure you are using nix unstable with flake support enabled.
1. Clone the repository, and `cd` into it.
2. Run `nix build` to build the defaultPackage, which is `nocargo` binary.
3. Run `nix registry add nocargo "$(pwd)"` to add the repository to global flake registry, which is used in runtime.
4. Play with `./result/bin/nocargo`.

## Usage

### Create a flake.nix which builds your crate.

1. `cd` to your rust project root which containing `Cargo.toml` and `Cargo.lock` (workspace is not supported yet).
2. `/path/to/bin/nocargo init` (replace the path to `nocargo` to your real one)
3. A `flake.nix` is generated. Check its content and `git add flake.nix`.
4. `nix build` to build your library, and `nix build .#defaultApp.x86_64-linux` to build binaries.
