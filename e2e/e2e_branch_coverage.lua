#!/usr/bin/env lua
--
-- E2E branch coverage test (per-PC instruction-level):
--   1. Load sample code, start PC-level hook
--   2. Run test code under the hook
--   3. Analyze branch coverage with branchcov
--   4. Generate LCOV data with branch records
--   5. Generate HTML report via genhtml
--

local function resolve_dir(path)
   if path:sub(1, 1) == "/" then return path end
   local pwd = io.popen("pwd"):read("*l")
   if path == "" or path == "./" then return pwd .. "/" end
   return pwd .. "/" .. path
end

local e2e_dir = resolve_dir(arg[0]:match("(.-)[^/]*$") or "./")

local output_dir  = e2e_dir .. "output"
local lcov_file   = output_dir .. "/coverage.lcov"
local html_dir    = output_dir .. "/html"
local sample_file = e2e_dir .. "sample.lua"
local run_test_file = e2e_dir .. "run_test.lua"

os.execute("mkdir -p " .. output_dir)

-- Step 1: Load sample, execute it, and start PC hook

print("=== Step 1: Loading sample and starting PC hook ===")

package.path = e2e_dir .. "?.lua;" .. package.path

local sample_func = assert(loadfile(sample_file))

local pchook = require("cluacov.pchook")
pchook.start()

local sample_module = sample_func()
package.loaded["sample"] = sample_module

-- Step 2: Run the test (under PC hook)

print("\n=== Step 2: Running test under PC hook ===")

local run_func = assert(loadfile(run_test_file))
run_func()

pchook.stop()

-- Step 3: Analyze branch coverage with branchcov

print("\n=== Step 3: Analyzing branch coverage (per-PC) ===")

local branchcov = require("cluacov.branchcov")
local result = branchcov.analyze(sample_func)

print(string.format("Discovered %d branch sites, %d branch targets, %d hit",
   #result.branches, result.total, result.hit))

local covered, partial, uncovered = 0, 0, 0
for _, b in ipairs(result.branches) do
   if b.status == "covered" then covered = covered + 1
   elseif b.status == "partial" then partial = partial + 1
   else uncovered = uncovered + 1 end
end

for i, b in ipairs(result.branches) do
   print(string.format(
      "  Branch #%d at line %d (pc=%d, %s): %s [targets: %s]",
      i, b.line, b.pc, b.kind, b.status,
      table.concat((function()
         local parts = {}
         for _, t in ipairs(b.targets) do
            parts[#parts + 1] = string.format("pc%d(L%d)=%d", t.pc, t.line, t.hits)
         end
         return parts
      end)(), ", ")
   ))
end

print(string.format(
   "\nBranch summary: %d sites, %d covered, %d partial, %d uncovered",
   #result.branches, covered, partial, uncovered))
print(string.format(
   "Branch targets: %d total, %d hit (%.1f%%)",
   result.total, result.hit,
   result.total > 0 and (result.hit / result.total * 100) or 0))

-- Step 4: Generate LCOV data

print("\n=== Step 4: Generating LCOV data ===")

local line_hits = branchcov.get_line_hits(sample_func)

local lcov_fh = assert(io.open(lcov_file, "w"))
lcov_fh:write("TN:cluacov-e2e\n")
lcov_fh:write("SF:" .. sample_file .. "\n")

-- Function records
local source_lines = {}
for line in io.lines(sample_file) do
   source_lines[#source_lines + 1] = line
end

local func_defs = {}
for line_nr, line in ipairs(source_lines) do
   local fname = line:match("^function%s+%S-%.([%w_]+)")
      or line:match("^function%s+([%w_]+)")
   if fname then
      func_defs[#func_defs + 1] = { line = line_nr, name = fname }
   end
end

for _, fd in ipairs(func_defs) do
   lcov_fh:write(string.format("FN:%d,%s\n", fd.line, fd.name))
end

lcov_fh:write(string.format("FNF:%d\n", #func_defs))

local fns_hit = 0
for _, fd in ipairs(func_defs) do
   local hits = line_hits[fd.line] or 0
   lcov_fh:write(string.format("FNDA:%d,%s\n", hits, fd.name))
   if hits > 0 then fns_hit = fns_hit + 1 end
end
lcov_fh:write(string.format("FNH:%d\n", fns_hit))

-- Branch coverage: BRDA records from per-PC analysis
local branch_block_id = 0
local branches_found = 0
local branches_hit = 0

for _, b in ipairs(result.branches) do
   branches_found = branches_found + #b.targets
   for target_idx, t in ipairs(b.targets) do
      local taken = t.hits
      lcov_fh:write(string.format("BRDA:%d,%d,%d,%s\n",
         b.line, branch_block_id, target_idx - 1,
         taken > 0 and tostring(taken) or "-"))
      if taken > 0 then branches_hit = branches_hit + 1 end
   end
   branch_block_id = branch_block_id + 1
end

lcov_fh:write(string.format("BRF:%d\n", branches_found))
lcov_fh:write(string.format("BRH:%d\n", branches_hit))

-- Line coverage: DA records
local lines_found = 0
local lines_hit = 0

local deepactivelines = require("cluacov.deepactivelines")
local active_lines = deepactivelines.get(sample_func)

for line_nr = 1, line_hits.max or 0 do
   if active_lines[line_nr] then
      local hits = line_hits[line_nr] or 0
      lcov_fh:write(string.format("DA:%d,%d\n", line_nr, hits))
      lines_found = lines_found + 1
      if hits > 0 then lines_hit = lines_hit + 1 end
   end
end

lcov_fh:write(string.format("LF:%d\n", lines_found))
lcov_fh:write(string.format("LH:%d\n", lines_hit))
lcov_fh:write("end_of_record\n")
lcov_fh:close()

print("LCOV data written to: " .. lcov_file)

-- Step 5: Generate HTML report

print("\n=== Step 5: Generating HTML report ===")

os.execute("rm -rf " .. html_dir)

local genhtml_cmd = string.format(
   "genhtml %s --output-directory %s --title 'cluacov Branch Coverage E2E (per-PC)' "
   .. "--legend --branch-coverage 2>&1",
   lcov_file, html_dir
)
local genhtml_result = io.popen(genhtml_cmd)
local genhtml_output = genhtml_result:read("*a")
genhtml_result:close()
print(genhtml_output)

local index_html = html_dir .. "/index.html"
local fh = io.open(index_html, "r")
if fh then
   fh:close()
   print("HTML report generated at: " .. index_html)
else
   io.stderr:write("WARNING: HTML report generation may have failed\n")
end

-- Step 6: Verification assertions

print("\n=== Step 6: Verification ===")

local function assert_eq(desc, got, expected)
   if got ~= expected then
      io.stderr:write(string.format("FAIL: %s: expected %s, got %s\n",
         desc, tostring(expected), tostring(got)))
      os.exit(1)
   end
   print(string.format("  OK: %s = %s", desc, tostring(got)))
end

assert_eq("branch sites found", #result.branches > 0, true)
assert_eq("some branches partially covered", partial > 0, true)
assert_eq("some branches fully covered", covered > 0, true)
assert_eq("branch targets > branch sites",
   result.total > #result.branches, true)
assert_eq("LCOV file exists", io.open(lcov_file) ~= nil, true)

-- Verify compound conditions produce multiple branch sites
local line_76_count = 0
for _, b in ipairs(result.branches) do
   if b.line == 76 then line_76_count = line_76_count + 1 end
end
assert_eq("any_truthy (or): 3 branch sites on line 76", line_76_count, 3)

local line_84_count = 0
for _, b in ipairs(result.branches) do
   if b.line == 84 then line_84_count = line_84_count + 1 end
end
assert_eq("all_truthy (and): 3 branch sites on line 84", line_84_count, 3)

print("\n=== E2E test PASSED ===")
