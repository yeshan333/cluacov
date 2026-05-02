local sample = require("sample")

-- ---------------------------------------------------------------------------
-- Section 1: original sample functions (do NOT change — drive the
-- savedpc-off-by-one regression assertions in e2e_branch_coverage.lua).
-- ---------------------------------------------------------------------------

-- Exercise classify: only test positive and zero, skip negative
assert(sample.classify(5) == "positive")
assert(sample.classify(0) == "zero")

-- Exercise abs: only test positive path (no branch taken)
assert(sample.abs(10) == 10)

-- Exercise clamp: only test within range
assert(sample.clamp(5, 1, 10) == 5)

-- Exercise sum: test with a non-empty list (loop runs)
assert(sample.sum({1, 2, 3}) == 6)

-- Exercise find: search for a value that exists
assert(sample.find({10, 20, 30}, 20) == true)

-- Exercise safe_div: only test non-zero divisor
assert(sample.safe_div(10, 2) == 5)

-- Exercise fizzbuzz: test fizzbuzz and fizz, skip buzz and plain number
assert(sample.fizzbuzz(15) == "fizzbuzz")
assert(sample.fizzbuzz(9) == "fizz")

-- Skip max_of_three entirely (no calls)

-- Exercise any_truthy: first call short-circuits on a; second evaluates b
assert(sample.any_truthy(true, nil, nil) == "yes")
assert(sample.any_truthy(nil, true, nil) == "yes")

-- Exercise all_truthy: first two true, third false (partial short-circuit)
assert(sample.all_truthy(true, true, false) == "not all")

-- Exercise mixed_logic: only x>0 and y>0 path
assert(sample.mixed_logic(5, 3) == "match")

-- Regression: exercise function-body first line and if-block first line.
-- These call paths drive the assertions added at the bottom of
-- e2e_branch_coverage.lua to guard against the savedpc off-by-one bug.
assert(sample.first_line_local({kind = "ok"}) == "ok:ok")
assert(sample.first_line_local({kind = "no"}) == "skip")
local out = sample.if_block_first_line({"a", "b", "c"})
assert(#out == 3 and out[1] == "a" and out[2] == "b" and out[3] == "c")

-- ---------------------------------------------------------------------------
-- Section 2: Lua-language showcase functions (lines 132+ of sample.lua).
--
-- We intentionally exercise SOME paths of each function and SKIP others
-- so the public HTML coverage report shows a realistic mix of red and
-- green — exactly what someone evaluating cluacov wants to see.
--
-- Skipped-on-purpose paths (each will show up RED in the report and
-- demonstrate that cluacov correctly attributes "branch not taken"):
--   * while_break: target NOT in list → break path skipped
--   * for_step:    step == 0 error path
--   * try_parse_int: error path (non-integer)
--   * divmod:      division by zero path
--   * factorial:   recursive case for very large n
--   * is_odd:      called only via is_even chain, never directly
--   * dispatch:    "div by zero" path inside dispatch.div
--   * Point:       length() method (only translate is exercised)
-- ---------------------------------------------------------------------------

-- while + break: hit the break path (target found mid-list)
assert(sample.while_break({10, 20, 30, 40}, 30) == 3)
-- DO NOT call with target NOT in list — leaves the "i > #t" return as red

-- repeat..until: collects squares until total >= 100
-- Sequence: 1, 1+4=5, +9=14, +16=30, +25=55, +36=91, +49=140 → stops at i=7
local rep_i, rep_total = sample.repeat_until(100)
assert(rep_i == 7 and rep_total == 140,
   string.format("repeat_until(100) = (%d, %d), expected (7, 140)", rep_i, rep_total))

-- numeric-for with positive step
local out_pos = sample.for_step(1, 5, 1)
assert(out_pos and #out_pos == 5 and out_pos[1] == 1 and out_pos[5] == 5)
-- numeric-for with negative step
local out_neg = sample.for_step(5, 1, -1)
assert(out_neg and #out_neg == 5 and out_neg[1] == 5 and out_neg[5] == 1)
-- DO NOT exercise the `step == 0` error path → leaves L193 red

-- generic-for with pairs: hit the "key found" branch
local v, found = sample.find_in_map({alpha = 1, beta = 2}, "alpha")
assert(v == 1 and found == true)
-- DO NOT exercise the "key not found" branch

-- classify_status: cover SOME, leave several elseif branches red
assert(sample.classify_status(200) == "ok")
assert(sample.classify_status(404) == "not found")
assert(sample.classify_status(503) == "unavailable")
assert(sample.classify_status(301) == "redirect")
-- skip: 504, 401, 403, 4xx-other, 5xx-other, 1xx (informational)

-- short-circuit `or` for default value: cover both branches
assert(sample.with_default(42, 99) == 42)
assert(sample.with_default(nil, 99) == 99)

-- ternary `a and b or c`: cover the `a > b` true branch only
assert(sample.ternary_max(7, 3) == 7)
-- DO NOT call with a < b → leaves the `b` branch red

-- pcall: cover the success branch only
local n, err = sample.try_parse_int("42")
assert(n == 42 and err == nil)
-- DO NOT call with non-integer → leaves the error branch red

-- goto/continue idiom
assert(sample.sum_odd({1, 2, 3, 4, 5}) == 9)  -- 1+3+5

-- vararg + select
assert(sample.count_args(1, nil, "x", nil, true) == 3)
assert(sample.count_args() == 0)

-- multiple return values + destructuring (success path only)
local q, r, derr = sample.divmod(17, 5)
assert(q == 3 and r == 2 and derr == nil)
-- DO NOT exercise b == 0 path → divmod's error branch stays red

-- closure factory + upvalue
local counter = sample.make_counter(10)
assert(counter() == 11)
assert(counter(5) == 16)
assert(counter() == 17)

-- direct recursion: factorial(0), factorial(5)
assert(sample.factorial(0) == 1)
assert(sample.factorial(5) == 120)

-- mutual recursion: only call is_even directly. is_odd is reached
-- transitively but NOT through its own public entry point — the entry
-- guard `if n == 0 then return false` will hit "false" branch only via
-- recursion when n is reached via is_even.
assert(sample.is_even(4) == true)
assert(sample.is_even(7) == false)
-- DO NOT call sample.is_odd directly

-- string-keyed dispatch table: cover add/sub, leave mul/div untaken
assert(sample.dispatch("add", 3, 4) == 7)
assert(sample.dispatch("sub", 10, 6) == 4)
-- the "unknown op" branch:
local r1, e1 = sample.dispatch("nope", 1, 2)
assert(r1 == nil and e1 == "unknown op: nope")
-- DO NOT call mul or div → leaves those dispatch lambdas red

-- metatable + colon-syntax method call
local p = sample.Point.new(3, 4)
p:translate(1, 1)
assert(p.x == 4 and p.y == 5)
-- DO NOT call p:length() → leaves Point:length red

-- table.concat / join: cover both branches
assert(sample.join({}, ",") == "")
assert(sample.join({"a", "b", "c"}, "-") == "a-b-c")

print("E2E test passed")
