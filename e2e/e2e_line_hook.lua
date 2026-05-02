#!/usr/bin/env lua
--
-- E2E test for the OLD line-based hook (src/cluacov/hook.c).
--
-- This is the LuaCov-native collection mode that ships with cluacov via
-- `cluacov.hook`. It works on Lua 5.1 / 5.2 / 5.3 / 5.4 / LuaJIT — i.e.
-- it is the ONLY mode available to a huge swath of production Lua users
-- (anything pre-5.4 or LuaJIT-based).
--
-- The PC-mode E2E in `e2e_branch_coverage.lua` already covers the
-- per-instruction path; this script makes sure we ALSO have an end-to-end
-- guard for the line-mode path:
--
--   1. Drive a fake luacov-compatible runner through `cluacov.hook`
--   2. Execute the `sample.lua` workload
--   3. Verify per-line hit data is collected
--   4. Spot-check known executed lines (function bodies that ran) and
--      known un-executed lines (the negative branch of `classify` is
--      never reached by `run_test.lua`, etc.)
--

local function resolve_dir(path)
   if path:sub(1, 1) == "/" then return path end
   local pwd = io.popen("pwd"):read("*l")
   if path == "" or path == "./" then return pwd .. "/" end
   return pwd .. "/" .. path
end

local e2e_dir = resolve_dir(arg[0]:match("(.-)[^/]*$") or "./")
local sample_file = e2e_dir .. "sample.lua"
local run_test_file = e2e_dir .. "run_test.lua"

package.path = e2e_dir .. "?.lua;" .. package.path

print("=== Step 1: Building a luacov-compatible runner shim ===")

-- Mimic the minimal `runner` interface that cluacov.hook expects. The
-- hook only uses: runner.initialized, runner.data, runner.configuration,
-- runner.tick, runner.paused, runner.file_included(), runner.save_stats().
local fake_runner = {
   initialized = true,
   data = {},
   configuration = { codefromstrings = false, savestepsize = 100 },
   tick = false,
   paused = false,
}

local file_included_calls = {}
function fake_runner.file_included(filename)
   file_included_calls[#file_included_calls + 1] = filename
   -- Only collect lines from our sample, not from cluacov / lua stdlib.
   return filename:match("e2e/sample%.lua$")
       or filename:match("e2e/run_test%.lua$") ~= nil
end

local save_stats_calls = 0
function fake_runner.save_stats()
   save_stats_calls = save_stats_calls + 1
end

print("=== Step 2: Installing line hook ===")

local hook_module = require("cluacov.hook")
local hook = hook_module.new(fake_runner)
debug.sethook(hook, "l")

print("=== Step 3: Loading and exercising sample under the hook ===")

local sample_func = assert(loadfile(sample_file))
local sample_module = sample_func()
package.loaded["sample"] = sample_module

local run_func = assert(loadfile(run_test_file))
run_func()

debug.sethook()

print("=== Step 4: Verifying collected per-line data ===")

-- Locate the entry for sample.lua in runner.data. The hook keys by the
-- short_src reported by the debug API; for files loaded with loadfile
-- this is typically the absolute or relative path.
local sample_key, sample_data
for filename, data in pairs(fake_runner.data) do
   if filename:match("sample%.lua$") then
      sample_key = filename
      sample_data = data
      break
   end
end

local function fail(msg, ...)
   io.stderr:write(string.format("FAIL: " .. msg .. "\n", ...))
   os.exit(1)
end

local function ok(msg, ...)
   print(string.format("  OK: " .. msg, ...))
end

if not sample_data then
   fail("sample.lua entry not found in runner.data; tracked files: %s",
      (function()
         local names = {}
         for k in pairs(fake_runner.data) do names[#names + 1] = k end
         return table.concat(names, ", ")
      end)())
end

ok("sample.lua tracked under key %q", sample_key)

-- runner.data[file] is a sparse array: data[line] = hit_count, plus
-- data.max and data.max_hits.
if type(sample_data.max) ~= "number" or sample_data.max <= 0 then
   fail("sample.max should be a positive number, got %s",
      tostring(sample_data.max))
end
ok("sample.max = %d (>= 1)", sample_data.max)

if type(sample_data.max_hits) ~= "number" or sample_data.max_hits <= 0 then
   fail("sample.max_hits should be > 0, got %s",
      tostring(sample_data.max_hits))
end
ok("sample.max_hits = %d (>= 1)", sample_data.max_hits)

-- Spot-check: lines that MUST be hit (corresponding to things
-- run_test.lua actually called).
--
-- These line numbers must stay in sync with sample.lua. They are picked
-- to cover several function bodies and several control-flow shapes.
local must_be_hit = {
   [4]   = "M.classify: `if n > 0 then` (positive branch)",
   [5]   = "M.classify: `return \"positive\"`",
   [30]  = "M.sum: `local total = 0` (function-body first line)",
   [31]  = "M.sum: `for i = 1, #t do`",
   [32]  = "M.sum: loop body `total = total + t[i]`",
   [106] = "M.first_line_local: `local t = cobj.kind`",
   [123] = "M.if_block_first_line: `local cleaned = v`",
}

local hit_failures = 0
for line_nr, desc in pairs(must_be_hit) do
   local hits = sample_data[line_nr] or 0
   if hits > 0 then
      ok("line %d hit %d times — %s", line_nr, hits, desc)
   else
      io.stderr:write(string.format(
         "FAIL: line %d expected to be hit, got 0 — %s\n", line_nr, desc))
      hit_failures = hit_failures + 1
   end
end

if hit_failures > 0 then
   fail("%d lines expected to be hit were not", hit_failures)
end

-- Spot-check: lines that MUST NOT be hit (run_test.lua deliberately
-- skips these branches).
local must_not_be_hit = {
   [9]  = "M.classify: `return \"negative\"` (negative path skipped)",
   [67] = "M.max_of_three: function body (never called)",
   [68] = "M.max_of_three: `if a >= b and a >= c then`",
}

local zero_failures = 0
for line_nr, desc in pairs(must_not_be_hit) do
   local hits = sample_data[line_nr] or 0
   if hits == 0 then
      ok("line %d hit 0 times (as expected) — %s", line_nr, desc)
   else
      io.stderr:write(string.format(
         "FAIL: line %d expected NOT to be hit, got %d — %s\n",
         line_nr, hits, desc))
      zero_failures = zero_failures + 1
   end
end

if zero_failures > 0 then
   fail("%d lines unexpectedly received hits", zero_failures)
end

-- file_included() must have been called at least once (for sample.lua
-- and any other files the hook saw).
if #file_included_calls < 1 then
   fail("file_included was never called; hook is not wired up")
end
ok("file_included called %d times", #file_included_calls)

-- save_stats should NOT be called when tick is false.
if save_stats_calls ~= 0 then
   fail("save_stats called %d times with tick=false; expected 0",
      save_stats_calls)
end
ok("save_stats not called with tick=false (= %d)", save_stats_calls)

print("\n=== E2E line-hook test PASSED ===")
