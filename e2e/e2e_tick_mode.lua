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
-- asserts that hit-collection still works correctly while ticking,
-- including the per-PC branch-coverage path used by branchcov/LCOV.
--

local function resolve_dir(path)
   if path:sub(1, 1) == "/" then return path end
   local pwd = io.popen("pwd"):read("*l")
   if path == "" or path == "./" then return pwd .. "/" end
   return pwd .. "/" .. path
end

local e2e_dir = resolve_dir(arg[0]:match("(.-)[^/]*$") or "./")
local output_dir = e2e_dir .. "output"
local sample_file = e2e_dir .. "sample.lua"
local tick_lcov_file = output_dir .. "/tick_branch_coverage.lcov"
local tick_html_dir = output_dir .. "/tick_branch/html"

package.path = e2e_dir .. "?.lua;" .. package.path
os.execute("mkdir -p " .. output_dir)

local pchook = require("cluacov.pchook")

print("=== Step 1: Starting pchook in tick mode ===")

local save_calls = 0
local hits_at_each_save = {}
local pc_protos_at_each_save = {}

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

      -- Also exercise the per-PC aggregation path while the hook is still
      -- active. Branch coverage depends on this data, not just line hits.
      local pc_snap = pchook.get_all_hits()
      local n_protos = 0
      for _, protos in pairs(pc_snap) do
         if type(protos) == "table" then
            n_protos = n_protos + #protos
         end
      end
      pc_protos_at_each_save[#pc_protos_at_each_save + 1] = n_protos
   end,
})

print("=== Step 2: Running large workload ===")

-- Use an explicit chunk object, not `require("sample")`, so branchcov can
-- analyze the exact same Proto tree that executed under the tick hook.
local sample_func = assert(loadfile(sample_file))
local sample = sample_func()
package.loaded["sample"] = sample

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

local pc_first = pc_protos_at_each_save[1] or 0
local pc_last = pc_protos_at_each_save[#pc_protos_at_each_save] or 0
ok("first save PC snapshot saw %d proto(s); last save saw %d proto(s)",
   pc_first, pc_last)
if pc_last <= 0 then
   fail("PC snapshots never observed any proto data during tick mode")
end
if pc_last < pc_first then
   fail("PC snapshot proto-count shrank from %d to %d across saves",
      pc_first, pc_last)
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

print("=== Step 6: Asserting tick-mode branch coverage is complete ===")

local branchcov = require("cluacov.branchcov")
local result = branchcov.analyze(sample_func)

if #result.branches <= 0 then
   fail("branchcov found no branch sites under tick mode")
end
if result.total <= #result.branches then
   fail("branch target count %d should be greater than branch site count %d",
      result.total, #result.branches)
end
if result.hit <= 0 then
   fail("branchcov found %d branch targets but none were hit under tick mode",
      result.total)
end

local covered, partial = 0, 0
for _, branch in ipairs(result.branches) do
   if branch.status == "covered" then
      covered = covered + 1
   elseif branch.status == "partial" then
      partial = partial + 1
   end
end
if covered <= 0 then
   fail("tick-mode branch coverage produced no covered branches")
end
if partial <= 0 then
   fail("tick-mode branch coverage produced no partial branches")
end
ok("branchcov under tick mode: %d sites, %d targets, %d hit, %d covered, %d partial",
   #result.branches, result.total, result.hit, covered, partial)

local lcov_fh = assert(io.open(tick_lcov_file, "w"))
lcov_fh:write("TN:cluacov-e2e-tick\n")
lcov_fh:write("SF:" .. sample_file .. "\n")

local block_id = 0
local branches_found, branches_hit = 0, 0
for _, branch in ipairs(result.branches) do
   branches_found = branches_found + #branch.targets
   for target_idx, target in ipairs(branch.targets) do
      lcov_fh:write(string.format("BRDA:%d,%d,%d,%s\n",
         branch.line,
         block_id,
         target_idx - 1,
         target.hits > 0 and tostring(target.hits) or "-"))
      if target.hits > 0 then
         branches_hit = branches_hit + 1
      end
   end
   block_id = block_id + 1
end
lcov_fh:write(string.format("BRF:%d\n", branches_found))
lcov_fh:write(string.format("BRH:%d\n", branches_hit))

local deepactivelines = require("cluacov.deepactivelines")
local active_lines = deepactivelines.get(sample_func)
local lines_found, lines_hit = 0, 0
for line_nr = 1, sample_lines.max or 0 do
   if active_lines[line_nr] then
      local hits = sample_lines[line_nr] or 0
      lcov_fh:write(string.format("DA:%d,%d\n", line_nr, hits))
      lines_found = lines_found + 1
      if hits > 0 then
         lines_hit = lines_hit + 1
      end
   end
end
lcov_fh:write(string.format("LF:%d\n", lines_found))
lcov_fh:write(string.format("LH:%d\n", lines_hit))
lcov_fh:write("end_of_record\n")
lcov_fh:close()

local verify_fh = assert(io.open(tick_lcov_file, "r"))
local lcov_content = verify_fh:read("*a")
verify_fh:close()
if not lcov_content:match("BRDA:") then
   fail("tick-mode LCOV file does not contain BRDA records")
end
if not lcov_content:match("BRF:%d+") or not lcov_content:match("BRH:%d+") then
   fail("tick-mode LCOV file does not contain BRF/BRH summary records")
end
if not lcov_content:match("DA:%d+,%d+") or not lcov_content:match("LF:%d+") then
   fail("tick-mode LCOV file does not contain valid line records")
end
ok("tick-mode LCOV records written to %s (BRF=%d, BRH=%d, LF=%d, LH=%d)",
   tick_lcov_file, branches_found, branches_hit, lines_found, lines_hit)

print("=== Step 7: Generating tick-mode branch HTML report ===")

os.execute("rm -rf " .. tick_html_dir .. " && mkdir -p " .. tick_html_dir)
local genhtml_cmd = string.format(
   "genhtml --quiet --legend --branch-coverage --title %q --output-directory %q %q 2>&1",
   "cluacov tick-mode branch coverage E2E",
   tick_html_dir,
   tick_lcov_file)

local pipe = io.popen(genhtml_cmd .. "; echo __EXIT__:$?")
local genhtml_out = pipe:read("*a")
pipe:close()

local genhtml_exit = genhtml_out:match("__EXIT__:(%d+)")
if genhtml_exit == "0" then
   local index_html = tick_html_dir .. "/index.html"
   local index_fh = io.open(index_html, "r")
   if not index_fh then
      fail("genhtml succeeded but %s not found", index_html)
   end
   index_fh:close()
   ok("tick-mode branch HTML report generated: %s", index_html)
else
   -- Keep local development lightweight when lcov/genhtml is not installed.
   -- CI installs lcov in coverage.yml, so this path should not be taken there.
   io.stderr:write("WARN: genhtml not available or failed (exit=" ..
      tostring(genhtml_exit) .. "); skipping tick-mode HTML report.\n")
   io.stderr:write(genhtml_out)
end

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
