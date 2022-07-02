{ lib, ... }:
let
  inherit (builtins) match readDir split foldl';
  inherit (lib)
    replaceStrings isString concatStrings stringLength hasPrefix substring concatStringsSep
    head tail init filter
    isAttrs attrNames mapAttrs getAttrFromPath;
in
rec {
  # We don't allow root-based glob and separator `/` or `\` inside brackets.
  globBracketPat = ''\[!?[^\/][^]\/]*]'';
  globAtomPat = ''[^[\/]|${globBracketPat}'';
  globPat = ''((${globAtomPat})+[\/])*(${globAtomPat})+'';

  # Parse a glob pattern into a list of segments.
  #
  # String -> List ({ lit: String } | { re: String } | { deep: true })
  #
  # `lit` for simple string literal.
  # `re` for segment matching.
  # `deep` for `**`
  #
  # https://docs.rs/glob/0.3.0/glob/struct.Pattern.html
  # https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap09.html#tag_09_04
  parseGlob = glob:
    let
      translateAtom = m:
        let m' = head m; in
        if isString m then
          replaceStrings
            [ "\\" "{"   "("   ")"   "^"   "$"   "|"   "."   "?"  "*" "+"  ]
            [ "/"  "\\{" "\\(" "\\)" "\\^" "\\$" "\\|" "\\." "." ".*" "\\+" ]
            m
        else if hasPrefix "[!" m' then
          "[^" + substring 2 (stringLength m') m'
        else
          m';

      translateSegment = seg:
        if seg == "**" then
          { deep = true; }
        else if match "[^[?*]+" seg != null then
          { lit = seg; }
        else
          { re = concatStrings (map translateAtom (split "(${globBracketPat})" seg)); };

      segments = filter (s: isString s && s != "") (split ''/|\\'' glob);

    in
      if match globPat glob == null then
        throw ''
          Invalid glob pattern: ${glob}
          Note that we don't support root-based pattern and separator `/` or `\` inside brackets.
        ''
      else
        map translateSegment segments;

  # Find all paths in a tree matching a given glob pattern.
  # A path is represented as a list of segments.
  #
  # String -> Set -> List (List String)
  globMatchTree = glob: tree:
    let
      flatMap = f: foldl' (ret: x: ret ++ f x) [];

      go = path: pats:
        let
          pat = head pats;
          pats' = tail pats;
          curTree = getAttrFromPath path tree;
          keys = if isAttrs curTree then attrNames curTree else [];
        in
          if pats == [] then
            [ path ]
          else if pat ? lit then
            if pat.lit == "." then
              go path pats'
            else if pat.lit == ".." then
              if path == [] then
                []
              else
                go (init path) pats'
            else if curTree ? ${pat.lit} then
              go (path ++ [ pat.lit ]) pats'
            else
              []
          else if pat ? deep then # `**`
            go path pats' ++
              flatMap (k: go (path ++ [ k ]) pats) keys # Pass `pats` to recurse into deep directories.
          else if pat ? re then
            flatMap (k: go (path ++ [ k ]) pats')
              (filter (k: match pat.re k != null) keys)
          else
            throw "Unreachable";
    in
      go [] (parseGlob glob);

  # Find all paths inside a filesystem directory matching a given glob pattern.
  # A path is represented as a relative string with `/` as segment separator, eg. "" (root), "foo", "foo/bar"
  #
  # String -> Path -> List String
  globMatchDir = glob: dir:
    let
      pathToTree = dir:
        mapAttrs
          (k: ty: if ty == "directory" then pathToTree (dir + "/${k}") else ty)
          (readDir dir);
      ret = globMatchTree glob (pathToTree dir);
    in
      map (concatStringsSep "/") ret;

  glob-tests = { assertEq, ... }: {
    "0parse" = let
      assertInvalid = glob: assertEq (builtins.tryEval (parseGlob glob)) { success = false; value = false; };
      assertParsed = glob: expect: assertEq (parseGlob glob) expect;
    in {
      invalid1 = assertInvalid "";
      invalid2 = assertInvalid "/";
      invalid3 = assertInvalid "/foo";
      invalid4 = assertInvalid "foo//bar";

      lit1 = assertParsed "foo" [ { lit = "foo"; } ];
      lit2 = assertParsed "!.(^$){}" [ { lit = "!.(^$){}"; } ];
      lit3 = assertParsed "." [ { lit = "."; } ];
      lit4 = assertParsed ".." [ { lit = ".."; } ];

      re1 = assertParsed "*" [ { re = ''.*''; } ];
      re2 = assertParsed ".*" [ { re = ''\..*''; } ];
      re3 = assertParsed "*.*" [ { re = ''.*\..*''; } ];
      re4 = assertParsed "[[][]][![][!]][a-z0-]" [ { re = ''[[][]][^[][^]][a-z0-]''; } ];
      re5 = assertParsed "?.*[[][?.*]?.*" [ { re = ''.\..*[[][?.*].\..*''; } ];
      re6 = assertParsed ".[.]" [ { re = ''\.[.]''; } ];

      deep1 = assertParsed "**" [ { deep = true; } ];

      compound1 = assertParsed
        "./foo/**/*.nix"
        [ { lit = "."; } { lit = "foo"; } { deep = true; } { re = ''.*\.nix''; } ];
      compound2 = assertParsed
        ".*/../log/[!abc]*-[0-9T:-]+0000.log"
        [ { re = ''\..*''; } { lit = ".."; } { lit = "log"; } { re = ''[^abc].*-[0-9T:-]\+0000\.log''; } ];
    };

    "1match-tree" = let
      tree = {
        a = null;
        b = null;
        b1 = null;
        b2 = null;
        bcd = null;
        bed = null;
        c = {
          d.e = {
            af = null;
            f = null;
          };
          g.h = null;
          wtf = null;
        };
        f = null;
        z = {
          a = null;
          b = {
            c = null;
            d.e = null;
          };
        };
      };

      assertMatch = glob: expect:
        let
          ret = globMatchTree glob tree;
          ret' = map (concatStringsSep "/") ret;
        in
          assertEq ret' expect;

    in {
      exact1 = assertMatch "a" [ "a" ];
      exact2 = assertMatch "c/g/h" [ "c/g/h" ];
      exact3 = assertMatch "c/g" [ "c/g" ];

      dot1 = assertMatch "./a" [ "a" ];
      dot2 = assertMatch "./a/../c/g/./h" [ "c/g/h" ];

      re1 = assertMatch "b*" [ "b" "b1" "b2" "bcd" "bed" ];
      re2 = assertMatch "b?" [ "b1" "b2" ];
      re3 = assertMatch "c/*" [ "c/d" "c/g" "c/wtf" ];
      re4 = assertMatch "b?d" [ "bcd" "bed" ];

      deep1 = assertMatch "**/b?d" [ "bcd" "bed" ];
      deep2 = assertMatch "c/**/*f" [ "c/wtf" "c/d/e/af" "c/d/e/f" ];
      deep3 = assertMatch "**/f/.." [ "" "c/d/e" ];
      deep4 = assertMatch "[wz]/**" [ "z" "z/a" "z/b" "z/b/c" "z/b/d" "z/b/d/e" ];
    };

    "2match-dir" = {
      compound1 = assertEq (globMatchDir "*-*.nix" ./.) [ "pkg-info.nix" "target-cfg.nix" ];
      compound2 = assertEq (globMatchDir "./dependent/../**/tokio-[!wtf][opq]?" ../tests) [ "tokio-app" ];
    };
  };
}
