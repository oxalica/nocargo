{ lib }:
let
  inherit (builtins) match elemAt from fromJSON;
  inherit (lib) compare compareLists splitString all any;
in rec {
  parseSemver = ver: let
    m = match "([0-9]+)\\.([0-9]+)\\.([0-9]+)(-([A-Za-z0-9.-]+))?(\\+[A-Za-z0-9.-]+)?" ver;
  in
    if m == null then
      throw "Invalid semver: `${ver}`"
    else {
      maj = fromJSON (elemAt m 0);
      min = fromJSON (elemAt m 1);
      pat = fromJSON (elemAt m 2);
      pre = elemAt m 4;
    };

  compareSemver = a: b: let
    m1 = parseSemver a;
    m2 = parseSemver b;
  in
    if m1.maj != m2.maj then
      if m1.maj < m2.maj then -1 else 1
    else if m1.min != m2.min then
      if m1.min < m2.min then -1 else 1
    else if m1.pat != m2.pat then
      if m1.pat < m2.pat then -1 else 1
    else
      comparePre m1.pre m2.pre;

  comparePre = a: b:
    if a == null then
      if b == null then
        0
      else
        1
    else if b == null then
      -1
    else
      comparePreList (splitString "." a) (splitString "." b);

  isNumber = s: match "[0-9]+" s != null;

  comparePreList = compareLists (a: b:
    let
      num1 = if isNumber a then fromJSON a else null;
      num2 = if isNumber b then fromJSON b else null;
    in
      if num1 != null then
        if num2 != null then
          compare num1 num2
        else
          -1
      else if num2 != null then
        1
      else
        compare a b
  );

  parseSemverReq = req: let
    reqs = splitString "," req;
    comparators = map parseComparators reqs;
  in
    ver: all (f: f ver) comparators && (isPreVersion ver -> any (containsExactPreVersion ver) reqs);

  isPreVersion = ver: match "[0-9.]+-.*" ver != null;
  containsExactPreVersion = ver: req: let
    m = parseSemver ver;
  in
    match " *(=|<|<=|>|>=|~|\\^)? *${toString m.maj}\\.${toString m.min}\\.${toString m.pat}-.*" req != null;

  opEq = { compMaj, compMin, compPat, compPre }: { maj, min, pat, pre }:
    maj == compMaj &&
    (compMin == null || min == compMin) &&
    (compPat == null || pat == compPat) &&
    (compPre == null || comparePre pre compPre == 0);

  opLtGt = op: { compMaj, compMin, compPat, compPre }: { maj, min, pat, pre }:
    if maj != compMaj then
      op maj compMaj
    else if compMin == null then
      false
    else if min != compMin then
      op min compMin
    else if compPat == null then
      false
    else if pat != compPat then
      op pat compPat
    else
      op (comparePre pre compPre) 0;

  opTilde = { compMaj, compMin, compPat, compPre }: { maj, min, pat, pre }:
    maj == compMaj &&
    (compMin == null || min == compMin) &&
    (compPat == null || pat > compPat || (pat == compPat &&
      comparePre pre compPre >= 0));

  opCaret = { compMaj, compMin, compPat, compPre }: { maj, min, pat, pre }:
    if maj != compMaj then
      false
    else if compMin == null then
      true
    else if compPat == null then
      if maj > 0 then
        min >= compMin
      else
        min == compMin
    else if maj > 0 then
      if min != compMin then
        min > compMin
      else if pat != compPat then
        pat > compPat
      else
        comparePre pre compPre >= 0
    else if min > 0 then
      if min != compMin then
        false
      else if pat != compPat then
        pat > compPat
      else
        comparePre pre compPre >= 0
    else if min != compMin || pat != compPat then
      false
    else
      comparePre pre compPre >= 0;

  parseComparators = req: let
    toInt = s: if s == null then null else fromJSON s;

    star = match " *(([0-9]+)\\.(([0-9]+)\\.)?)?\\*(\\.\\*)? *" req;
    star0 = elemAt star 1;
    star1 = elemAt star 3;
    comp = match " *(=|>|>=|<|<=|~|\\^)? *(([0-9]+)(\\.([0-9]+)(\\.([0-9]+)(-([A-Za-z0-9.-]+))?(\\+[A-Za-z0-9.-]*)?)?)?) *" req;
    compOp = elemAt comp 0;
    compVer = elemAt comp 1;
    compArgs = {
      compMaj = toInt (elemAt comp 2);
      compMin = toInt (elemAt comp 4);
      compPat = toInt (elemAt comp 6);
      compPre = elemAt comp 8;
    };

    less = a: b: a < b;
    greater = a: b: a > b;
    op = {
      "=" = opEq compArgs;
      "<" = opLtGt less compArgs;
      "<=" = args: opLtGt less compArgs args || opEq compArgs args;
      ">" = opLtGt greater compArgs;
      ">=" = args: opLtGt greater compArgs args || opEq compArgs args;
      "~" = opTilde compArgs;
      "^" = opCaret compArgs;
    }.${if compOp != null then compOp else "^"};

  in
    if star != null then
      if star0 == null then
        (ver: true)
      else if star1 == null then
        (ver: match "${toString star0}\\..*" ver != null)
      else
        (ver: match "${toString star0}\\.${toString star1}\\..*" ver != null)
    else if comp != null then
      (ver: op (parseSemver ver))
    else
      throw "Invalid version comparator: `${req}`";

  version-compare-tests = { assertEq, ... }: {
    version-compare-simple1 = assertEq (compareSemver "1.2.3" "1.2.2") 1;
    version-compare-simple2 = assertEq (compareSemver "1.2.3" "1.2.3") 0;
    version-compare-simple3 = assertEq (compareSemver "1.2.3" "1.2.4") (-1);
    version-compare-simple4 = assertEq (compareSemver "1.2.3" "1.1.3") 1;
    version-compare-simple5 = assertEq (compareSemver "1.2.3" "1.3.3") (-1);
    version-compare-simple6 = assertEq (compareSemver "1.2.3" "0.2.3") 1;
    version-compare-simple7 = assertEq (compareSemver "1.2.3" "2.2.3") (-1);
  };

  # From https://github.com/dtolnay/semver/blob/a03d376560e0c4d16518bc271867b1981c85acf0/tests/test_version_req.rs
  version-req-tests = { assertEqMsg, ... }: let
    testMatchReq = req: { yes ? [], no ? [] }: let
      checker = parseSemverReq req;
    in
      map (ver: assertEqMsg ver (checker ver) true) yes ++
      map (ver: assertEqMsg ver (checker ver) false) no;
  in {
    version-req-eq1 = testMatchReq "=1.0.0" {
      yes = [ "1.0.0" ];
      no  = [ "1.0.1" "0.9.9" "0.10.0" "0.1.0" "1.0.0-pre" ];
    };
    version-req-default = testMatchReq "^1.0.0" {
      yes = [ "1.0.0" "1.1.0" "1.0.1" ];
      no  = [ "0.9.9" "0.10.0" "0.1.0" "1.0.0-pre" "1.0.1-pre" ];
    };
    version-req-exact1 = testMatchReq "=1.0.0" {
      yes = [ "1.0.0" ];
      no  = [ "1.0.1" "0.9.9" "0.10.0" "0.1.0" "1.0.0-pre" ];
    };
    version-req-exact2 = testMatchReq "=0.9.0" {
      yes = [ "0.9.0" ];
      no  = [ "0.9.1" "1.9.0" "0.0.9" "0.9.0-pre" ];
    };
    version-req-exact3 = testMatchReq "=0.0.2" {
      yes = [ "0.0.2" ];
      no  = [ "0.0.1" "0.0.3" "0.0.2-pre" ];
    };
    version-req-exact4 = testMatchReq "=0.1.0-beta2.a" {
      yes = [ "0.1.0-beta2.a" ];
      no  = [ "0.9.1" "0.1.0" "0.1.1-beta2.a" "0.1.0-beta2" ];
    };
    version-req-exact5 = testMatchReq "=0.1.0" {
      yes = [ "0.1.0" "0.1.0+meta" "0.1.0+any" ];
    };
    version-req-gt1 = testMatchReq ">= 1.0.0" {
      yes = [ "1.0.0" "2.0.0" ];
      no  = [ "0.1.0" "0.0.1" "1.0.0-pre" "2.0.0-pre" ];
    };
    version-req-gt2 = testMatchReq ">=2.1.0-alpha2" {
      yes = [ "2.1.0-alpha2" "2.1.0-alpha3" "2.1.0" "3.0.0" ];
      no  = [ "2.0.0" "2.1.0-alpha1" "2.0.0-alpha2" "3.0.0-alpha2" ];
    };
    version-req-lt1 = testMatchReq "<1.0.0" {
      yes = [ "0.1.0" "0.0.1" ];
      no  = [ "1.0.0" "1.0.0-beta" "1.0.1" "0.9.9-alpha" ];
    };
    version-req-le1 = testMatchReq "<= 2.1.0-alpha2" {
      yes = [ "2.1.0-alpha2" "2.1.0-alpha1" "2.0.0" "1.0.0" ];
      no  = [ "2.1.0" "2.2.0-alpha1" "2.0.0-alpha2" "1.0.0-alpha2" ];
    };
    version-req-multi1 = testMatchReq ">1.0.0-alpha, <1.0.0" {
      yes = [ "1.0.0-beta" ];
    };
    version-req-multi2 = testMatchReq ">1.0.0-alpha, <1.0" {
      no  = [ "1.0.0-beta" ];
    };
    version-req-multi3 = testMatchReq ">1.0.0-alpha, <1" {
      no  = [ "1.0.0-beta" ];
    };
    version-req-multi4 = testMatchReq "> 0.0.9, <= 2.5.3" {
      yes = [ "0.0.10" "1.0.0" "2.5.3" ];
      no  = [ "0.0.8" "2.5.4" ];
    };
    version-req-multi5 = testMatchReq "0.3.0, 0.4.0" {
      no  = [ "0.0.8" "0.3.0" "0.4.0" ];
    };
    version-req-multi6 = testMatchReq "<= 0.2.0, >= 0.5.0" {
      no  = [ "0.0.8" "0.3.0" "0.5.1" ];
    };
    version-req-multi7 = testMatchReq "^0.1.0, ^0.1.4, ^0.1.6" {
      yes = [ "0.1.6" "0.1.9" ];
      no  = [ "0.1.0" "0.1.4" "0.2.0" ];
    };
    version-req-multi8 = testMatchReq ">=0.5.1-alpha3, <0.6" {
      yes = [ "0.5.1-alpha3" "0.5.1-alpha4" "0.5.1-beta" "0.5.1" "0.5.5" ];
      no  = [ "0.5.1-alpha1" "0.5.2-alpha3" "0.5.5-pre" "0.5.0-pre" "0.6.0" "0.6.0-pre" ];
    };
    version-req-tilde1 = testMatchReq "~1" {
      yes = [ "1.0.0" "1.0.1" "1.1.1" ];
      no  = [ "0.9.1" "2.9.0" "0.0.9" ];
    };
    version-req-tilde2 = testMatchReq "~1.2" {
      yes = [ "1.2.0" "1.2.1" ];
      no  = [ "1.1.1" "1.3.0" "0.0.9" ];
    };
    version-req-tilde3 = testMatchReq "~1.2.2" {
      yes = [ "1.2.2" "1.2.4" ];
      no  = [ "1.2.1" "1.9.0" "1.0.9" "2.0.1" "0.1.3" ];
    };
    version-req-tilde4 = testMatchReq "~1.2.3-beta.2" {
      yes = [ "1.2.3" "1.2.4" "1.2.3-beta.2" "1.2.3-beta.4" ];
      no  = [ "1.3.3" "1.1.4" "1.2.3-beta.1" "1.2.4-beta.2" ];
    };
    version-req-caret1 = testMatchReq "^1" {
      yes = [ "1.1.2" "1.1.0" "1.2.1" "1.0.1" ];
      no  = [ "0.9.1" "2.9.0" "0.1.4" "1.0.0-beta1" "0.1.0-alpha" "1.0.1-pre" ];
    };
    version-req-caret2 = testMatchReq "^1.1" {
      yes = [ "1.1.2" "1.1.0" "1.2.1" ];
      no  = [ "0.9.1" "2.9.0" "1.0.1" "0.1.4" ];
    };
    version-req-caret3 = testMatchReq "^1.1.2" {
      yes = [ "1.1.2" "1.1.4" "1.2.1" ];
      no  = [ "0.9.1" "2.9.0" "1.1.1" "0.0.1" "1.1.2-alpha1" "1.1.3-alpha1" "2.9.0-alpha1" ];
    };
    version-req-caret4 = testMatchReq "^0.1.2" {
      yes = [ "0.1.2" "0.1.4" ];
      no  = [ "0.9.1" "2.9.0" "1.1.1" "0.0.1" "0.1.2-beta" "0.1.3-alpha" "0.2.0-pre" ];
    };
    version-req-caret5 = testMatchReq "^0.5.1-alpha3" {
      yes = [ "0.5.1-alpha3" "0.5.1-alpha4" "0.5.1-beta" "0.5.1" "0.5.5" ];
      no  = [ "0.5.1-alpha1" "0.5.2-alpha3" "0.5.5-pre" "0.5.0-pre" "0.6.0" ];
    };
    version-req-caret6 = testMatchReq "^0.0.2" {
      yes = [ "0.0.2" ];
      no  = [ "0.9.1" "2.9.0" "1.1.1" "0.0.1" "0.1.4" ];
    };
    version-req-caret7 = testMatchReq "^0.0" {
      yes = [ "0.0.2" "0.0.0" ];
      no  = [ "0.9.1" "2.9.0" "1.1.1" "0.1.4" ];
    };
    version-req-caret8 = testMatchReq "^0" {
      yes = [ "0.9.1" "0.0.2" "0.0.0" ];
      no  = [ "2.9.0" "1.1.1" ];
    };
    version-req-caret9 = testMatchReq "^1.4.2-beta.5" {
      yes = [ "1.4.2" "1.4.3" "1.4.2-beta.5" "1.4.2-beta.6" "1.4.2-c" ];
      no  = [ "0.9.9" "2.0.0" "1.4.2-alpha" "1.4.2-beta.4" "1.4.3-beta.5" ];
    };
    version-req-star1 = testMatchReq "*" {
      yes = [ "0.9.1" "2.9.0" "0.0.9" "1.0.1" "1.1.1" ];
    };
    version-req-star2 = testMatchReq "1.*" {
      yes = [ "1.2.0" "1.2.1" "1.1.1" "1.3.0" ];
      no  = [ "0.0.9" ];
    };
    version-req-star3 = testMatchReq "1.2.*" {
      yes = [ "1.2.0" "1.2.2" "1.2.4" ];
      no  = [ "1.9.0" "1.0.9" "2.0.1" "0.1.3" ];
    };
    version-req-pre = testMatchReq "=2.1.1-really.0" {
      yes = [ "2.1.1-really.0" ];
    };
  };
}
