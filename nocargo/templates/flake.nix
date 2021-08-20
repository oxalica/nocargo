{
  description = "Rust crate {{ crate_name|nix_str }}";

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
    registry-{{ loop.index }} = { url = "{{ flake_ref|nix_str }}"; flake = false; };
    {%- endfor %}
    {%- for (_, flake_ref) in git_srcs %}
    git-{{ loop.index }} = { url = "{{ flake_ref|nix_str }}"; flake = false; };
    {%- endfor %}
  };

  outputs = { nixpkgs, flake-utils, rust-overlay, nocargo, ... }@inputs:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ rust-overlay.overlay nocargo.overlay ];
        };

        rustc = pkgs.rust-bin.stable.latest.minimal;
        {%- if !registries.is_empty() %}
        extraRegistries = {
          {%- for (source_id, _) in registries %}
          "{{ source_id|nix_str }}" = pkgs.lib.nocargo.mkIndex inputs.registry-{{ loop.index }};
          {%- endfor %}
        };
        {%- endif %}
        {%- if !git_srcs.is_empty() %}
        gitSources = {
          {%- for (source_id, _) in git_srcs %}
          "{{ source_id|nix_str }}" = inputs.git-{{ loop.index }};
          {%- endfor %}
        };
        {%- endif %}

      in
      rec {
        defaultPackage = packages."{{ crate_name|nix_str }}";
        defaultApp = defaultPackage.bin;

        packages."{{ crate_name|nix_str }}" = pkgs.nocargo.buildRustCrateFromSrcAndLock {
          src = ./.;
          inherit /* rustc */
            {%- if !registries.is_empty() %} extraRegistries{% endif %}
            {%- if !git_srcs.is_empty() %} gitSources{% endif %};
        };
      });
}
