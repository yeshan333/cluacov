# cluacov Hook Performance Benchmark

This document presents a quantitative comparison of four coverage-hook configurations:

| Configuration | Hook type | Per-event cost |
|---|---|---|
| **baseline** | no hook | — |
| **luacov-hook** | `debug.sethook(lua_fn, "l")` — pure-Lua `LUA_MASKLINE` | high (Lua dispatch + `debug.getinfo`) |
| **cluacov-hook** | `debug.sethook(c_fn, "l")` — C `LUA_MASKLINE` | lower (C, still calls `lua_getstack`) |
| **pchook** | C `LUA_MASKCOUNT` (count = 1) — fires every instruction | lowest (direct `CallInfo.savedpc` read) |

## Environment

| Item | Value |
|---|---|
| Lua version | Lua 5.5.0 |
| CPU | Intel Xeon Platinum 8269CY @ 2.50 GHz |
| Cores | 104 logical |
| Memory | 16 GiB |
| OS | Linux 5.10 |
| Timing | `os.clock()` (process CPU time) |

## Methodology

The benchmark script is at [`bench/benchmark.lua`](../bench/benchmark.lua).

### Workloads

Three synthetic workloads exercise different hook-event densities:

| Workload | Description | Hook events per batch (approx.) |
|---|---|---|
| **fib(24)** | Recursive Fibonacci — many function-call line events | ~185 000 line / ~1.3 M instruction |
| **loop×1 000** | Tight numeric for-loop — few source lines, many iterations | ~3 000 line / ~10 000 instruction |
| **call-chain/100** | Depth-100 recursion — moderate function-activation rate | ~200 line / ~700 instruction |

### Per-cell measurement protocol

Each `(workload, mode)` cell runs the following sequence to eliminate warmup
artefacts and remove `os.clock()` calls from the hot path:

1. **Warmup** — one unmetered batch invocation to prime internal tables and
   (for pchook) materialise `Proto` metadata.
2. **Probe** — one timed batch invocation to estimate per-batch CPU cost.
3. **Timed run** — `n = max(1, floor(1.5 s / probe_secs))` batches executed in
   a clean `for`-loop with no `os.clock()` call inside. This bounds
   the hook-event contamination from loop control code to `n+1` events
   vs `n × events_per_batch` workload events (< 0.1 % noise for all cells).
4. Steps 1–3 are repeated **3 independent times** (reps); mode order is
   **randomised** within each rep pass to spread thermal bias across cells.
   If the probe time exceeds **4 s**, only one rep is taken and the cell is
   flagged with `*`.

Reported metric: `ops / s = (n × batch_ops) / elapsed_cpu_seconds`.  
Slowdown factor: `baseline_ops_per_s / hook_ops_per_s` (higher = worse).  
Summary row: geometric mean of slowdown factors across the three workloads.

## Results

### Raw throughput and slowdown

```
Workload              baseline (ops/s)   luacov-hook           cluacov-hook          pchook
─────────────────────────────────────────────────────────────────────────────────────────────
fib(24)               2.846e+02          1.622e+00 (175.5x)*   1.278e+01  (22.3x)    1.181e+01  (24.1x)
loop×1 000           2.661e+07          9.273e+04 (287.0x)     8.029e+05  (33.1x)    1.567e+06  (17.0x)
call-chain/100        4.128e+05          1.817e+03 (227.2x)     1.506e+04  (27.4x)    1.609e+04  (25.7x)
─────────────────────────────────────────────────────────────────────────────────────────────
geometric mean                                     225.3x                   27.2x               21.9x
```

`*` = slow cell; probe exceeded 4 s threshold; single rep only.

### Run-to-run variance

All fast cells (3 reps each) show low noise, confirming stable measurements:

```
Workload              baseline              luacov-hook           cluacov-hook          pchook
──────────────────────────────────────────────────────────────────────────────────────────────────────
fib(24)               2.83e+02..2.87e+02   (1 rep, 6 s probe)   1.27e+01..1.28e+01   1.18e+01..1.18e+01
                      (±1%)                                       (±0%)                (±0%)
loop×1 000           2.660e+07..2.663e+07  9.20e+04..9.33e+04   8.02e+05..8.05e+05   1.56e+06..1.58e+06
                      (±0%)                (±1%)                 (±0%)                (±1%)
call-chain/100        4.12e+05..4.14e+05   1.81e+03..1.82e+03   1.50e+04..1.52e+04   1.56e+04..1.63e+04
                      (±0%)                (±0%)                 (±1%)                (±2%)
```

### cluacov C hook vs pchook — head-to-head

```
Workload              cluacov-hook    pchook      winner
────────────────────────────────────────────────────────
fib(24)               22.3x           24.1x       cluacov-hook  (1.08×)
loop×1 000           33.1x           17.0x       pchook        (1.95×)
call-chain/100        27.4x           25.7x       pchook        (1.07×)
────────────────────────────────────────────────────────
geometric mean                                    pchook        (1.24×)
```

## Analysis

### Why luacov pure-Lua hook is so expensive

Every line event requires the Lua VM to call a **Lua closure** that internally
invokes `debug.getinfo(level, "S")`.  This involves:

- Entering the debug library (C → Lua boundary)
- Walking the call stack to the requested level
- Allocating and populating an `lua_Debug` struct
- Returning to Lua, performing table lookups and string pattern matching

Measured cost: roughly **3–5 µs per line event**.  On fib(24), which generates
~185 000 line events per 10-call batch, this dominates completely (175–287×
overhead range).

### Why the cluacov C hook is faster

`hook.c` replaces the Lua closure with a direct C callback, eliminating the
Lua-dispatch overhead.  It still calls `lua_getstack` + `lua_getinfo` to
resolve the current source filename, but does so without Lua bytecode
interpretation.  Measured cost: **~400 ns per line event** — roughly 8× cheaper
than the pure-Lua hook.

### Why pchook is faster still, despite firing more often

`pchook.c` uses `LUA_MASKCOUNT` (count = 1), firing on **every bytecode
instruction** — 3–7× more events than the line hook for the same code.  Yet it
is **faster** overall (geometric mean 21.9× vs 27.2× for the C line hook)
because each invocation is far cheaper:

- No `lua_getstack` / `lua_getinfo` call.
- PC is read directly from `CallInfo.u.l.savedpc - proto->code` — a single
  pointer subtraction.
- File/function metadata is looked up by integer `entry_id` from a pre-built
  Lua table (materialised on the first encounter of each `Proto*`).

Estimated cost: **~100–130 ns per instruction event** — roughly 3–4× cheaper
per call than the C line hook.

### Workload-dependent crossover

The balance between "fires more often" and "cheaper per call" creates a
workload-dependent result:

| Workload | Instruction / line ratio | Head-to-head |
|---|---|---|
| fib(24) — many recursive calls | ~7 instructions / line | cluacov-hook wins (1.08×) |
| loop×1 000 — tight arithmetic | ~3 instructions / line | pchook wins (1.95×) |
| call-chain/100 — moderate calls | ~3.5 instructions / line | pchook wins (1.07×) |

When the instruction-to-line ratio is high (recursive code), the extra event
volume of pchook can outweigh its per-call advantage.  For loops and typical
application code the ratio is lower, and pchook wins.

The geometric mean across all three workloads is **pchook 1.24× faster** than
the cluacov C line hook.

## Implications for documentation

The `README.md` comparison table previously read:

```
| Performance | Moderate | Slower (fires every instruction) |
```

This was incorrect.  The benchmark shows:

- **cluacov C hook**: 27.2× geometric mean slowdown.
- **pchook**: 21.9× geometric mean slowdown — **faster**, not slower.

The `getting-started.md` troubleshooting section previously read:

> Per-instruction hooks fire on every VM instruction, which is significantly
> slower than line-level hooks.

This was also incorrect when "line-level hook" refers to the cluacov C hook.
pchook is faster in two of three workloads and faster overall.  The statement
is only true when comparing against the pure-Lua luacov hook (225× overhead),
but that hook is not what users get when cluacov is installed.

Both claims have been corrected in the documentation.

## Caveats

- **Microbenchmark**: all three workloads are synthetic.  Real application code
  will have a different instruction-to-line ratio and a larger number of source
  files.  Multi-file workloads add one-time `file_included` lookup overhead per
  new file (cached thereafter), which affects both line hooks equally and does
  not affect pchook.
- **Single rep for luacov-hook × fib**: the probe took 6.14 s, exceeding the
  4 s threshold.  The single measurement is stable (fib is deterministic) but
  no variance estimate is available for this cell.
- **No I/O overhead**: the mock runner does not call `save_stats()`.  Periodic
  disk writes (tick mode) are not included in these measurements.
- **Lua 5.5 only**: pchook reads internal `CallInfo` and `Proto` fields via
  vendored headers and is only available on PUC-Rio Lua 5.4+.  The cluacov C
  hook and luacov pure-Lua hook are available on all supported versions
  (5.1–5.5, LuaJIT).
