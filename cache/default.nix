{ writeText, mkRustPackageOrWorkspace }:
let
  ws = mkRustPackageOrWorkspace {
    src = ./.;
  };
in
writeText "cache-paths"
  (toString (ws.dev.cache.dependencies ++ ws.release.cache.dependencies))
