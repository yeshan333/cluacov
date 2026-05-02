# Function-body first line shows hits = 0 (savedpc off-by-one in line aggregation)

- **Affected component**: `cluacov.pchook` — specifically `collect_line_hits_recursive` in `src/cluacov/pchook.c`
- **Affected versions**: any commit at or after `fc9499f` ("fix: correct off-by-one PC index in collect_line_hits_recursive") and before this fix
- **Severity**: medium (silent data correctness, no crash)
- **Discovered**: 2026-05-02
- **Reporter**: yeshan333 (downstream user, project: gserver/luatricks)

## Symptom

For any function whose body's first executable statement is a simple
expression (e.g. `local t = obj.field`), the LCOV report consistently
shows that line as **uncovered (`DA:<line>,0`)**, even though the
function is called many times. The same pattern reappears at the first
executable line inside any `if`-block whose body starts with a
`local x = expr` style assignment, and at the closing `end` of `for`
loops.

A real-world report fragment from a downstream project (with
`M.dump_path` defined at lines 364-370 of `uobj.lua`):

```
DA:364,1     # function M.dump_path(cobj)
DA:365,0     # local t = cobj._type      ← actually executed on every call
DA:366,1     # if t ~= "struct" and ...
DA:367,0     # error("...")              ← genuinely not entered
DA:369,1     # return uobj_core.dump_path(cobj)
DA:370,1     # end
```

A second downstream pattern (from `Path.join_path`):

```
local cleaned_v = v               -- shown 0 hits, was actually executed 8x
...
end                               -- for-loop end, shown 0 hits, was actually executed 3x
```

## Reproduction

Captured under `regression: function-body first line shows hits=0
(savedpc off-by-one)` in `spec/pchook_spec.lua`. Minimal standalone
reproduction:

```lua
local pchook = require("cluacov.pchook")

local fn = assert(load([[
   return function(cobj)
      local t = cobj._type           -- function body, first statement
      if t == "struct" then
         return "ok"
      end
      return "no"
   end
]]))()

pchook.start()
for _ = 1, 3 do fn({_type = "struct"}) end
pchook.stop()

local lines = pchook.get_line_hits(fn)
-- BEFORE FIX: the line of `local t = cobj._type` shows hits = 0
-- AFTER  FIX: it shows hits = 3
for i = 1, lines.max do
   if lines[i] then print(("L%d: HIT(%d)"):format(i, lines[i])) end
end
```

## Root cause

The `pchook` hits table uses `(int)(ci->u.l.savedpc - proto->code)`
as its key. By Lua's interpreter convention, this value is the PC of
the **next** instruction to execute, not the one that just ran. From
Lua 5.5's source:

```c
/* ldebug.c, luaG_traceexec */
pc++;                          /* reference is always next instruction */
ci->u.l.savedpc = pc;          /* save 'pc' */
...
if (counthook)
   luaD_hook(L, LUA_HOOKCOUNT, -1, 0, 0);   /* the count hook fires here */
```

```c
/* ldo.c, luaD_hookcall */
ci->u.l.savedpc++;             /* hooks assume 'pc' is already incremented */
luaD_hook(L, event, -1, 1, p->numparams);
ci->u.l.savedpc--;             /* correct 'pc' */
```

That is, **every hook callback observes `savedpc` already pointing at
the next instruction**. To recover the PC of the instruction that
actually ran, the canonical pattern (used by Lua itself) is
`pcRel(savedpc, proto)`:

```c
/* src/ldebug.h */
#define pcRel(pc, p)  (cast_int((pc) - (p)->code) - 1)
```

This convention is intentionally preserved at the storage layer in
`cluacov` so that `branchcov.lua` can keep using
`proto_hits[target.pc]` directly (where `target.pc` is a jump-target
PC, also expressed as a "next-to-execute" PC). The contract is:

| Layer                     | What `hits[pc]` means                       |
|---------------------------|---------------------------------------------|
| Storage (`pc_hook`)       | "savedpc was here when count hook fired"    |
| Branch reader (`branchcov`)| Same — directly compatible with `target.pc`|
| **Line reader** (`collect_line_hits_recursive`) | **Must shift by -1 to get the executed instruction's source line** |

The pre-`fc9499f` code did exactly that:

```c
int pc1based = (int)lua_tointeger(L, -2);
line = get_pc_line(proto, pc1based - 1);
```

Commit `fc9499f` ("fix: correct off-by-one PC index in
collect_line_hits_recursive") misread the `- 1` as a stale 1-based →
0-based conversion and removed it:

```c
int pc = (int)lua_tointeger(L, -2);
line = get_pc_line(proto, pc);    // wrong: now reads the NEXT instruction's line
```

That introduced the regression seen in the symptom. Every line-hit
count was being attributed to the source line of the **next**
instruction:

1. The first executable line of a function body (PC 0) lost its hit
   entirely (because PC 0 itself never appears in the hits table — no
   prior instruction can produce a `savedpc == 0` inside this Proto).
2. The line of every other executable instruction was credited to the
   line of the instruction that came after it, doubling some lines and
   zeroing others.

## Fix

Restore the `-1` shift in `collect_line_hits_recursive`, with an
explicit `pc <= 0` guard for the first-instruction case:

```c
if (pc <= 0) continue;
line = get_pc_line(proto, pc - 1);
if (line <= 0) continue;
```

A long block comment was added explaining why this is the correct
contract and why it is **not** symmetrical with what `branchcov.lua`
needs, so future maintainers do not "fix" it again.

The storage layer (`pc_hook`) and `branchcov.lua` are intentionally
left untouched: their direct-PC contract is correct as-is, and any
shift there would break per-PC branch coverage immediately.

## Why both Lua 5.4 and 5.5 are affected

The `pc++` step in `luaG_traceexec` is unchanged between Lua 5.4 and
5.5. The bug reproduces identically on both. The reproduction was
first observed on Lua 5.5 because that is what the downstream user
ran, but it is not specific to 5.5.

## Verification

After the fix, on both Lua 5.4.8 and Lua 5.5.0:

- `spec/pchook_spec.lua` — 30 assertions pass on Lua 5.4, 32 on
  Lua 5.5 (including the two new regression cases under
  `regression: function-body first line shows hits=0`).
- `e2e/e2e_branch_coverage.lua` — branchcov still reports
  `25 sites, 8 covered, 13 partial, 4 uncovered, 29/50 (58.0%)` and
  every E2E assertion passes. This proves the fix does not regress
  per-PC branch coverage.
- The original downstream symptom (line-365 of `uobj.lua` showing
  `DA:365,0` despite the function being called) is gone.

## Lessons

- A `- 1` next to a PC value is almost never a base conversion. It is
  almost always an interpreter-convention adjustment ("savedpc points
  to next instruction"). The `pcRel` macro in Lua's own
  `src/ldebug.h` is the canonical reference. Any future
  "fix-the-off-by-one" change in this code path must be evaluated
  against both:
  1. `spec/pchook_spec.lua` (line-coverage correctness), and
  2. `e2e/e2e_branch_coverage.lua` (per-PC branch correctness).
- The storage layer's "next-instruction PC" key is **the
  load-bearing convention** of cluacov; shifting it at the storage
  layer breaks `branchcov` immediately. All shifts must happen at
  the line-aggregation reader.
