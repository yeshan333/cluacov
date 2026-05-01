# Branch Coverage with `cluacov.deepbranches`

## Overview

`cluacov.deepbranches` statically analyzes Lua function bytecode to discover
**branch sites** — points where execution can take one of two paths. By
cross-referencing these sites with [LuaCov](https://github.com/lunarmodules/luacov)
line-hit data, you can compute branch coverage and generate LCOV reports with
branch records (`BRDA`).

## Supported Branch Types

| Kind | Source construct | Description |
|------|-----------------|-------------|
| `test` | `if`, `elseif`, `and`, `or`, comparisons | Conditional test followed by a jump |
| `loop` | `for i = a, b` (loop back edge) | Numeric for loop continuation check |
| `loop-entry` | `for i = a, b` (entry, Lua >= 5.4) | Numeric for loop initial entry check |
| `iterator` | `for k, v in f()` | Generic for iterator exhaustion check |

Each branch site has exactly **two targets**: the two possible execution paths.

> **Note:** targets are sorted by program counter (ascending), not by semantic
> direction. `targets[1]` is the lower-PC target, not necessarily the
> "true-path". This is stable and sufficient for coverage computation.

## API

```lua
local deepbranches = require("cluacov.deepbranches")

-- deepbranches.version : string (e.g. "1.0.0")
-- deepbranches.get(func) -> table of branch sites

local branches = deepbranches.get(some_function)
```

`get` accepts a **Lua function** (not a C function) and returns an array of
branch site tables. It recursively includes branches from nested functions.

### Branch site fields

| Field | Type | Description |
|-------|------|-------------|
| `line` | number | Source line of the branch instruction |
| `pc` | number | 1-based program counter of the branch instruction |
| `kind` | string | Branch type: `"test"`, `"loop"`, `"loop-entry"`, or `"iterator"` |
| `linedefined` | number | First line of the enclosing function |
| `targets` | table | Array of exactly 2 target tables |

### Target fields

| Field | Type | Description |
|-------|------|-------------|
| `line` | number | Source line of the target instruction |
| `pc` | number | 1-based program counter of the target instruction |

### Example

```lua
local deepbranches = require("cluacov.deepbranches")

local function example(x)
   if x > 0 then
      return "positive"
   else
      return "non-positive"
   end
end

local branches = deepbranches.get(example)
--[[
branches = {
   {
      line = 2,            -- "if x > 0"
      pc = 2,
      kind = "test",
      linedefined = 1,
      targets = {
         { line = 3, pc = 4 },   -- true  path: "return positive"
         { line = 5, pc = 6 },   -- false path: "return non-positive"
      }
   }
}
]]
```

## How Branch Coverage Works

Branch coverage measures whether **both paths** of each branch site were
exercised during testing.

The approach is:

1. **Discover** branch sites with `deepbranches.get(func)`
2. **Run** the code under LuaCov to collect per-line hit counts
3. **Filter** branches (see Compound Conditions below)
4. **Cross-reference**: for each reportable branch, check if its target lines
   were hit

### Compound Conditions

Lua's **line-level** debug hook fires once per source line. When a single
source line contains multiple branch instructions (e.g. `if a or b or c`
compiles to 3 TEST instructions), they all share the same line-hit count —
per-instruction distinction is impossible with line-level hooks alone.

**Filtering rule**: for lines with multiple branches, only report branches
whose **both targets are on different lines** from the branch line. These are
the only branches whose two outcomes are genuinely distinguishable via line
hits. Branches with a same-line target (intermediate short-circuit jumps) are
skipped. When multiple branches on the same line share the same target-line
pair, only one is reported (deduplication).

This naturally handles:

- **`if a and b`** — the last TEST has targets on the then-body and else-body
  lines (both off-line), so it is reported. The first TEST has a same-line
  target (falls through to the next TEST), so it is skipped.
- **`for i = 1, n`** — FORPREP and FORLOOP are two branch instructions on the
  same line, but both have off-line targets (loop body and after-loop). Since
  they share the same target-line pair, only one is reported.
- **`if a or b or c`** — same pattern: only the last TEST (with both targets
  off-line) is reported.

> **Why not instruction-level coverage with this approach?** C/gcov inserts
> arc counters at compile time, tracking every branch instruction individually.
> Lua's line-level debug hook makes same-line instructions indistinguishable.
> For true per-instruction coverage on Lua 5.4+, use
> [pchook](#per-pc-branch-coverage-cluacovpchook--cluacovbranchcov).

### Reading branch coverage in HTML reports

In `genhtml`-generated reports, each source line with branches shows annotations:

```
Line 4    [+ +]:  2 :    if x > 0 then      -- both paths taken
Line 14   [+ #]:  1 :    if x < 0 then      -- only one path taken
Line 66   [# #]:  0 :    if a >= b then     -- neither path taken
```

- `+` = this branch path was taken
- `#` = this branch path was **not** taken (not executed)

## Generating LCOV Reports

### LCOV branch record format

Each branch target produces a `BRDA` record:

```
BRDA:<line>,<block_id>,<branch_id>,<taken>
```

- `line` — source line of the branch instruction
- `block_id` — unique ID for the branch site
- `branch_id` — 0 or 1 (which of the two targets)
- `taken` — hit count, or `-` if never taken

Summary records:

```
BRF:<total_branch_targets>
BRH:<hit_branch_targets>
```

### Generating HTML from LCOV

```sh
genhtml coverage.lcov --output-directory html --branch-coverage
```

### E2E example

The `e2e/` directory contains a complete working example:

```sh
lua e2e/e2e_branch_coverage.lua
```

This script:
1. Runs `e2e/sample.lua` under LuaCov
2. Discovers branch sites with `deepbranches.get`
3. Filters compound condition branches
4. Cross-references with line-hit data
5. Writes LCOV to `e2e/output/coverage.lcov`
6. Generates HTML report to `e2e/output/html/`

## Platform Support

| Platform | Branch analysis | Per-PC hook | Notes |
|----------|----------------|-------------|-------|
| PUC-Rio Lua 5.1 | Yes | No | `OP_TFORLOOP` followed by `OP_JMP` |
| PUC-Rio Lua 5.2 | Yes | No | `OP_TFORLOOP` uses `sBx` |
| PUC-Rio Lua 5.3 | Yes | No | Same as 5.2 |
| PUC-Rio Lua 5.4 | Yes | Yes | `OP_FORPREP` conditional, `sJ` format jumps |
| PUC-Rio Lua 5.5 | Yes | Yes | Same as 5.4 |
| LuaJIT | No | No | Returns empty table (bytecode format differs) |

## Per-PC Branch Coverage (`cluacov.pchook` + `cluacov.branchcov`)

The line-hit-based approach above treats same-line branches as indistinguishable
(since Lua's debug hook fires per line, not per instruction). For **true
instruction-level branch coverage**, cluacov provides a C-level count hook that
records execution counts for every bytecode instruction (per-PC hit counting).

### Why per-PC?

Consider `if a or b or c then`. This compiles to 3 separate `TEST` instructions.
With line-hit data, all 3 share the same hit count — you can't tell which
sub-conditions were evaluated. With per-PC counting, each `TEST` and its targets
get independent hit counts, giving 6 branch targets instead of 2.

### `cluacov.pchook` API

```lua
local pchook = require("cluacov.pchook")

pchook.start()                     -- register instruction-level C hook
-- ... run code under test ...
pchook.stop()                      -- remove hook

local hits = pchook.get_hits(func) -- per-proto PC hit tables
pchook.reset()                     -- clear all recorded data (collection continues)
```

`pchook.start()` calls `lua_sethook(L, hook, LUA_MASKCOUNT, 1)` to fire a
C-level callback on every VM instruction. The callback records the 1-based
program counter of each executed instruction, keyed by `Proto*` pointer.

`pchook.get_hits(func)` walks the function's Proto tree (including nested
functions) and returns an array of entries:

```lua
{
    { linedefined = 0, sizecode = 42, hits = { [1] = 5, [3] = 2, ... } },
    { linedefined = 8, sizecode = 10, hits = { [2] = 3, ... } },
    ...
}
```

Each entry's `hits` table maps 1-based PC to execution count.

> **Performance note:** instruction-level hooks fire on every VM instruction.
> Despite the higher event rate, per-call cost is lower than the cluacov C line
> hook (no `lua_getstack` call) — overall overhead is comparable and often lower
> (see [benchmark](../docs/benchmark.md)). Both modes add significant overhead
> vs a no-hook baseline; use `pchook` for coverage analysis, not production
> monitoring.

### `cluacov.branchcov` API

```lua
local branchcov = require("cluacov.branchcov")

local result = branchcov.analyze(func)
-- result.branches: array of branch info with per-target hit counts
-- result.total: total branch targets (branch_count * 2)
-- result.hit: number of targets with hits > 0
```

`analyze` combines `deepbranches.get(func)` with `pchook.get_hits(func)` to
compute per-instruction branch coverage. Each branch's targets have independent
`hits` counts from the PC-level data.

Unlike the line-hit approach, **no filtering is needed** — every branch
instruction is individually measurable.

### Shared target PCs

Multiple branch instructions may share a target PC (e.g., all `TEST`s in
`a or b or c` target the same body instruction). When the body is reached
from any path, that target PC shows as "hit" for **all** branches sharing it.
This is instruction-coverage (was this PC executed?), not edge-coverage
(which branch led here?).

### Requirements

- **Lua 5.4+** required (accesses `CallInfo.u.l.savedpc` via vendored headers)
- The function passed to `get_hits` must be the **same object** that was
  executed under `pchook.start()` (same `Proto*` pointer)
- Lua 5.1–5.3: `pchook.start()` raises an error; `get_hits()` returns empty
- LuaJIT: same as 5.1–5.3
