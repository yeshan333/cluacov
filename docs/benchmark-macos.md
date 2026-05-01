# cluacov Hook Performance Benchmark — macOS (Apple Silicon)

This document presents macOS benchmark results using the same methodology as the
[Linux benchmark](benchmark.md), enabling cross-platform comparison.

## Environment

| Item | Value |
|---|---|
| Lua version | Lua 5.5.0 |
| CPU | Apple M4 Pro |
| Cores | 12 (performance + efficiency) |
| Memory | 48 GiB |
| OS | macOS 15 (Darwin 25.3.0 arm64) |
| Timing | `os.clock()` (process CPU time) |

## Linux reference environment

| Item | Value |
|---|---|
| Lua version | Lua 5.5.0 |
| CPU | Intel Xeon Platinum 8269CY @ 2.50 GHz |
| Cores | 104 logical |
| Memory | 16 GiB |
| OS | Linux 5.10 (ubuntu-latest) |

## Methodology

Identical to the Linux benchmark — see [benchmark.md § Methodology](benchmark.md#methodology).

Script: [`bench/benchmark.lua`](../bench/benchmark.lua)  
Config: `TARGET_SECS=1.5`, `SLOW_THRESHOLD=4.0`, `N_REPS=3`

## Results

### Raw throughput and slowdown

```
Workload              baseline (ops/s)   luacov-hook           cluacov-hook          pchook
─────────────────────────────────────────────────────────────────────────────────────────────
fib(24)               9.461e+02          5.011e+00 (188.8x)    3.292e+01  (28.7x)    1.891e+01  (50.0x)
loop×1 000           1.863e+08          2.871e+05 (649.1x)    2.053e+06  (90.8x)    2.698e+06  (69.1x)
call-chain/100        1.204e+06          5.505e+03 (218.8x)    3.864e+04  (31.2x)    2.639e+04  (45.6x)
─────────────────────────────────────────────────────────────────────────────────────────────
geometric mean                                     299.3x                   43.3x               54.0x
```

### Run-to-run variance

All cells ran 3 reps. Variance is low, confirming stable measurements:

```
Workload              baseline              luacov-hook           cluacov-hook          pchook
──────────────────────────────────────────────────────────────────────────────────────────────────────
fib(24)               9.43e+02..9.49e+02   4.89e+00..5.20e+00   3.15e+01..3.39e+01   1.81e+01..1.93e+01
                      (±0%)                (±3%)                 (±4%)                (±3%)
loop×1 000           1.77e+08..1.93e+08   2.77e+05..2.97e+05   2.02e+06..2.10e+06   2.69e+06..2.71e+06
                      (±4%)                (±4%)                 (±2%)                (±0%)
call-chain/100        1.18e+06..1.22e+06   5.36e+03..5.73e+03   3.71e+04..4.01e+04   2.56e+04..2.69e+04
                      (±2%)                (±3%)                 (±4%)                (±3%)
```

### cluacov C hook vs pchook — head-to-head

```
Workload              cluacov-hook    pchook      winner
────────────────────────────────────────────────────────
fib(24)               28.7x           50.0x       cluacov-hook  (1.74x)
loop×1 000           90.8x           69.1x       pchook        (1.31x)
call-chain/100        31.2x           45.6x       cluacov-hook  (1.46x)
────────────────────────────────────────────────────────
geometric mean                                    cluacov-hook  (1.25x)
```

## Cross-platform comparison (macOS vs Linux)

### Baseline throughput

| Workload | Linux (ops/s) | macOS (ops/s) | macOS / Linux |
|---|---|---|---|
| fib(24) | 2.846e+02 | 9.461e+02 | **3.32x faster** |
| loop×1 000 | 2.661e+07 | 1.863e+08 | **7.00x faster** |
| call-chain/100 | 4.128e+05 | 1.204e+06 | **2.92x faster** |

Apple M4 Pro baseline throughput is 2.9–7.0x higher than the Linux CI runner
(Intel Xeon 8269CY), reflecting the ARM chip's superior single-thread IPC and
the advantage of dedicated hardware vs. shared CI.

### Slowdown factors comparison

| Workload | Mode | Linux slowdown | macOS slowdown | Delta |
|---|---|---|---|---|
| fib(24) | luacov-hook | 175.5x | 188.8x | +8% |
| fib(24) | cluacov-hook | 22.3x | 28.7x | +29% |
| fib(24) | pchook | 24.1x | 50.0x | +107% |
| loop×1 000 | luacov-hook | 287.0x | 649.1x | +126% |
| loop×1 000 | cluacov-hook | 33.1x | 90.8x | +174% |
| loop×1 000 | pchook | 17.0x | 69.1x | +306% |
| call-chain/100 | luacov-hook | 227.2x | 218.8x | -4% |
| call-chain/100 | cluacov-hook | 27.4x | 31.2x | +14% |
| call-chain/100 | pchook | 25.7x | 45.6x | +78% |

### Geometric mean slowdown

| Mode | Linux | macOS |
|---|---|---|
| luacov-hook | 225.3x | 299.3x |
| cluacov-hook | 27.2x | 43.3x |
| pchook | 21.9x | 54.0x |

### Head-to-head winner (cluacov-hook vs pchook)

| | Linux | macOS |
|---|---|---|
| fib(24) | cluacov-hook (1.08x) | cluacov-hook (1.74x) |
| loop×1 000 | pchook (1.95x) | pchook (1.31x) |
| call-chain/100 | pchook (1.07x) | cluacov-hook (1.46x) |
| **geometric mean** | **pchook (1.24x)** | **cluacov-hook (1.25x)** |

## Analysis

### Key observations

1. **Absolute performance**: The Apple M4 Pro delivers 2.9–7.0x higher baseline
   throughput than the Linux CI runner. This is expected — the M4 Pro is a
   modern high-IPC ARM chip on dedicated hardware, vs. a shared Xeon VM.

2. **Slowdown ratios are higher on macOS**: All hook modes show higher relative
   overhead on macOS (43.3x vs 27.2x for cluacov-hook geometric mean; 54.0x vs
   21.9x for pchook). This is consistent with the M4's faster baseline: when
   the uninstrumented code runs much faster, the fixed per-event hook cost
   becomes a larger relative penalty.

3. **pchook loses its advantage on macOS**: On Linux, pchook's geometric mean
   slowdown (21.9x) beats cluacov-hook (27.2x) by 1.24x. On macOS, the
   relationship **reverses** — cluacov-hook (43.3x) beats pchook (54.0x) by
   1.25x. pchook only wins on the `loop×1 000` workload; cluacov-hook wins
   on both `fib(24)` and `call-chain/100`.

4. **Why the reversal?** pchook fires on every VM instruction (3–7x more events
   than the line hook). On the M4 Pro's fast pipeline, the sheer event volume
   outweighs pchook's cheaper per-event cost. The instruction-to-line ratio
   penalty is more pronounced when the baseline executes faster.

5. **luacov pure-Lua hook**: Remains the slowest by a wide margin on both
   platforms (299.3x vs 225.3x geometric mean), confirming that the Lua dispatch
   + `debug.getinfo` overhead dominates regardless of CPU architecture.

### Practical implications

- On **Apple Silicon Macs** (development machines), the cluacov C line hook
  (`cluacov.hook`) provides the best performance for coverage collection.
- On **Linux x86 servers / CI**, pchook remains slightly faster overall.
- Both C hooks are dramatically faster than the pure-Lua luacov hook on all
  platforms (5–10x improvement).
- The choice between cluacov-hook and pchook should be guided primarily by
  **feature requirements** (pchook enables PC-level branch coverage) rather
  than performance alone, as the performance difference is workload-dependent
  and moderate in either direction.

## Caveats

- All caveats from the [Linux benchmark](benchmark.md#caveats) apply.
- **Apple M4 Pro efficiency cores**: `os.clock()` measures CPU time, so
  efficiency-core scheduling should not affect results, but core migration
  during measurement could introduce minor noise.
- **Thermal throttling**: Unlike the Linux VM, physical hardware may throttle
  under sustained load. The ±0–4% variance observed suggests this is not a
  significant factor for this benchmark duration.
- **Compiler differences**: macOS uses Apple Clang (via `gcc` shim) while the
  Linux CI uses GCC. Different code generation and optimization could affect
  C hook performance.
