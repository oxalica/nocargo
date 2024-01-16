# See more usages of nocargo at https://github.com/oxalica/nocargo#readme
{
  {%- if let Some((pkg_name, _)) = main_pkg %}
  description = "Rust package {{ pkg_name|nix_escape }}";
  {%- else %}
  description = "My Rust packages";
  {%- endif %}

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
    nix-filter.url = "github:numtide/nix-filter";
    nocargo = {
      url = "github:oxalica/nocargo";
      inputs.nixpkgs.follows = "nixpkgs";
      # inputs.registry-crates-io.follows = "registry-crates-io";
    };
    # Optionally, you can override crates.io index to get cutting-edge packages.
    # registry-crates-io = { url = "github:rust-lang/crates.io-index"; flake = false; };
    {%- for (_, flake_ref) in registries %}
    registry-{{ loop.index }} = { url = "{{ flake_ref|nix_escape }}"; flake = false; };
    {%- endfor %}
    {%- for (_, flake_ref) in git_srcs %}
    git-{{ loop.index }} = { url = "{{ flake_ref|nix_escape }}"; flake = false; };
    {%- endfor %}
  };

  outputs = { nixpkgs, flake-utils, nocargo, ... }@inputs:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (system:
      let
        ws = nocargo.lib.${system}.mkRustPackageOrWorkspace {
          src = ./.;
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
