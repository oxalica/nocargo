{ lib }:
let
  inherit (builtins) match substring stringLength length elem elemAt tryEval;
  inherit (lib) any all;
in
rec {
  # cfgs: [
  #   { key = "atom1"; }
  #   { key = "atom2"; }
  #   { key = "feature"; value = "foo"; }
  #   { key = "feature"; value = "bar"; }
  # ]
  evalCfgStr = cfgs: s:
    evalCfgExpr cfgs (parseCfgExpr s);

  # Cargo's parse is stricter than rustc's.
  # - Must starts with `cfg(` and ends with `)`. No spaces are allowed before and after.
  # - Identifiers must follows /[A-Za-z_][A-Za-z_0-9]*/.
  # - Raw identifiers, raw strings, escapes in strings are not allowed.
  #
  # https://github.com/rust-lang/cargo/blob/dcc95871605785c2c1f2279a25c6d3740301c468/crates/cargo-platform/src/cfg.rs
  parseCfgExpr = cfg: let
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

      mCfg = match ''cfg\( *(.*)\)'' cfg;
      mCfgInner = elemAt mCfg 0;
      ret = go { fn = "cfg"; values = []; afterComma = true; prev = null; } mCfgInner;

    in
      if mCfg == null then
        fail "Cfg expr must start with `cfg(` and end with `)`"
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

  cfg-parser-tests = { assertEq, assertDeepEq, ... }: let
    shouldParse = cfg: expect:
      assertDeepEq (parseCfgExpr cfg) expect;
    shouldNotParse = cfg:
      assertEq (tryEval (parseCfgExpr cfg)).success false;
  in {
    cfg-parse-simple1 = shouldParse "cfg(atom)" { key = "atom"; };
    cfg-parse-simple2 = shouldParse ''cfg(k = "v")'' { key = "k"; value = "v"; };
    cfg-parse-complex = shouldParse ''cfg( all ( not ( a , ) , b , all ( ) , any ( c , d = "e" ) , ) )''
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

    cfg-parse-invalid-cfg1 = shouldNotParse "cfg (a)";
    cfg-parse-invalid-cfg2 = shouldNotParse "cfg()";
    cfg-parse-invalid-cfg3 = shouldNotParse "cfg(a,b)";
    cfg-parse-invalid-not1 = shouldNotParse "cfg(not(a,b))";
    cfg-parse-invalid-not2 = shouldNotParse "cfg(not())";
    cfg-parse-invalid-comma1 = shouldNotParse "cfg(all(,))";
    cfg-parse-invalid-comma2 = shouldNotParse "cfg(all(a,,b))";
    cfg-parse-invalid-comma3 = shouldNotParse "cfg(all(a,b,,))";
    cfg-parse-invalid-comma4 = shouldNotParse "cfg(all(a b))";
    cfg-parse-invalid-comma5 = shouldNotParse "cfg(all(any() any()))";
    cfg-parse-invalid-paren1 = shouldNotParse "cfg(all(a)))";
    cfg-parse-invalid-paren2 = shouldNotParse "cfg(all(a)";
  };

  cfg-eval-tests = { assertEq, ... }: let
    cfgs = [
      { key = "foo"; }
      { key = "bar"; }
      { key = "feature"; value = "foo"; }
      { key = "feature"; value = "bar"; }
    ];
    test = cfg: expect: assertEq (evalCfgStr cfgs cfg) expect;
  in {
    cfg-eval-simple1 = test ''cfg(foo)'' true;
    cfg-eval-simple2 = test ''cfg(baz)'' false;
    cfg-eval-simple3 = test ''cfg(feature = "foo")'' true;
    cfg-eval-simple4 = test ''cfg(foo = "")'' false;
    cfg-eval-simple5 = test ''cfg(wtf = "foo")'' false;

    cfg-eval-and1  = test ''cfg(and())'' true;
    cfg-eval-and2  = test ''cfg(and(foo))'' true;
    cfg-eval-and3  = test ''cfg(and(baz))'' false;
    cfg-eval-and4  = test ''cfg(and(foo,bar))'' true;
    cfg-eval-and5  = test ''cfg(and(foo,bar,baz))'' false;
    cfg-eval-and6  = test ''cfg(and(foo,baz,bar))'' false;
    cfg-eval-and7  = test ''cfg(and(baz,foo))'' false;
    cfg-eval-and8  = test ''cfg(and(baz,feature="foo"))'' false;
    cfg-eval-and9  = test ''cfg(and(baz,feature="wtf"))'' false;
    cfg-eval-and10 = test ''cfg(and(foo,feature="wtf"))'' true;

    cfg-eval-any1  = test ''cfg(any())'' false;
    cfg-eval-any2  = test ''cfg(any(foo))'' true;
    cfg-eval-any3  = test ''cfg(any(baz))'' false;
    cfg-eval-any4  = test ''cfg(any(foo,bar))'' true;
    cfg-eval-any5  = test ''cfg(any(foo,bar,baz))'' true;
    cfg-eval-any6  = test ''cfg(any(foo,baz,bar))'' true;
    cfg-eval-any7  = test ''cfg(any(baz,foo))'' true;
    cfg-eval-any8  = test ''cfg(any(baz,feature="foo"))'' true;
    cfg-eval-any9  = test ''cfg(any(baz,feature="wtf"))'' false;
    cfg-eval-any10 = test ''cfg(any(foo,feature="wtf"))'' true;

    cfg-eval-not1 = test ''cfg(not(foo))'' false;
    cfg-eval-not2 = test ''cfg(not(wtf))'' true;
  };
}
