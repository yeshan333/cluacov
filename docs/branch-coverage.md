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

Lua's debug hook fires at **line** level, not instruction level. When a single
source line contains multiple branch instructions (e.g. `if a or b or c`
compiles to 3 TEST instructions), they all share the same line-hit count.
Per-instruction branch coverage is impossible under Lua's runtime model.

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

> **Why not instruction-level coverage?** C/gcov inserts arc counters at
> compile time, tracking every branch instruction individually. Lua only
> provides a line-level debug hook, so same-line instructions are
> indistinguishable at runtime.

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

| Platform | Branch analysis | Notes |
|----------|----------------|-------|
| PUC-Rio Lua 5.1 | Yes | `OP_TFORLOOP` followed by `OP_JMP` |
| PUC-Rio Lua 5.2 | Yes | `OP_TFORLOOP` uses `sBx` |
| PUC-Rio Lua 5.3 | Yes | Same as 5.2 |
| PUC-Rio Lua 5.4 | Yes | `OP_FORPREP` conditional, `sJ` format jumps |
| PUC-Rio Lua 5.5 | Yes | Same as 5.4 |
| LuaJIT | No | Returns empty table (bytecode format differs) |
