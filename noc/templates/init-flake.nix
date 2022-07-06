{
  {%- if let Some((pkg_name, _)) = main_pkg %}
  description = "Rust package {{ pkg_name|nix_escape }}";
  {%- else %}
  description = "My Rust packages";
  {%- endif %}

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
    nocargo = {
      url = "github:oxalica/nocargo";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.registry-crates-io.follows = "registry-crates-io";
    };

    registry-crates-io = { url = "github:rust-lang/crates.io-index"; flake = false; };
    {%- for (_, flake_ref) in registries %}
    registry-{{ loop.index }} = { url = "{{ flake_ref|nix_escape }}"; flake = false; };
    {%- endfor %}
    {%- for (_, flake_ref) in git_srcs %}
    git-{{ loop.index }} = { url = "{{ flake_ref|nix_escape }}"; flake = false; };
    {%- endfor %}
  };

  outputs = { nixpkgs, flake-utils, rust-overlay, nocargo, ... }@inputs:
    flake-utils.lib.eachSystem [ "x86_64-linux" ] (system:
      let
        ws = nocargo.lib.${system}.mkRustPackageOrWorkspace {
          src = ./.;

          # Use the latest stable release of rustc. Fallback to nixpkgs' rustc if omitted.
          rustc = rust-overlay.packages.${system}.rust;

          {%- if !registries.is_empty() %}
          # Referenced external registries other than crates.io.
          extraRegistries = {
            {%- for (source_id, _) in registries %}
            "{{ source_id|nix_escape }}" = nocargo.lib.${system}.mkIndex inputs.registry-{{ loop.index }} {};
            {%- endfor %}
          };
          {%- endif %}

          {%- if !git_srcs.is_empty() %}
          # Referenced external rust packages from git.
          gitSrcs = {
            {%- for (source_id, _) in git_srcs %}
            "{{ source_id|nix_escape }}" = inputs.git-{{ loop.index }};
            {%- endfor %}
          };
          {%- endif %}
        };
      in rec {
        {%- if is_workspace %}
        packages = {% if let Some((pkg_name, prod)) = main_pkg %}{
          default = packages.{{ pkg_name|ident_or_str }}{% if prod.binary %}.bin{% endif %};
        } // {% endif %}ws.release
          // nixpkgs.lib.mapAttrs' (name: value: { name = "${name}-dev"; inherit value; }) ws.dev;
        {%- else if let Some((pkg_name, prod)) = main_pkg %}
        packages = {
          default = packages.{{ pkg_name|ident_or_str }};
          {{ pkg_name|ident_or_str }} = ws.release.{{ pkg_name|ident_or_str }}{% if prod.binary %}.bin{% endif %};
          {{ pkg_name|ident_or_str }}-dev = ws.dev.{{ pkg_name|ident_or_str }}{% if prod.binary %}.bin{% endif %};
        };
        {%- endif %}
      });
}
