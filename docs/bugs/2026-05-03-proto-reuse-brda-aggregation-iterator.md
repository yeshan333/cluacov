# Proto address reuse, BRDA multi-load aggregation, and iterator branch zero-hits

- **Affected components**: `cluacov.pchook` (`src/cluacov/pchook.c`),
  `cluacov.runner` (`src/cluacov/runner.lua`),
  `cluacov.deepbranches` (`src/cluacov/deepbranches.c`)
- **Affected versions**: all versions prior to commits `c122a73`, `336661e`, `036a784`
- **Severity**: medium–high (silent data correctness, no crash)
- **Discovered**: 2026-05-03
- **Fix commits**: `c122a73` (defect 1), `336661e` (defect 2), `036a784` (defect 3)

## Symptom

Three independent defects affect coverage accuracy in multi-load
(busted) scenarios and for-in loop branch coverage.

### 1. Proto address reuse after GC causes wrong DA/FNDA attribution

In busted test suites that clear `package.loaded` between spec files,
the same source file is loaded multiple times.  After GC collects an
old Proto, Lua may reuse the freed address for a newly allocated
Proto.  The LCOV report then shows **called functions with DA:0 for
all body lines**:

```
FNDA:5,is_empty     <-- function was called 5 times
DA:85,0              <-- but all body lines show 0 hits (WRONG)
DA:86,0
DA:87,0
DA:88,0
```

The for-loop `end` line of a called function also shows as uncovered
(red) in the HTML report, which was the original downstream report
that triggered the investigation.

**Confirmation**: disabling GC with `collectgarbage("stop")` before
the multi-load test produces correct results on Lua 5.5.

### 2. BRDA counts silently truncated in multi-load scenarios

Even with defect 1 fixed, branch coverage (BRDA) values are much
lower than expected.  For example, `deep_clone` called 1145 times
shows `BRDA:137,9,1,186` instead of the correct 1145:

```
FNDA:1145,deep_clone
DA:137,1145              <-- line coverage correctly aggregated
BRDA:137,9,1,186         <-- branch coverage only from last load (WRONG)
```

The downstream project showed 50.3% branch coverage when the correct
figure (after fix) is 55.5%.

### 3. For-in iterator branches always report BRDA [-|-]

All for-in loop iterator branches show both directions as never
taken, even when the loop clearly executed:

```
DA:34,3                  <-- for-loop line hit 3 times
BRDA:34,0,0,-            <-- but both branch directions show zero (WRONG)
BRDA:34,0,1,-
```

The downstream project showed 55.5% branch coverage when the correct
figure (after fix) is 63.3%.

## Root cause

### Defect 1: PROTO_INDEX_KEY stale mapping

`PROTO_INDEX_KEY` maps `Proto*` lightuserdata to entry IDs in the
pchook data table.  Lightuserdata keys have no GC interaction — they
are not weak, have no finalizers, and cannot be automatically cleaned
up when the Proto they point to is freed.

When GC frees an old Proto and Lua allocates a new Proto at the same
address, the stale mapping routes the new Proto's hook hits into the
old entry, which belongs to a different function (different source,
different line table).  This silently corrupts both the old and new
function's coverage data.

Lua 5.5's GC behavior triggers address reuse more frequently than
5.4, which is why the defect was first observed on 5.5.

### Defect 2: `hits_by_ld` overwrites instead of aggregating

In `runner.lua`'s `write_lcov`, the `hits_by_ld` lookup is built by
iterating proto entries:

```lua
hits_by_ld[entry.linedefined .. ":" .. entry.sizecode] = entry.hits
```

When multiple proto entries share the same `linedefined:sizecode` key
(from multiple loads of the same file), **the last entry silently
overwrites all previous ones**.  BRDA counts then reflect only one
load's data instead of the aggregate.

This contrasts with DA (via `aggregate_all_line_hits`) and FNDA (via
`fn_call_counts`), which both correctly aggregate across proto
entries using per-proto MAX then cross-proto SUM.

### Defect 3: TFORLOOP bypasses vmfetch, never triggers count hook

In Lua 5.2+, the for-in loop compiles to two adjacent instructions:

```
TFORCALL  ra, nresults    -- call the iterator function
TFORLOOP  ra, offset      -- test result, branch if not nil
```

In the VM dispatch (`luaV_execute`), TFORCALL's handler ends with:

```c
i = *(pc++);                   /* read TFORLOOP instruction */
lua_assert(GET_OPCODE(i) == OP_TFORLOOP);
goto l_tforloop;               /* jump directly, bypass vmfetch */
```

Because `vmfetch()` is skipped, `luaG_traceexec()` is never called
for TFORLOOP, and the count hook never fires at TFORLOOP's PC.
`deepbranches.c` reported TFORLOOP's PC as the branch source, so the
runner's `proto_hits[b.pc]` lookup always found zero, causing all
for-in iterator BRDA entries to be suppressed as "unreached".

The same `goto` pattern applies to the initial loop entry: TFORPREP
directly jumps to `l_tforcall` in Lua 5.4+, so the first TFORCALL
execution also bypasses vmfetch.

## Fix

### Defect 1 fix (`pchook.c`)

Added stale-mapping validation in `push_hits_for_proto`.  When an
existing mapping is found (`entry_id != 0`), fetch the entry and
compare its stored `linedefined` and `sizecode` with the current
Proto's values.  If they differ, the address was recycled: discard
the stale mapping and create a fresh entry.

The valid-mapping fast path reuses the already-fetched entry table to
avoid a redundant `lua_rawgeti` call.

### Defect 2 fix (`runner.lua`)

Changed `hits_by_ld` construction to aggregate (SUM) PC-level hits
across all proto entries with the same `linedefined:sizecode` key,
instead of overwriting:

```lua
local existing = hits_by_ld[key]
if existing then
   for pc, count in pairs(entry.hits) do
      existing[pc] = (existing[pc] or 0) + count
   end
else
   local copy = {}
   for pc, count in pairs(entry.hits) do
      copy[pc] = count
   end
   hits_by_ld[key] = copy
end
```

### Defect 3 fix (`deepbranches.c`)

For OP_TFORLOOP branches, use TFORCALL's bytecode offset (`pc - 1`)
as the branch source instead of TFORLOOP's offset.  TFORCALL always
goes through vmfetch (except the first call via TFORPREP goto) and
therefore has valid hit data in pchook.

The fix applies to both `#if LUA_VERSION_NUM >= 504` (Lua 5.4/5.5)
and the `#else` path (Lua 5.2/5.3).  Lua 5.1's TFORLOOP handles
both calling and testing in a single instruction, so no change is
needed there.

## Testing

- **Unit tests**: 111/0 on Lua 5.4, 96/15 on Lua 5.5 (15 are
  pre-existing runner_spec failures from lua binary path mismatch)
- **E2E tests**: pass on both 5.4 and 5.5
- **Regression tests added**:
  - `pchook_spec`: "handles Proto address reuse after GC without
    stale mapping" — multi-load with forced GC between loads
  - `runner_spec`: "aggregates BRDA counts across multiple proto
    entries for the same file" — three loads of same source, verifies
    BRDA aggregate >= 3
- **Downstream verification** (luatricks, 1760 tests):
  - Branch coverage: 50.3% → 63.3% (+13pp)
  - All for-in iterator branches now correctly reported
  - `Table.size` for-loop `end` line no longer shows as uncovered
