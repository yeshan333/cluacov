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
| Cores | 104 logical (52 physical, 2 sockets, HT on) |
| Memory | 16 GiB |
| OS | Linux 5.10 (x86_64) |
| Compiler | GCC 13.3.0 |
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
fib(24)               2.851e+02          1.590e+00 (179.3x)*   1.195e+01  (23.9x)    7.141e+00  (39.9x)
loop×1 000           2.671e+07          9.067e+04 (294.6x)    7.954e+05  (33.6x)    9.681e+05  (27.6x)
call-chain/100        4.131e+05          1.776e+03 (232.6x)    1.485e+04  (27.8x)    9.674e+03  (42.7x)
─────────────────────────────────────────────────────────────────────────────────────────────
geometric mean                                     230.7x                   28.1x               36.1x
```

`*` = slow cell; probe exceeded 4 s threshold; single rep only.

### Run-to-run variance

All fast cells (3 reps each) show low noise, confirming stable measurements:

```
Workload              baseline              luacov-hook           cluacov-hook          pchook
──────────────────────────────────────────────────────────────────────────────────────────────
fib(24)               2.80e+02..2.89e+02   (1 rep, 6.2 s probe) 1.18e+01..1.21e+01   7.12e+00..7.16e+00
                      (±2%)                                       (±1%)                (±0%)
loop×1 000           2.67e+07..2.68e+07   9.04e+04..9.12e+04   7.93e+05..7.97e+05   9.67e+05..9.69e+05
                      (±0%)                (±0%)                 (±0%)                (±0%)
call-chain/100        4.13e+05..4.14e+05   1.76e+03..1.79e+03   1.48e+04..1.49e+04   9.65e+03..9.70e+03
                      (±0%)                (±1%)                 (±0%)                (±0%)
```

### cluacov C hook vs pchook — head-to-head

```
Workload              cluacov-hook    pchook      winner
────────────────────────────────────────────────────────
fib(24)               23.9x           39.9x       cluacov-hook  (1.67x)
loop×1 000           33.6x           27.6x       pchook        (1.22x)
call-chain/100        27.8x           42.7x       cluacov-hook  (1.53x)
────────────────────────────────────────────────────────
geometric mean                                    cluacov-hook  (1.28x)
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
~185 000 line events per 10-call batch, this dominates completely (179–295×
overhead range).

### Why the cluacov C hook is faster

`hook.c` replaces the Lua closure with a direct C callback, eliminating the
Lua-dispatch overhead.  It still calls `lua_getstack` + `lua_getinfo` to
resolve the current source filename, but does so without Lua bytecode
interpretation.  Measured cost: **~400 ns per line event** — roughly 8× cheaper
than the pure-Lua hook.

### Why pchook fires more often but has lower per-event cost

`pchook.c` uses `LUA_MASKCOUNT` (count = 1), firing on **every bytecode
instruction** — 3–7× more events than the line hook for the same code.  Each
invocation is far cheaper:

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
| fib(24) — many recursive calls | ~7 instructions / line | cluacov-hook wins (1.67x) |
| loop×1 000 — tight arithmetic | ~3 instructions / line | pchook wins (1.22x) |
| call-chain/100 — moderate calls | ~3.5 instructions / line | cluacov-hook wins (1.53x) |

When the instruction-to-line ratio is high (recursive code), the extra event
volume of pchook outweighs its per-call advantage.  For tight loops with low
instruction-to-line ratios, pchook wins.

The geometric mean across all three workloads is **cluacov-hook 1.28× faster**
than pchook.  This result is consistent with other benchmarked machines
(Xeon 8369B, Apple M4 Pro) where cluacov-hook also wins overall.

## Implications for documentation

Both C hooks are dramatically faster than the pure-Lua luacov hook on all
tested machines (5–10× improvement).  The cluacov C line hook is faster overall
in geometric mean on all tested machines, though pchook wins on tight-loop
workloads.  The choice between the two should be guided primarily by **feature
requirements** (pchook enables PC-level branch coverage) rather than performance
alone.

## Caveats

- **Microbenchmark**: all three workloads are synthetic.  Real application code
  will have a different instruction-to-line ratio and a larger number of source
  files.  Multi-file workloads add one-time `file_included` lookup overhead per
  new file (cached thereafter), which affects both line hooks equally and does
  not affect pchook.
- **Single rep for luacov-hook × fib**: the probe took 6.2 s, exceeding the
  4 s threshold.  The single measurement is stable (fib is deterministic) but
  no variance estimate is available for this cell.
- **No I/O overhead**: the mock runner does not call `save_stats()`.  Periodic
  disk writes (tick mode) are not included in these measurements.
- **Lua 5.5 only**: pchook reads internal `CallInfo` and `Proto` fields via
  vendored headers and is only available on PUC-Rio Lua 5.4+.  The cluacov C
  hook and luacov pure-Lua hook are available on all supported versions
  (5.1–5.5, LuaJIT).
- **Shared-VM environment**: The Xeon 8269CY machine may be subject to
  noisy-neighbor effects in a shared infrastructure, though the low variance
  (±0–2%) suggests this was not significant during measurement.
