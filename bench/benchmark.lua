#!/usr/bin/env lua
--
-- Quantitative performance comparison:
--   baseline  vs  luacov pure-Lua hook  vs  cluacov C hook  vs  cluacov pchook
--
-- Methodology:
--   Each (workload × mode) cell is measured independently:
--     1. Warmup: one unmetered batch to prime tables and Proto cache.
--     2. Probe:  one timed batch to estimate per-batch cost.
--     3. Timed:  floor(TARGET_SECS / probe_secs) batches in a clean for-loop
--                with no os.clock() call inside the hot path.
--     4. Repeat steps 1-3 for N_REPS independent repetitions.
--        If probe_secs > SLOW_THRESHOLD, only one rep is taken (cell is noted).
--   Mode order is independently randomised in each rep to reduce thermal bias.
--
-- Usage:
--   cd <repo-root>
--   lua bench/benchmark.lua

package.cpath = "./cluacov/?.so;" .. package.cpath

local debug_lib   = require("debug")
local pchook      = require("cluacov.pchook")
local cluacov_hook = require("cluacov.hook")
local luacov_hook  = require("luacov.hook")
local math_lib    = math
local os_lib      = os

-- ── config ───────────────────────────────────────────────────────────────────
local TARGET_SECS    = 1.5   -- target CPU seconds per timed run
local SLOW_THRESHOLD = 4.0   -- if probe > this, take only 1 rep (note it)
local N_REPS         = 3     -- repetitions per cell (fast cells only)
local MAX_N_BATCHES  = 50000 -- sanity cap

math.randomseed(os.time())

-- ── workloads ────────────────────────────────────────────────────────────────
-- All workload functions defined at module level so their Proto is already
-- materialised before any hook starts (avoids first-call overhead in timed run).

local function _fib(n)
   if n < 2 then return n end
   return _fib(n - 1) + _fib(n - 2)
end

-- 1. Recursive – many function-call line/instruction events per op.
local function workload_fib(iters)
   for _ = 1, iters do _fib(24) end
end

-- 2. Tight numeric loop – many iterations, few distinct source lines, no calls.
local function workload_loop(iters)
   local sum = 0
   for i = 1, iters do
      sum = sum + i
      sum = sum - (i // 2)
      sum = sum + (i % 7)
   end
   return sum
end

-- 3. Deep call chain – moderate recursion, exercises function-activation overhead.
local function _chain(n)
   if n == 0 then return 0 end
   return 1 + _chain(n - 1)
end

local function workload_call(iters)
   for _ = 1, iters do _chain(100) end
end

-- batch_iters: argument passed to the workload function each call.
-- batch_ops:   number of logical "ops" represented by one call.
--              Used only for ops/s display; slowdown ratios are independent of it.
local WORKLOADS = {
   { name = "fib(24)",        fn = workload_fib,  batch_iters = 10,   batch_ops = 10    },
   { name = "loop×1 000",     fn = workload_loop, batch_iters = 1000, batch_ops = 1000  },
   { name = "call-chain/100", fn = workload_call, batch_iters = 200,  batch_ops = 200   },
}

-- ── mock runner (line hooks) ──────────────────────────────────────────────────
-- Mirrors the minimum interface used by luacov.hook / cluacov.hook.
-- file_included always returns true so every executed line is tracked,
-- matching real-world usage where the application under test is fully included.
local function make_runner()
   return {
      initialized = true,
      data        = {},
      tick        = false,
      paused      = false,
      configuration = {
         codefromstrings = false,
         include         = {},
         exclude         = {},
         savestepsize    = 100,
      },
      file_included = function() return true end,
   }
end

-- ── modes ─────────────────────────────────────────────────────────────────────
local MODES = {
   {
      name     = "baseline",
      setup    = function() end,
      teardown = function() end,
   },
   {
      name  = "luacov-hook",
      setup = function()
         debug_lib.sethook(luacov_hook.new(make_runner()), "l")
      end,
      teardown = function() debug_lib.sethook() end,
   },
   {
      name  = "cluacov-hook",
      setup = function()
         debug_lib.sethook(cluacov_hook.new(make_runner()), "l")
      end,
      teardown = function() debug_lib.sethook() end,
   },
   {
      name     = "pchook",
      setup    = function() pchook.start() end,
      teardown = function() pchook.stop(); pchook.reset() end,
   },
}

-- ── measurement primitives ────────────────────────────────────────────────────

-- Run fn(batch_iters) exactly n times and return elapsed CPU seconds.
-- The for-loop itself generates n+1 hook events (FORPREP + n×FORLOOP).
-- For any workload that produces >100 events per batch this is <1% noise.
local function run_n(fn, batch_iters, n)
   local t0 = os_lib.clock()
   for _ = 1, n do
      fn(batch_iters)
   end
   return os_lib.clock() - t0
end

-- One cell measurement: warmup → probe → timed-run.
-- Returns ops/s, probe_secs (for SLOW_THRESHOLD check), and n_batches used.
local function measure_one(fn, batch_iters, batch_ops)
   -- Step 1: warmup (1 batch, not timed).
   fn(batch_iters)

   -- Step 2: probe (1 batch, timed) to estimate per-batch cost.
   local probe_secs = run_n(fn, batch_iters, 1)
   if probe_secs < 1e-9 then probe_secs = 1e-9 end   -- guard against zero

   -- Step 3: compute n and run timed loop (no os.clock() inside hot path).
   local n = math_lib.max(1, math_lib.floor(TARGET_SECS / probe_secs))
   n = math_lib.min(n, MAX_N_BATCHES)
   local elapsed = run_n(fn, batch_iters, n)
   if elapsed < 1e-9 then elapsed = 1e-9 end

   return n * batch_ops / elapsed, probe_secs, n
end

-- ── shuffling ─────────────────────────────────────────────────────────────────
local function shuffle(t)
   local n = #t
   for i = n, 2, -1 do
      local j = math_lib.random(i)
      t[i], t[j] = t[j], t[i]
   end
end

-- ── result storage ────────────────────────────────────────────────────────────
-- results[wname][mname] = { mean, min, max, reps, slow_flag }
local results = {}
for _, w in ipairs(WORKLOADS) do
   results[w.name] = {}
end

-- ── run ───────────────────────────────────────────────────────────────────────
-- Build a flat list of (workload, mode) cells, then run N_REPS passes
-- with the cell order shuffled each pass to spread thermal bias.

local cells = {}
for _, w in ipairs(WORKLOADS) do
   for _, m in ipairs(MODES) do
      cells[#cells + 1] = { w = w, m = m }
   end
end

-- Accumulate per-cell samples across reps.
local samples = {}          -- samples[wname][mname] = { rates=[], slow=bool }
for _, c in ipairs(cells) do
   local t = samples[c.w.name]
   if not t then samples[c.w.name] = {}; t = samples[c.w.name] end
   if not t[c.m.name] then t[c.m.name] = { rates = {}, slow = false } end
end

local total_planned = #cells * N_REPS
local done = 0

io.write(string.format(
   "\nBenchmark  (%d workloads × %d modes × %d reps target)\n\n",
   #WORKLOADS, #MODES, N_REPS))

for rep = 1, N_REPS do
   -- Randomise cell order within this rep.
   local order = {}
   for i, c in ipairs(cells) do order[i] = c end
   shuffle(order)

   for _, cell in ipairs(order) do
      local w, m = cell.w, cell.m
      local s = samples[w.name][m.name]

      -- Skip extra reps for slow cells (already flagged in rep 1).
      if rep > 1 and s.slow then
         done = done + 1
         goto continue
      end

      done = done + 1
      io.write(string.format("  [%3d/%d] rep%d  %-13s × %-20s ... ",
         done, total_planned, rep, m.name, w.name))
      io.flush()

      m.setup()
      local rate, probe_secs, n_batches = measure_one(w.fn, w.batch_iters, w.batch_ops)
      m.teardown()

      s.rates[#s.rates + 1] = rate
      if probe_secs > SLOW_THRESHOLD then s.slow = true end

      local slow_note = s.slow and "  [slow: 1 rep only]" or ""
      io.write(string.format("%.3e ops/s  (probe %.2fs, n=%d)%s\n",
         rate, probe_secs, n_batches, slow_note))

      ::continue::
   end
end

-- ── aggregate ────────────────────────────────────────────────────────────────
for _, w in ipairs(WORKLOADS) do
   for _, m in ipairs(MODES) do
      local s = samples[w.name][m.name]
      local r = s.rates
      table.sort(r)
      local sum = 0
      for _, v in ipairs(r) do sum = sum + v end
      results[w.name][m.name] = {
         mean  = sum / #r,
         min   = r[1],
         max   = r[#r],
         reps  = #r,
         slow  = s.slow,
      }
   end
end

-- ── report ────────────────────────────────────────────────────────────────────
local function hrule(w) io.write(string.rep("─", w) .. "\n") end
local W = 100

io.write("\n")
hrule(W)
io.write(string.format(
   "%-22s  %-20s  %-22s  %-22s  %-22s\n",
   "Workload", "baseline (ops/s)", "luacov-hook", "cluacov-hook", "pchook"))
hrule(W)

for _, w in ipairs(WORKLOADS) do
   local r    = results[w.name]
   local base = r["baseline"].mean

   local function fmt(mname)
      local d = r[mname]
      local slowdown = base / d.mean
      local rep_note = d.slow and "*" or string.format("n=%d", d.reps)
      return string.format("%8.3e (%5.1fx) [%s]", d.mean, slowdown, rep_note)
   end

   io.write(string.format("%-22s  %8.3e [n=%d]       %s  %s  %s\n",
      w.name,
      base, r["baseline"].reps,
      fmt("luacov-hook"),
      fmt("cluacov-hook"),
      fmt("pchook")))
end
hrule(W)
io.write("Slowdown factor: baseline / hook_ops_per_sec.  * = slow cell, 1 rep.\n")

-- ── slowdown summary ──────────────────────────────────────────────────────────
local HOOK_MODES = { "luacov-hook", "cluacov-hook", "pchook" }

io.write("\nSlowdown vs baseline (× = slower):\n\n")
io.write(string.format("  %-22s  %14s  %14s  %14s\n",
   "Workload", "luacov-hook", "cluacov-hook", "pchook"))
io.write(string.rep("-", 70) .. "\n")

for _, w in ipairs(WORKLOADS) do
   local r    = results[w.name]
   local base = r["baseline"].mean
   io.write(string.format("  %-22s", w.name))
   for _, mn in ipairs(HOOK_MODES) do
      local note = r[mn].slow and "*" or " "
      io.write(string.format("  %12.1fx%s", base / r[mn].mean, note))
   end
   io.write("\n")
end

io.write(string.rep("-", 70) .. "\n")
io.write(string.format("  %-22s", "geometric mean"))
for _, mn in ipairs(HOOK_MODES) do
   local lsum = 0
   for _, w in ipairs(WORKLOADS) do
      lsum = lsum + math_lib.log(results[w.name]["baseline"].mean / results[w.name][mn].mean)
   end
   io.write(string.format("  %12.1fx ", math_lib.exp(lsum / #WORKLOADS)))
end
io.write("\n\n")

-- ── variance table ────────────────────────────────────────────────────────────
io.write("Run-to-run variance (min / mean / max ops/s, fast cells only):\n\n")
io.write(string.format("  %-22s  %-14s  %-22s  %-22s  %-22s\n",
   "Workload", "baseline", "luacov-hook", "cluacov-hook", "pchook"))
io.write(string.rep("-", 92) .. "\n")

local function fmt_var(d)
   if d.reps == 1 then
      return string.format("  %-22s", string.format("%.3e (1 rep)", d.mean))
   end
   local pct = (d.max - d.min) / d.mean * 100
   return string.format("  %-22s", string.format("%.3e..%.3e (±%.0f%%)", d.min, d.max, pct/2))
end

for _, w in ipairs(WORKLOADS) do
   local r = results[w.name]
   io.write(string.format("  %-22s", w.name))
   for _, mn in ipairs({"baseline", "luacov-hook", "cluacov-hook", "pchook"}) do
      io.write(fmt_var(r[mn]))
   end
   io.write("\n")
end
io.write(string.rep("-", 92) .. "\n\n")

-- ── cluacov-hook vs pchook head-to-head ──────────────────────────────────────
io.write("cluacov C hook vs pchook:\n\n")
io.write(string.format("  %-22s  %14s  %14s  %s\n",
   "Workload", "cluacov-hook", "pchook", "winner"))
io.write(string.rep("-", 72) .. "\n")

local lsum_ratio = 0
for _, w in ipairs(WORKLOADS) do
   local r      = results[w.name]
   local base   = r["baseline"].mean
   local ch_s   = base / r["cluacov-hook"].mean
   local ph_s   = base / r["pchook"].mean
   local ratio  = r["pchook"].mean / r["cluacov-hook"].mean  -- >1 → pchook faster
   lsum_ratio   = lsum_ratio + math_lib.log(ratio)
   local winner, margin
   if ratio >= 1 then winner = "pchook";       margin = ratio
   else              winner = "cluacov-hook";  margin = 1 / ratio end
   io.write(string.format("  %-22s  %12.1fx    %12.1fx    %s (%.2fx)\n",
      w.name, ch_s, ph_s, winner, margin))
end
io.write(string.rep("-", 72) .. "\n")
local gm = math_lib.exp(lsum_ratio / #WORKLOADS)
local gm_winner = gm >= 1 and "pchook" or "cluacov-hook"
local gm_margin = gm >= 1 and gm or 1/gm
io.write(string.format("  %-22s  %28s    %s (%.2fx)\n",
   "geometric mean", "", gm_winner, gm_margin))
io.write("\n")

-- ── footer ────────────────────────────────────────────────────────────────────
io.write(string.format("Lua:    %s\n", _VERSION))
io.write(string.format("Config: TARGET_SECS=%.1f  SLOW_THRESHOLD=%.1f  N_REPS=%d\n",
   TARGET_SECS, SLOW_THRESHOLD, N_REPS))
io.write("* = slow cell (probe > SLOW_THRESHOLD), only 1 rep taken.\n")
