{
  inputs = {
    crates-io-index = {
      url = "github:rust-lang/crates.io-index";
      flake = false;
    };
  };

  outputs = { self, crates-io-index }: {
    overlay = final: prev: let
      out = import ./. final prev;
      out' = {
        crates-nix = out.crates-nix // {
          inherit (crates-io-index);
        };
      };
    in out';
  };
}

