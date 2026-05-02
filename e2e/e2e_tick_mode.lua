#!/usr/bin/env lua
--
-- E2E test for pchook tick mode (incremental save_stats during runtime).
--
-- Long-running processes (servers, daemons, long benchmarks) can't wait
-- for shutdown to flush coverage data — they need periodic snapshots.
-- pchook exposes this via the `tick` config to `pchook.start({...})`:
--
--   pchook.start({
--      savestepsize = N,        -- fire save_stats every N line events
--      save_stats   = function() ... end,
--   })
--
-- This script runs a workload large enough to trigger save_stats AT
-- LEAST `min_expected_calls` times, asserts the callback fired, AND
-- asserts that hit-collection still works correctly while ticking.
--

local function resolve_dir(path)
   if path:sub(1, 1) == "/" then return path end
   local pwd = io.popen("pwd"):read("*l")
   if path == "" or path == "./" then return pwd .. "/" end
   return pwd .. "/" .. path
end

local e2e_dir = resolve_dir(arg[0]:match("(.-)[^/]*$") or "./")
package.path = e2e_dir .. "?.lua;" .. package.path

local pchook = require("cluacov.pchook")

print("=== Step 1: Starting pchook in tick mode ===")

local save_calls = 0
local hits_at_each_save = {}

-- savestepsize=50: ~50 line events per save callback. The workload
-- below triggers thousands of line events.
pchook.start({
   savestepsize = 50,
   save_stats = function()
      save_calls = save_calls + 1
      -- Inside the callback, get_all_line_hits should be safe to call
      -- and return a non-empty snapshot. This is what real long-lived
      -- consumers (e.g. periodic coverage exporters) would do.
      local snap = pchook.get_all_line_hits()
      local n_sources = 0
      for _ in pairs(snap) do n_sources = n_sources + 1 end
      hits_at_each_save[#hits_at_each_save + 1] = n_sources
   end,
})

print("=== Step 2: Running large workload ===")

local sample = require("sample")

-- Hammer multiple sample functions to generate plenty of line events.
local total_iterations = 500
for i = 1, total_iterations do
   assert(sample.classify(i % 3 - 1) ~= nil)  -- positive / zero / negative
   assert(sample.abs(-i) == i)
   assert(sample.sum({1, 2, 3, 4, 5}) == 15)
   assert(sample.find({i, i+1, i+2}, i+1) == true)
   if i % 15 == 0 then
      assert(sample.fizzbuzz(i) == "fizzbuzz")
   end
end

pchook.stop()

local function fail(msg, ...)
   io.stderr:write(string.format("FAIL: " .. msg .. "\n", ...))
   os.exit(1)
end

local function ok(msg, ...)
   print(string.format("  OK: " .. msg, ...))
end

print("=== Step 3: Asserting save_stats fired ===")

-- With savestepsize=50 and ~500 outer iterations × dozens of inner
-- line events, we expect MANY save callbacks. We pick a conservative
-- floor (>= 5) to avoid false positives from JIT / small-VM variance.
local min_expected_calls = 5
if save_calls < min_expected_calls then
   fail("save_stats only called %d times; expected >= %d (savestepsize=50, %d iters)",
      save_calls, min_expected_calls, total_iterations)
end
ok("save_stats fired %d times (>= %d expected)", save_calls, min_expected_calls)

print("=== Step 4: Asserting snapshots inside callbacks were valid ===")

if #hits_at_each_save == 0 then
   fail("no snapshot recorded inside save callbacks")
end

-- Snapshot data should grow (or stay stable) over time, not shrink to
-- zero. A drop to zero would indicate the live data was corrupted by a
-- save call.
local first, last = hits_at_each_save[1], hits_at_each_save[#hits_at_each_save]
ok("first save snapshot saw %d source(s); last save saw %d source(s)",
   first, last)
if last < first then
   fail("snapshot source-count shrank from %d → %d across saves (corruption?)",
      first, last)
end

print("=== Step 5: Asserting final hit data is complete ===")

-- After stop(), the global aggregate must contain at least sample.lua
-- and the per-line data must reflect the workload (sample.sum runs
-- 500 times → its loop body must have very high hit counts).
local all_lines = pchook.get_all_line_hits()
local sample_source, sample_lines
for source, lines in pairs(all_lines) do
   if type(source) == "string" and source:match("sample%.lua") then
      sample_source = source
      sample_lines = lines
      break
   end
end

if not sample_lines then
   fail("sample.lua not present in final get_all_line_hits aggregate")
end
ok("sample.lua present under key %q", sample_source)

-- M.sum's loop body is at L32 in sample.lua. With 500 outer iters and
-- t={1..5}, that line should have been hit at least 500 * 5 = 2500
-- times. Use a generous floor (>= 1000) to absorb potential opcode
-- folding differences across Lua minor versions.
local sum_body_hits = sample_lines[32] or 0
if sum_body_hits < 1000 then
   fail("M.sum body line 32 hit %d times; expected >= 1000", sum_body_hits)
end
ok("M.sum body line 32 hit %d times (>= 1000)", sum_body_hits)

-- Reset cleanup: a second start() without tick should not somehow
-- inherit the tick config. We don't crash here, just assert a sanity
-- check that the previous tick state was cleared.
pchook.reset()
local empty = pchook.get_all_line_hits()
local has_any = false
for _ in pairs(empty) do has_any = true; break end
if has_any then
   fail("pchook.reset() did not clear all line hits")
end
ok("pchook.reset() cleared all line hits")

print("\n=== E2E tick-mode test PASSED ===")
