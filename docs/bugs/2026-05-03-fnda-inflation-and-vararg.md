# Function coverage inflated by OP_CLOSURE, broken for vararg functions, and aggregate off-by-one

- **Affected component**: `cluacov.runner` (`src/cluacov/runner.lua`),
  `cluacov.pchook` (`src/cluacov/pchook.c`)
- **Affected versions**: all versions prior to commit `d511be7` (defects 1-3),
  all versions prior to the aggregate off-by-one fix (defect 4)
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

### 4. `aggregate_all_line_hits` off-by-one: DA values attributed to wrong line

The `get_all_line_hits()` C function (used by `runner.lua` to produce
DA records in LCOV) maps hits to the **wrong source line** for any
instruction whose successor is on a different line. Typically this
causes:

- Hits shifting from line N to line N+1 (or a nearby line)
- Definition lines of uncalled functions appearing as covered (or 0)
  depending on bytecode layout
- In Lua 5.5, CLOSURE is at `end` and SETFIELD at `function`, so the
  CLOSURE hit leaks to the SETFIELD line instead of the `end` line

In the downstream project (`luatricks`), this produced anomalies like
`DA:38,844390` on an uncalled function's closing `end` line, and
`DA:123,834089` on a function definition line.

### 5. Uncalled function `end` line shows hits in Lua 5.5

After fixing defects 3 and 4, the `end` line (`lastlinedefined`) of
uncalled multi-line functions still showed DA > 0 in Lua 5.5. In the
HTML report this meant the closing `end` of an entirely-uncovered
function body was highlighted blue (covered).

In Lua 5.4 `OP_CLOSURE` is at `linedefined` (the `function` keyword
line), which defect 3's fix already zeroed. In Lua 5.5 the compiler
moved `OP_CLOSURE` to `lastlinedefined` (the `end` line), so that
line accumulated a hit from the parent chunk's module loading pass.
The defect-3 fix only suppressed `linedefined`, not `lastlinedefined`.

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

### Defect 4: `aggregate_all_line_hits` savedpc off-by-one

`collect_line_hits_recursive` (used by `get_line_hits`) correctly
applies `get_pc_line(proto, pc - 1)` when mapping a hits-table key
to a source line, because the key is a savedpc offset (next
instruction's PC). However, `aggregate_all_line_hits` (used by
`get_all_line_hits` and therefore by `runner.lua`'s DA output) looked
up `entry.lines[pc]` directly — the line of instruction AT `pc`,
not instruction `pc - 1` that actually executed.

```c
// BEFORE (wrong): attributes hits to the NEXT instruction's line
lua_rawgeti(L, lines_idx, pc);

// AFTER (correct): attributes hits to the EXECUTED instruction's line
if (pc <= 0) continue;
lua_rawgeti(L, lines_idx, pc - 1);
```

The bug was invisible in most cases because adjacent bytecode
instructions tend to share the same source line. It only manifested
when consecutive instructions mapped to **different** lines:

- CLOSURE/SETFIELD pairs in module top-level chunks (Lua 5.5 puts
  CLOSURE at `end` and SETFIELD at `function`)
- The last instruction of a for-loop body followed by the TFORCALL
  on the `for` line
- Function-return sequences where CLOSE and RETURN are on different
  lines

### Defect 5: `lastlinedefined` not suppressed for uncalled functions

The defect-3 fix only added `linedefined` (the `function` keyword
line) to `uncalled_def_lines`. In Lua 5.5, `OP_CLOSURE` moved to
`lastlinedefined`, so the parent chunk's module-load pass gives
`DA:end_line,N` with N > 0. Runner.lua had no knowledge of
`lastlinedefined` because pchook did not expose it, and the
`uncalled_def_lines` set only contained `linedefined`.

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

### DA: fix savedpc off-by-one in `aggregate_all_line_hits`

In `pchook.c`, the `aggregate_all_line_hits` inner loop now mirrors
the `pc - 1` shift already used by `collect_line_hits_recursive`:

```c
/* Walk entry.hits – key is savedpc offset (next instruction PC).
 * Look up lines[pc - 1] to attribute the hit to the EXECUTED
 * instruction's source line, not the next instruction's line.  */
if (pc <= 0) continue;
lua_rawgeti(L, lines_idx, pc - 1);
```

The `pc <= 0` guard skips any degenerate key that has no preceding
instruction inside the Proto.

### DA: suppress `lastlinedefined` for uncalled functions

Three changes:

1. `pchook.c:materialize_proto_entry` now also stores
   `proto->lastlinedefined` in each materialized entry table.
2. A new `pchook.get_func_defs(func)` C function traverses the full
   Proto tree of a loaded file (including protos never entered by the
   hook) and returns `{ linedefined, lastlinedefined }` for each.
3. `runner.lua:write_lcov` calls `get_func_defs(func)` and adds
   `lastlinedefined` to `uncalled_def_lines` for every text-matched
   uncalled function whose `linedefined` matches a Proto.

```lua
for _, def in ipairs(pchook.get_func_defs(func)) do
   if uncalled_ld_set[def.linedefined] then
      local lld = def.lastlinedefined
      if lld and lld > 0 and lld ~= def.linedefined then
         uncalled_def_lines[lld] = true
      end
   end
end
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

- **107 unit tests pass** (busted), including 4 function-coverage
  tests, 2 aggregate off-by-one regression tests, 3 `get_func_defs`
  tests, and 1 uncalled-function `end`-line zeroing test.
- **e2e_branch_coverage.lua** passes all assertions. `count_args(...)`
  now correctly reports `FNDA:2` (previously `FNDA:0`).
  `max_of_three` and `Point:length` correctly report `FNDA:0` and
  `DA:<line>,0` on their definition lines.
- **e2e_function_coverage.lua** (new) validates 6 functions (4 called
  including 1 vararg, 2 uncalled) through both in-memory proto hits
  and round-trip LCOV parsing.
- **Downstream verification** (Lua 5.5, `luatricks`): `DA:38` now
  correctly shows 1 (was 844390 before fix); previously missing DA
  lines for loop CLOSE instructions now appear correctly.
- **Lua 5.5 `end`-line verification**: uncalled function's `end` line
  now correctly shows `DA:9,0` (was `DA:9,1` before fix). Both
  `linedefined` and `lastlinedefined` are suppressed for uncalled
  functions.

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
- When multiple C functions derive source-line information from the
  same hits table, they **must** apply the same savedpc convention
  (`pc - 1`). The off-by-one in `aggregate_all_line_hits` was latent
  because adjacent instructions usually share a line; it only
  surfaced with cross-line instruction pairs (CLOSURE/SETFIELD,
  loop boundaries, return sequences). Any future API that reads the
  hits table must include this shift.
- Lua VM versions may change **which source line** an instruction is
  attributed to (e.g. Lua 5.5 moved `OP_CLOSURE` from `linedefined`
  to `lastlinedefined`). Coverage suppression logic must handle both
  ends of a function's line range. The new `get_func_defs` API
  exposes the full Proto tree including protos never seen by the hook,
  making this cross-version suppression possible.
