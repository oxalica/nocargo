{
  description = "Rust package {{ main_pkg_name|nix_escape }}";

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
        pkgs = nixpkgs.legacyPackages.${system};

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
        gitSources = {
          {%- for (source_id, _) in git_srcs %}
          "{{ source_id|nix_escape }}" = inputs.git-{{ loop.index }};
          {%- endfor %}
        };
        {%- endif %}

      in rec {
        packages = {
          default = packages.{{ main_pkg_name|ident_or_str }};
          {{ main_pkg_name|ident_or_str }} = nocargo.lib.${system}.buildRustPackageFromSrcAndLock {
            src = ./.;
            inherit rustc
              {%- if !registries.is_empty() %} extraRegistries{% endif %}
              {%- if !git_srcs.is_empty() %} gitSources{% endif %};
          };
        };
      });
}
