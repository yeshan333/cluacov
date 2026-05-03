#!/usr/bin/env lua
--
-- E2E function coverage test:
--   Verifies that LCOV FNDA/FNH correctly reports function-level coverage.
--
--   The bug: when a module is `require`d, the OP_CLOSURE instruction that
--   *defines* a function runs in the parent chunk, giving the definition
--   line a hit count > 0. The old code used this line hit as the FNDA
--   value, making every defined function appear "called" even if its body
--   was never entered. The fix uses per-Proto body hits (hits[1]) to
--   determine actual call counts.
--
--   This test creates a sample module with 5 functions, calls only 3 of
--   them, and asserts that:
--     * Called functions have FNDA > 0
--     * Uncalled functions have FNDA:0
--     * FNH reflects only the actually-called count
--     * Multiple calls produce proportional FNDA values
--

local function resolve_dir(path)
   if path:sub(1, 1) == "/" then return path end
   local pwd = io.popen("pwd"):read("*l")
   if path == "" or path == "./" then return pwd .. "/" end
   return pwd .. "/" .. path
end

local e2e_dir = resolve_dir(arg[0]:match("(.-)[^/]*$") or "./")
local output_dir = e2e_dir .. "output"
local scratch_dir = output_dir .. "/function_coverage"
os.execute("mkdir -p " .. scratch_dir)

local pchook = require("cluacov.pchook")

local function fail(msg, ...)
   io.stderr:write(string.format("FAIL: " .. msg .. "\n", ...))
   os.exit(1)
end

local function ok(msg, ...)
   print(string.format("  OK: " .. msg, ...))
end

-- Step 1: Write a sample module with 5 functions

print("=== Step 1: Generating sample module ===")

local sample_path = scratch_dir .. "/fn_sample.lua"
local sample_fh = assert(io.open(sample_path, "w"))
sample_fh:write([[
local M = {}
function M.called_once(x)
   return x + 1
end
function M.called_three_times(x)
   return x * 2
end
function M.uncalled_alpha(x)
   return x - 1
end
function M.uncalled_beta(a, b)
   if a > b then
      return a
   end
   return b
end
function M.called_five_times(t)
   local sum = 0
   for i = 1, #t do
      sum = sum + t[i]
   end
   return sum
end
function M.vararg_called_twice(...)
   local n = select("#", ...)
   local sum = 0
   for i = 1, n do
      sum = sum + select(i, ...)
   end
   return sum
end
return M
]])
sample_fh:close()

-- Step 2: Load module and exercise it under pchook

print("=== Step 2: Loading and exercising module under pchook ===")

local sample_chunk = assert(loadfile(sample_path))

pchook.start()

local M = sample_chunk()

-- called_once: 1 call
assert(M.called_once(10) == 11)

-- called_three_times: 3 calls
for i = 1, 3 do
   assert(M.called_three_times(i) == i * 2)
end

-- uncalled_alpha: NOT called
-- uncalled_beta: NOT called

-- called_five_times: 5 calls
for i = 1, 5 do
   assert(M.called_five_times({i, i + 1}) == 2 * i + 1)
end

-- vararg_called_twice: 2 calls (exercises OP_VARARGPREP edge case)
assert(M.vararg_called_twice(10, 20) == 30)
assert(M.vararg_called_twice(1, 2, 3) == 6)

pchook.stop()

-- Step 3: Extract proto-level hits and build FNDA data

print("=== Step 3: Analyzing function coverage ===")

local proto_hits = pchook.get_hits(sample_chunk)

-- Build fn_call_counts from proto body hits (same logic as runner.lua).
-- Normal functions: hits[1]; vararg functions (OP_VARARGPREP at PC 0
-- skips the count hook): fall back to hits[2].
local fn_call_counts = {}
for _, entry in ipairs(proto_hits) do
   local ld = entry.linedefined
   if ld > 0 then
      local count = entry.hits[1] or entry.hits[2] or 0
      if count > 0 then
         fn_call_counts[ld] = (fn_call_counts[ld] or 0) + count
      end
   end
end

-- Parse source to extract function definitions (same regex as runner.lua)
local source_lines = {}
for line in io.lines(sample_path) do
   source_lines[#source_lines + 1] = line
end

local func_defs = {}
for line_nr, line in ipairs(source_lines) do
   local fname = line:match("^function%s+%S-%.([%w_]+)")
      or line:match("^function%s+([%w_]+)")
      or line:match("^local%s+function%s+([%w_]+)")
   if fname then
      func_defs[#func_defs + 1] = { line = line_nr, name = fname }
   end
end

print(string.format("  Found %d function definitions", #func_defs))

-- Step 4: Verify function coverage correctness

print("=== Step 4: Verifying FNDA correctness ===")

-- Expected results
local expected = {
   called_once          = { called = true,  min_hits = 1 },
   called_three_times   = { called = true,  min_hits = 3 },
   uncalled_alpha       = { called = false, min_hits = 0 },
   uncalled_beta        = { called = false, min_hits = 0 },
   called_five_times    = { called = true,  min_hits = 5 },
   vararg_called_twice  = { called = true,  min_hits = 2 },
}

if #func_defs ~= 6 then
   fail("expected 6 function definitions, got %d", #func_defs)
end
ok("found exactly 6 function definitions")

local fns_hit = 0
for _, fd in ipairs(func_defs) do
   local hits = fn_call_counts[fd.line] or 0
   local exp = expected[fd.name]
   if not exp then
      fail("unexpected function %q at line %d", fd.name, fd.line)
   end

   if exp.called and hits == 0 then
      fail("function %q was called but FNDA = 0", fd.name)
   end
   if not exp.called and hits > 0 then
      fail("function %q was NOT called but FNDA = %d (should be 0)", fd.name, hits)
   end
   if hits < exp.min_hits then
      fail("function %q expected FNDA >= %d, got %d",
         fd.name, exp.min_hits, hits)
   end

   if hits > 0 then fns_hit = fns_hit + 1 end
   ok("FNDA:%d,%s %s", hits, fd.name,
      exp.called and "(correctly called)" or "(correctly uncalled)")
end

if fns_hit ~= 4 then
   fail("FNH should be 4 (4 called functions), got %d", fns_hit)
end
ok("FNH = %d (exactly the 4 called functions)", fns_hit)

-- Step 5: Generate LCOV file with correct function coverage

print("=== Step 5: Generating LCOV file ===")

local line_hits = pchook.get_line_hits(sample_chunk)
local deepactivelines = require("cluacov.deepactivelines")
local active_lines = deepactivelines.get(sample_chunk)

local lcov_file = scratch_dir .. "/function_coverage.lcov"
local lcov_fh = assert(io.open(lcov_file, "w"))
lcov_fh:write("TN:cluacov_function_coverage\n")
lcov_fh:write("SF:" .. sample_path .. "\n")

-- FN records
for _, fd in ipairs(func_defs) do
   lcov_fh:write(string.format("FN:%d,%s\n", fd.line, fd.name))
end
lcov_fh:write(string.format("FNF:%d\n", #func_defs))

-- FNDA records (using proto body hits, not definition line hits)
local lcov_fns_hit = 0
for _, fd in ipairs(func_defs) do
   local hits = fn_call_counts[fd.line] or 0
   lcov_fh:write(string.format("FNDA:%d,%s\n", hits, fd.name))
   if hits > 0 then lcov_fns_hit = lcov_fns_hit + 1 end
end
lcov_fh:write(string.format("FNH:%d\n", lcov_fns_hit))

-- DA records
-- Zero out definition lines of uncalled functions (OP_CLOSURE artifact).
local uncalled_def_lines = {}
for _, fd in ipairs(func_defs) do
   if not fn_call_counts[fd.line] then
      uncalled_def_lines[fd.line] = true
   end
end

local lf, lh = 0, 0
for line_nr = 1, line_hits.max or 0 do
   if active_lines[line_nr] then
      local hits = line_hits[line_nr] or 0
      if uncalled_def_lines[line_nr] then hits = 0 end
      lcov_fh:write(string.format("DA:%d,%d\n", line_nr, hits))
      lf = lf + 1
      if hits > 0 then lh = lh + 1 end
   end
end
lcov_fh:write(string.format("LF:%d\n", lf))
lcov_fh:write(string.format("LH:%d\n", lh))
lcov_fh:write("end_of_record\n")
lcov_fh:close()

ok("LCOV file written: %s", lcov_file)

-- Step 6: Parse LCOV back and verify FNDA values

print("=== Step 6: Verifying LCOV file contents ===")

local lcov_content = {}
for line in io.lines(lcov_file) do
   lcov_content[#lcov_content + 1] = line
end

local lcov_fnda = {}
local lcov_fnf, lcov_fnh
for _, line in ipairs(lcov_content) do
   local count, name = line:match("^FNDA:(%d+),(%S+)$")
   if count then
      lcov_fnda[name] = tonumber(count)
   end
   local fnf_val = line:match("^FNF:(%d+)$")
   if fnf_val then lcov_fnf = tonumber(fnf_val) end
   local fnh_val = line:match("^FNH:(%d+)$")
   if fnh_val then lcov_fnh = tonumber(fnh_val) end
end

if lcov_fnf ~= 6 then
   fail("LCOV FNF should be 6, got %s", tostring(lcov_fnf))
end
ok("LCOV FNF = 6")

if lcov_fnh ~= 4 then
   fail("LCOV FNH should be 4, got %s", tostring(lcov_fnh))
end
ok("LCOV FNH = 4")

for name, exp in pairs(expected) do
   local fnda = lcov_fnda[name]
   if fnda == nil then
      fail("LCOV missing FNDA for %q", name)
   end
   if exp.called and fnda == 0 then
      fail("LCOV FNDA:%d,%s — function was called, expected > 0", fnda, name)
   end
   if not exp.called and fnda ~= 0 then
      fail("LCOV FNDA:%d,%s — function was NOT called, expected 0", fnda, name)
   end
   ok("LCOV FNDA:%d,%s %s", fnda, name,
      exp.called and "(correct: called)" or "(correct: uncalled)")
end

print("\n=== E2E function coverage test PASSED ===")
