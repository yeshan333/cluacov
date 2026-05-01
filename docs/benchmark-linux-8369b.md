# cluacov Hook Performance Benchmark — Linux (Intel Xeon 8369B)

This document presents Linux benchmark results on a different machine from the
[original Linux benchmark](benchmark.md), enabling cross-machine comparison.

## Environment

| Item | Value |
|---|---|
| Lua version | Lua 5.5.0 |
| CPU | Intel Xeon Platinum 8369B @ 2.70 GHz |
| Cores | 8 logical |
| Memory | 32 GiB |
| OS | Linux 5.10 (x86_64) |
| Timing | `os.clock()` (process CPU time) |

## Reference environments

| Item | This machine | Original Linux | macOS |
|---|---|---|---|
| CPU | Xeon 8369B @ 2.70 GHz | Xeon 8269CY @ 2.50 GHz | Apple M4 Pro |
| Cores | 8 | 104 | 12 |
| Memory | 32 GiB | 16 GiB | 48 GiB |
| OS | Linux 5.10 | Linux 5.10 | macOS 15 |

## Methodology

Identical to the [Linux benchmark](benchmark.md#methodology).

Script: [`bench/benchmark.lua`](../bench/benchmark.lua)
Config: `TARGET_SECS=1.5`, `SLOW_THRESHOLD=4.0`, `N_REPS=3`

## Results

### Raw throughput and slowdown

```
Workload              baseline (ops/s)   luacov-hook           cluacov-hook          pchook
─────────────────────────────────────────────────────────────────────────────────────────────
fib(24)               2.115e+02          1.166e+00 (181.4x)*   8.548e+00  (24.7x)    4.721e+00  (44.8x)
loop×1 000           3.626e+07          6.719e+04 (539.7x)    5.521e+05  (65.7x)    6.391e+05  (56.7x)
call-chain/100        3.134e+05          1.302e+03 (240.8x)    1.011e+04  (31.0x)    6.522e+03  (48.0x)
─────────────────────────────────────────────────────────────────────────────────────────────
geometric mean                                     286.7x                   36.9x               49.6x
```

`*` = slow cell; probe exceeded 4 s threshold; single rep only.

### Run-to-run variance

All fast cells (3 reps each) show low noise, confirming stable measurements:

```
Workload              baseline              luacov-hook           cluacov-hook          pchook
──────────────────────────────────────────────────────────────────────────────────────────────
fib(24)               2.07e+02..2.15e+02   (1 rep, 8.5 s probe) 8.48e+00..8.65e+00   4.70e+00..4.73e+00
                      (±2%)                                       (±1%)                (±0%)
loop×1 000           3.60e+07..3.64e+07   6.70e+04..6.74e+04   5.46e+05..5.56e+05   6.18e+05..6.52e+05
                      (±1%)                (±0%)                 (±1%)                (±3%)
call-chain/100        3.11e+05..3.16e+05   1.30e+03..1.31e+03   1.00e+04..1.02e+04   6.48e+03..6.54e+03
                      (±1%)                (±0%)                 (±1%)                (±0%)
```

### cluacov C hook vs pchook — head-to-head

```
Workload              cluacov-hook    pchook      winner
────────────────────────────────────────────────────────
fib(24)               24.7x           44.8x       cluacov-hook  (1.81x)
loop×1 000           65.7x           56.7x       pchook        (1.16x)
call-chain/100        31.0x           48.0x       cluacov-hook  (1.55x)
────────────────────────────────────────────────────────
geometric mean                                    cluacov-hook  (1.34x)
```

## Cross-machine comparison

### Baseline throughput

| Workload | Xeon 8269CY (ops/s) | Xeon 8369B (ops/s) | M4 Pro (ops/s) | 8369B / 8269CY |
|---|---|---|---|---|
| fib(24) | 2.851e+02 | 2.115e+02 | 9.461e+02 | 0.74x |
| loop×1 000 | 2.671e+07 | 3.626e+07 | 1.863e+08 | 1.36x |
| call-chain/100 | 4.131e+05 | 3.134e+05 | 1.204e+06 | 0.76x |

The Xeon 8369B delivers comparable baseline throughput to the 8269CY — slightly
faster on tight loops (1.36x) but slower on recursive workloads (0.74–0.76x),
likely reflecting differences in turbo behavior and shared-VM vs. dedicated
resource allocation.

### Slowdown factors comparison

| Workload | Mode | 8269CY slowdown | 8369B slowdown | M4 Pro slowdown |
|---|---|---|---|---|
| fib(24) | luacov-hook | 179.3x | 181.4x | 188.8x |
| fib(24) | cluacov-hook | 23.9x | 24.7x | 28.7x |
| fib(24) | pchook | 39.9x | 44.8x | 50.0x |
| loop×1 000 | luacov-hook | 294.6x | 539.7x | 649.1x |
| loop×1 000 | cluacov-hook | 33.6x | 65.7x | 90.8x |
| loop×1 000 | pchook | 27.6x | 56.7x | 69.1x |
| call-chain/100 | luacov-hook | 232.6x | 240.8x | 218.8x |
| call-chain/100 | cluacov-hook | 27.8x | 31.0x | 31.2x |
| call-chain/100 | pchook | 42.7x | 48.0x | 45.6x |

### Geometric mean slowdown

| Mode | Xeon 8269CY | Xeon 8369B | M4 Pro |
|---|---|---|---|
| luacov-hook | 230.7x | 286.7x | 299.3x |
| cluacov-hook | 28.1x | 36.9x | 43.3x |
| pchook | 36.1x | 49.6x | 54.0x |

### Head-to-head winner (cluacov-hook vs pchook)

| | Xeon 8269CY | Xeon 8369B | M4 Pro |
|---|---|---|---|
| fib(24) | cluacov-hook (1.67x) | cluacov-hook (1.81x) | cluacov-hook (1.74x) |
| loop×1 000 | pchook (1.22x) | pchook (1.16x) | pchook (1.31x) |
| call-chain/100 | cluacov-hook (1.53x) | cluacov-hook (1.55x) | cluacov-hook (1.46x) |
| **geometric mean** | **cluacov-hook (1.28x)** | **cluacov-hook (1.34x)** | **cluacov-hook (1.25x)** |

## Analysis

### Key observations

1. **cluacov-hook wins on all machines**: cluacov-hook's geometric mean
   slowdown (36.9x) beats pchook (49.6x) by 1.34x on the Xeon 8369B. This
   is consistent with all other benchmarked machines — Xeon 8269CY (1.28x)
   and Apple M4 Pro (1.25x).

2. **Slowdown ratios are higher than the Xeon 8269CY**: The Xeon 8369B
   shows higher hook overhead than the 8269CY (e.g., pchook 49.6x
   vs 36.1x), despite comparable baseline throughput. This is consistent with
   the observation from the macOS benchmark: when the per-event hook cost is
   higher relative to baseline, the fixed hook cost becomes a larger relative
   penalty.

3. **pchook disproportionately affected**: pchook's slowdown increases from
   36.1x to 49.6x (1.37x increase) while cluacov-hook only increases from
   28.1x to 36.9x (1.31x increase). pchook fires 3–7x more events than the
   line hook; the cumulative effect of these extra events is amplified on
   machines where the per-event overhead dominates.

4. **Only loop×1 000 favors pchook**: Across all benchmarked machines,
   pchook only wins on the tight numeric loop workload (lowest instruction-to-line
   ratio of ~3:1). Both recursive workloads favor cluacov-hook.

5. **luacov pure-Lua hook**: Remains the slowest by a wide margin on all
   machines, confirming that the Lua dispatch + `debug.getinfo` overhead dominates
   regardless of CPU architecture.

### Practical implications

- cluacov-hook is faster overall on all tested machines (Xeon 8269CY, Xeon
  8369B, Apple M4 Pro), with a geometric mean advantage of 1.25–1.34x.
- The performance gap between cluacov-hook and pchook is moderate per workload
  (1.16–1.67x), so the choice should be guided primarily by **feature
  requirements** (pchook enables PC-level branch coverage) rather than
  performance alone.
- Both C hooks are dramatically faster than the pure-Lua luacov hook on all
  tested machines (5–10x improvement).

## Caveats

- All caveats from the [Linux benchmark](benchmark.md#caveats) apply.
- **Shared-VM environment**: The Xeon 8369B machine may be subject to
  noisy-neighbor effects in a shared infrastructure, though the low variance
  (±0–3%) suggests this was not significant during measurement.
- **Compiler**: GCC was used on this machine; the original Linux CI runner also
  uses GCC. The macOS benchmark uses Apple Clang, which may produce different
  code generation for the C hooks.
