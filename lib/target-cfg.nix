{ lib, ... }:
let
  inherit (builtins) match tryEval;
  inherit (lib)
    concatStrings
    length elem elemAt any all sort flatten isList
    optionalAttrs mapAttrsToList;
in
rec {
  # https://doc.rust-lang.org/reference/conditional-compilation.html#target_arch
  platformToTargetArch = platform:
    if platform.isAarch32 then "arm"
    else platform.parsed.cpu.name;

  # https://doc.rust-lang.org/reference/conditional-compilation.html#target_os
  platformToTargetOs = platform:
    if platform.isDarwin then "macos"
    else platform.parsed.kernel.name;

  # https://github.com/rust-lang/rust/blob/9bc8c42bb2f19e745a63f3445f1ac248fb015e53/compiler/rustc_session/src/config.rs#L835
  # https://doc.rust-lang.org/reference/conditional-compilation.html
  platformToCfgAttrs = platform: {
    # Arch info.
    # https://github.com/NixOS/nixpkgs/blob/c63d4270feed5eb6c578fe2d9398d3f6f2f96811/pkgs/build-support/rust/build-rust-crate/configure-crate.nix#L126
    target_arch = platformToTargetArch platform;
    target_endian = if platform.isLittleEndian then "little"
      else if platform.isBigEndian then "big"
      else throw "Unknow target_endian for ${platform.config}";
    target_env = if platform.isNone then ""
      else if platform.libc == "glibc" then "gnu"
      else if platform.isMusl then "musl"
      else if platform.isDarwin then "" # Empty
      else lib.trace platform (throw "Unknow target_env for ${platform.config}");
    target_family = if platform.isUnix then "unix"
      else if platform.isWindows then "windows"
      else null;
    target_os = platformToTargetOs platform;
    target_pointer_width = toString platform.parsed.cpu.bits;
    target_vendor = platform.parsed.vendor.name;
  } // optionalAttrs platform.isx86 {
    # These features are assume to be available.
    target_feature = [ "fxsr" "sse" "sse2" ];
  } // optionalAttrs platform.isUnix {
    unix = true;
  } // optionalAttrs platform.isWindows {
    windows = true;
  };

  platformToCfgs = platform:
    flatten (
      mapAttrsToList (key: value:
        if value == true then { inherit key; }
        else if isList value then map (value: { inherit key value; }) value
        else { inherit key value; }
      ) (platformToCfgAttrs platform));

  # cfgs: [
  #   { key = "atom1"; }
  #   { key = "atom2"; }
  #   { key = "feature"; value = "foo"; }
  #   { key = "feature"; value = "bar"; }
  # ]
  evalTargetCfgStr = cfgs: s:
    evalCfgExpr cfgs (parseTargetCfgExpr s);

  # Cargo's parse is stricter than rustc's.
  # - Must starts with `cfg(` and ends with `)`. No spaces are allowed before and after.
  # - Identifiers must follows /[A-Za-z_][A-Za-z_0-9]*/.
  # - Raw identifiers, raw strings, escapes in strings are not allowed.
  #
  # The target can also be a simple target name like `aarch64-unknown-linux-gnu`, which will be parsed
  # as if it's `cfg(target = "...")`.
  #
  # https://github.com/rust-lang/cargo/blob/dcc95871605785c2c1f2279a25c6d3740301c468/crates/cargo-platform/src/cfg.rs
  parseTargetCfgExpr = cfg: let
    fail = reason: throw "${reason}, when parsing `${cfg}";

    go = { fn, values, afterComma, prev }@stack: s: let
      m = match ''((all|any|not) *\( *|(\)) *|(,) *|([A-Za-z_][A-Za-z_0-9]*) *(= *"([^"]*)" *)?)(.*)'' s;
      mFn = elemAt m 1;
      mClose = elemAt m 2;
      mComma = elemAt m 3;
      mIdent = elemAt m 4;
      mString = elemAt m 6;
      mRest = elemAt m 7;
    in
      if s == "" then
        stack
      else if m == null then
        fail "No parse `${s}`"
      # else if builtins.trace ([ stack m ]) (mFn != null) then
      else if mFn != null then
        if !afterComma then
          fail "Missing comma before `${mFn}` at `${s}"
        else
          go { fn = mFn; values = []; afterComma = true; prev = stack; } mRest
      else if mClose != null then
        if prev == null then
          fail "Unexpected `)` at `${s}`"
        else if fn == "not" && length values == 0 then
          fail "`not` must have exact one argument, got 0"
        else if prev.fn == "not" && length prev.values != 0 then
          fail "`not` must have exact one argument, got at least 2"
        else
          go (prev // { values = prev.values ++ [ { inherit (stack) fn values; } ]; afterComma = false; }) mRest
      else if mComma != null then
        if afterComma then
          fail "Unexpected `,` at `${s}`"
        else
          go (stack // { afterComma = true; }) mRest
      else
        if !afterComma then
          fail "Missing comma before identifier `${mIdent}` at `${s}"
        else if fn == "not" && length values != 0 then
          fail "`not` must have exact one argument, got at least 2"
        else
          let kv =
            if mString != null then { key = mIdent; value = mString; }
            else { key = mIdent; };
          in
            go (stack // { afterComma = false; values = values ++ [ kv ]; }) mRest;

      mSimpleTarget = match "[A-Za-z_0-9_.-]+" cfg;

      mCfg = match ''cfg\( *(.*)\)'' cfg;
      mCfgInner = elemAt mCfg 0;
      ret = go { fn = "cfg"; values = []; afterComma = true; prev = null; } mCfgInner;

    in
      if mSimpleTarget != null then
        { key = "target"; value = cfg; }
      else if mCfg == null then
        fail "Cfg expr must be a simple target string, or start with `cfg(` and end with `)`"
      else if ret.prev != null then
        fail "Missing `)`"
      else if length ret.values != 1 then
        fail "`cfg` must have exact one argument, got ${toString (length ret.values)}"
      else
        elemAt ret.values 0;

  evalCfgExpr = cfgs: tree:
    if !(tree ? fn) then
      elem tree cfgs
    else if tree.fn == "all" then
      all (evalCfgExpr cfgs) tree.values
    else if tree.fn == "any" then
      any (evalCfgExpr cfgs) tree.values
    else
      !evalCfgExpr cfgs (elemAt tree.values 0);

  cfg-parser-tests = { assertEq, ... }: let
    shouldParse = cfg: expect:
      assertEq (tryEval (parseTargetCfgExpr cfg)) { success = true; value = expect; };
    shouldNotParse = cfg:
      assertEq (tryEval (parseTargetCfgExpr cfg)) { success = false; value = false; };
  in {
    simple-target1 = shouldParse "thumbv8m.base-none-eabi"
      { key = "target"; value = "thumbv8m.base-none-eabi"; };
    simple-target2 = shouldParse "aarch64-unknown-linux-gnu"
      { key = "target"; value = "aarch64-unknown-linux-gnu"; };

    simple1 = shouldParse "cfg(atom)" { key = "atom"; };
    simple2 = shouldParse ''cfg(k = "v")'' { key = "k"; value = "v"; };
    complex = shouldParse ''cfg( all ( not ( a , ) , b , all ( ) , any ( c , d = "e" ) , ) )''
      {
        fn = "all";
        values = [
          {
            fn = "not";
            values = [ { key = "a"; } ];
          }
          { key = "b"; }
          {
            fn = "all";
            values = [];
          }
          {
            fn = "any";
            values = [
              { key = "c"; }
              { key = "d"; value = "e"; }
            ];
          }
        ];
      };

    invalid-cfg1 = shouldNotParse "cfg (a)";
    invalid-cfg2 = shouldNotParse "cfg()";
    invalid-cfg3 = shouldNotParse "cfg(a,b)";
    invalid-not1 = shouldNotParse "cfg(not(a,b))";
    invalid-not2 = shouldNotParse "cfg(not())";
    invalid-comma1 = shouldNotParse "cfg(all(,))";
    invalid-comma2 = shouldNotParse "cfg(all(a,,b))";
    invalid-comma3 = shouldNotParse "cfg(all(a,b,,))";
    invalid-comma4 = shouldNotParse "cfg(all(a b))";
    invalid-comma5 = shouldNotParse "cfg(all(any() any()))";
    invalid-paren1 = shouldNotParse "cfg(all(a)))";
    invalid-paren2 = shouldNotParse "cfg(all(a)";
  };

  cfg-eval-tests = { assertEq, ... }: let
    cfgs = [
      { key = "foo"; }
      { key = "bar"; }
      { key = "feature"; value = "foo"; }
      { key = "feature"; value = "bar"; }
    ];
    test = cfg: expect: assertEq (evalTargetCfgStr cfgs cfg) expect;
  in {
    simple1 = test ''cfg(foo)'' true;
    simple2 = test ''cfg(baz)'' false;
    simple3 = test ''cfg(feature = "foo")'' true;
    simple4 = test ''cfg(foo = "")'' false;
    simple5 = test ''cfg(wtf = "foo")'' false;

    all1  = test ''cfg(all())'' true;
    all2  = test ''cfg(all(foo))'' true;
    all3  = test ''cfg(all(baz))'' false;
    all4  = test ''cfg(all(foo,bar))'' true;
    all5  = test ''cfg(all(foo,bar,baz))'' false;
    all6  = test ''cfg(all(foo,baz,bar))'' false;
    all7  = test ''cfg(all(baz,foo))'' false;
    all8  = test ''cfg(all(baz,feature="foo"))'' false;
    all9  = test ''cfg(all(baz,feature="wtf"))'' false;
    all10 = test ''cfg(all(foo,feature="foo"))'' true;

    any1  = test ''cfg(any())'' false;
    any2  = test ''cfg(any(foo))'' true;
    any3  = test ''cfg(any(baz))'' false;
    any4  = test ''cfg(any(foo,bar))'' true;
    any5  = test ''cfg(any(foo,bar,baz))'' true;
    any6  = test ''cfg(any(foo,baz,bar))'' true;
    any7  = test ''cfg(any(baz,foo))'' true;
    any8  = test ''cfg(any(baz,feature="foo"))'' true;
    any9  = test ''cfg(any(baz,feature="wtf"))'' false;
    any10 = test ''cfg(any(foo,feature="wtf"))'' true;

    not1 = test ''cfg(not(foo))'' false;
    not2 = test ''cfg(not(wtf))'' true;
  };

  platform-cfg-tests = { assertEq, ... }: let
    inherit (lib.systems) elaborate;
    test = config: expect: let
      cfgs = platformToCfgs (elaborate config);
      strs = map ({ key, value ? null }:
        if value != null then "${key}=\"${value}\"\n" else "${key}\n"
      ) cfgs;
      got = concatStrings (sort (a: b: a < b) strs);
    in
      assertEq got expect;

  in {
    attrs-x86_64-linux = assertEq (platformToCfgAttrs (elaborate "x86_64-unknown-linux-gnu")) {
      target_arch = "x86_64";
      target_endian = "little";
      target_env = "gnu";
      target_family = "unix";
      target_feature = ["fxsr" "sse" "sse2"];
      target_os = "linux";
      target_pointer_width = "64";
      target_vendor = "unknown";
      unix = true;
    };

    cfg-x86_64-linux = test "x86_64-unknown-linux-gnu" ''
      target_arch="x86_64"
      target_endian="little"
      target_env="gnu"
      target_family="unix"
      target_feature="fxsr"
      target_feature="sse"
      target_feature="sse2"
      target_os="linux"
      target_pointer_width="64"
      target_vendor="unknown"
      unix
    '';

    cfg-aarch64-linux = test "aarch64-unknown-linux-gnu" ''
      target_arch="aarch64"
      target_endian="little"
      target_env="gnu"
      target_family="unix"
      target_os="linux"
      target_pointer_width="64"
      target_vendor="unknown"
      unix
    '';
  };
}
