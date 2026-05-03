# Function coverage inflated by OP_CLOSURE, broken for vararg functions

- **Affected component**: `cluacov.runner` -- `write_lcov` in `src/cluacov/runner.lua`
- **Affected versions**: all versions prior to commit `d511be7`
- **Severity**: medium (silent data correctness, no crash)
- **Discovered**: 2026-05-03
- **Fix commit**: `d511be7`

## Symptom

Two related defects in LCOV function-coverage output:

### 1. FNDA inflation: every defined function appears "called"

When a Lua module is `require`d, the LCOV report shows **every
function** in that module as called (FNDA > 0), even for functions
whose body was never entered. A typical report fragment:

```
FN:65,max_of_three
FNDA:1,max_of_three     <-- function never called, should be 0
DA:65,1                  <-- definition line shows covered
DA:66,0                  <-- but body is entirely uncovered
DA:67,0
```

The HTML report shows 33/33 functions hit when only 31 were actually
called, making function coverage appear 100% when it is not.

### 2. Vararg functions always report FNDA:0

After fixing defect 1 by switching to per-Proto body hits, **vararg
functions** (e.g. `function count_args(...)`) always report `FNDA:0`
despite being called. In the HTML report this shows as 30/33 instead
of the correct 31/33.

### 3. Uncalled function definition lines show as covered

Even with FNDA corrected, the line-coverage (DA) record for an
uncalled function's definition line still shows hits > 0. The HTML
report displays a blue (covered) definition line followed by an
entirely red (uncovered) function body, which is visually misleading.

## Reproduction

### Defect 1 -- FNDA inflation

```lua
-- fn_sample.lua
local M = {}
function M.called(x) return x + 1 end
function M.uncalled(x) return x * 2 end
return M
```

```lua
-- test.lua
local m = require("fn_sample")
m.called(1)
-- m.uncalled is never called
```

Run under `lua -lcluacov.runner test.lua`, then inspect `lcov.info`:

```
FNDA:1,called      -- correct
FNDA:1,uncalled    -- WRONG: should be 0
FNH:2              -- WRONG: should be 1
```

### Defect 2 -- vararg FNDA:0

```lua
local pchook = require("cluacov.pchook")

local normal = load("return function(x) return x end")()
local vararg = load("return function(...) return select('#', ...) end")()

pchook.start()
normal(1)
vararg(1, 2, 3)
pchook.stop()

for _, entry in ipairs(pchook.get_hits(normal)) do
   -- hits[1] = 1  (correct)
   for k, v in pairs(entry.hits) do print("normal", k, v) end
end

for _, entry in ipairs(pchook.get_hits(vararg)) do
   -- hits[1] is NIL, hits[2] = 1
   for k, v in pairs(entry.hits) do print("vararg", k, v) end
end
```

Output:

```
=== normal function ===
  hits[1] = 1
=== vararg function ===
  hits[2] = 1       <-- hits[1] is absent
```

## Root cause

### Defect 1: OP_CLOSURE line hit mistaken for function call

When a module is loaded, the top-level chunk executes `OP_CLOSURE`
instructions to create each function closure. These instructions
are attributed to the `function ... end` definition line in the
source. The original `write_lcov` used the **line-level hit count**
of the definition line as the FNDA value:

```lua
-- runner.lua (before fix)
local hits = line_data[fn.line] or 0
fd:write(string.format("FNDA:%d,%s\n", hits, fn.name))
```

Since `OP_CLOSURE` runs at the definition line, `line_data[fn.line]`
is always > 0 for any function defined in a loaded module, regardless
of whether the function body was ever entered.

The correct approach is to use per-Proto body hits from
`pchook.get_all_hits()`. When a function's Proto is entered by the
VM, pchook records per-PC hit counts in the Proto's `hits` table.
`hits[1]` (corresponding to the first instruction's savedpc) serves
as a reliable proxy for call count.

### Defect 2: OP_VARARGPREP skips the count hook

In Lua 5.4+, vararg functions have `OP_VARARGPREP` as instruction 0.
This instruction is handled specially by the VM and does not trigger
the `LUA_MASKCOUNT` hook in the same dispatch path as regular
instructions. As a result, `hits[1]` (savedpc for PC 0) is never
recorded for vararg functions. The first recorded hit is `hits[2]`
(savedpc for PC 1, the instruction after `OP_VARARGPREP`).

Using `entry.hits[1] or 0` therefore yields 0 for every vararg
function, regardless of how many times it was called.

### Defect 3: DA definition line inherits OP_CLOSURE hit

The DA (line coverage) record faithfully reports the line-level hit
count, which includes the `OP_CLOSURE` execution. For uncalled
functions this produces a covered definition line (blue in HTML)
with an entirely uncovered body (red), creating a visual
contradiction.

## Fix

### FNDA: use per-Proto body hits with vararg fallback

```lua
-- runner.lua (after fix)
local fn_call_counts = {}
for _, entry in ipairs(proto_list) do
   local ld = entry.linedefined
   if ld > 0 then
      local count = entry.hits[1] or entry.hits[2] or 0
      if count > 0 then
         fn_call_counts[ld] = (fn_call_counts[ld] or 0) + count
      end
   end
end
```

- Normal functions: `hits[1]` is the entry-point hit count (PC 0
  produces savedpc 1).
- Vararg functions: `hits[1]` is nil (OP_VARARGPREP skips the hook),
  so fall back to `hits[2]` (the first instruction after
  OP_VARARGPREP, executed once per call).

### DA: zero out definition lines of uncalled functions

```lua
local uncalled_def_lines = {}
for _, fn in ipairs(func_defs) do
   if not fn_call_counts[fn.line] then
      uncalled_def_lines[fn.line] = true
   end
end

-- In the DA loop:
if uncalled_def_lines[line_nr] then hits = 0 end
```

## Why only Lua 5.4+ is affected by the vararg issue

`OP_VARARGPREP` was introduced in Lua 5.4. Earlier versions (5.1,
5.2, 5.3) handle vararg setup differently and do not have this
opcode. LuaJIT uses `hook.c` (line-level hooks) rather than
`pchook.c` (PC-level hooks), so this code path is not exercised.

The FNDA inflation bug (defect 1) affects all Lua versions where
pchook is active (5.4+), since `OP_CLOSURE` always executes at the
definition line regardless of Lua version.

## Verification

After the fix:

- **101 unit tests pass** (busted), including 4 new function-coverage
  tests: FNDA:0 for uncalled, FNH correctness, multi-call counting,
  and vararg function FNDA.
- **e2e_branch_coverage.lua** passes all assertions. `count_args(...)`
  now correctly reports `FNDA:2` (previously `FNDA:0`).
  `max_of_three` and `Point:length` correctly report `FNDA:0` and
  `DA:<line>,0` on their definition lines.
- **e2e_function_coverage.lua** (new) validates 6 functions (4 called
  including 1 vararg, 2 uncalled) through both in-memory proto hits
  and round-trip LCOV parsing.

## Lessons

- Line-level hit counts are unreliable proxies for function-call
  counts in Lua. The only correct source is per-Proto instruction
  hits from the hook callback.
- Lua 5.4's `OP_VARARGPREP` is a silent edge case that breaks naive
  "first instruction = call count" assumptions. Any code using
  `hits[1]` as a call-count proxy must fall back to `hits[2]` for
  vararg functions.
- Function definition lines in LCOV should be treated as a special
  case: their line-level hits reflect closure creation in the parent
  chunk, not function entry. When the function was never called, the
  definition line hit should be suppressed to avoid misleading HTML
  reports.
