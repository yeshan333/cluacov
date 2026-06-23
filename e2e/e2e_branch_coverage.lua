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

-- Extract a UNIQUE display name for each function definition. We must
-- handle all of these forms appearing in sample.lua:
--   function M.foo(...)         → "foo"            (module method)
--   function M:bar(...)         → "bar"            (rare; reserved for future)
--   function Point.new(...)     → "Point.new"      (class constructor)
--   function Point:translate(...) → "Point:translate"  (instance method)
--   function is_even(...)       → "is_even"        (module-local forward decl)
-- The naive `^function%s+%S-%.([%w_]+)` regex collapsed `Point.new`,
-- `Point:translate`, and `Point:length` all to "Point", which made
-- genhtml choke with "duplicate function 'Point'". Disambiguate by
-- keeping the table-prefix when it is anything OTHER than the module
-- table `M`.
local func_defs = {}
for line_nr, line in ipairs(source_lines) do
   -- Try table-method forms first: `function Foo.bar(...)` / `function Foo:bar(...)`
   local table_name, sep, method_name =
      line:match("^function%s+([%w_]+)([%.:])([%w_]+)")
   local fname
   if table_name then
      if table_name == "M" then
         -- Module table — drop the "M." prefix so the report stays clean.
         fname = method_name
      else
         -- Class-like table — keep the prefix so methods don't collide.
         fname = table_name .. sep .. method_name
      end
   else
      -- Bare top-level form: `function name(...)`
      fname = line:match("^function%s+([%w_]+)")
   end
   if fname then
      func_defs[#func_defs + 1] = { line = line_nr, name = fname }
   end
end

for _, fd in ipairs(func_defs) do
   lcov_fh:write(string.format("FN:%d,%s\n", fd.line, fd.name))
end

lcov_fh:write(string.format("FNF:%d\n", #func_defs))

-- Build lookup: linedefined -> call count from proto body hits.
-- A function is only counted as "called" when its Proto's body
-- was actually entered, not merely when the OP_CLOSURE instruction
-- at the definition site executed.
-- Normal functions: hits[1]; vararg functions (OP_VARARGPREP at PC 0
-- skips the count hook): fall back to hits[2].
local proto_hits = pchook.get_hits(sample_func)
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

local fns_hit = 0
for _, fd in ipairs(func_defs) do
   local hits = fn_call_counts[fd.line] or 0
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
-- Zero out definition lines of uncalled functions: the hit there is
-- merely OP_CLOSURE in the parent chunk, not an actual call.
local uncalled_def_lines = {}
for _, fd in ipairs(func_defs) do
   if not fn_call_counts[fd.line] then
      uncalled_def_lines[fd.line] = true
   end
end

local lines_found = 0
local lines_hit = 0

local deepactivelines = require("cluacov.deepactivelines")
local active_lines = deepactivelines.get(sample_func)

for line_nr = 1, line_hits.max or 0 do
   if active_lines[line_nr] then
      local hits = line_hits[line_nr] or 0
      if uncalled_def_lines[line_nr] then hits = 0 end
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

-- ---------------------------------------------------------------------------
-- Regression: savedpc off-by-one in collect_line_hits_recursive.
--
-- Before the fix, the very first executable line of a function body, and
-- the first executable line inside any if-block, both reported hits = 0
-- in get_line_hits / branchcov.get_line_hits, even when the function/block
-- was clearly executed (the next line absorbed the missing hits).
--
-- These four assertions lock in the fix end-to-end (branchcov -> LCOV).
-- They MUST stay in sync with the line numbers in e2e/sample.lua:
--
--   L30  `local total = 0`         (M.sum, function-body first line)
--   L31  `for i = 1, #t do`        (M.sum, line that holds the loop init)
--   L106 `local t = cobj.kind`     (M.first_line_local, function-body first)
--   L123 `local cleaned = v`       (M.if_block_first_line, if-block first)
-- ---------------------------------------------------------------------------

local function line_hit_count(line_nr)
   return line_hits[line_nr] or 0
end

assert_eq("regression: M.sum first line `local total = 0` (L30) hit",
   line_hit_count(30) > 0, true)
assert_eq("regression: M.first_line_local body first line `local t = cobj.kind` (L106) hit",
   line_hit_count(106) > 0, true)
assert_eq("regression: M.if_block_first_line if-block first line `local cleaned = v` (L123) hit",
   line_hit_count(123) >= 3, true)

-- Stronger guard: in the buggy version, hits were *shifted* by one source
-- line. The line right after the function-body first line ended up with
-- the hit count that should have belonged to the first line. Verify the
-- distribution is plausible (the first line was hit at least as many
-- times as a sentinel line we know is conditionally executed).
assert_eq("regression: M.first_line_local body first line >= conditional return line",
   line_hit_count(106) >= line_hit_count(108), true)

-- ---------------------------------------------------------------------------
-- goto scenario assertions
--
-- goto_filter (M.goto_filter): `if v < 0 then goto skip end`
--   Input {-1, 2, -3, 4, 5} exercises BOTH branches → "covered".
--   L394 is the `if v < 0` conditional.
--
-- goto_first_match (M.goto_first_match): `if v > 0 then ... goto found end`
--   Input {-1, -2, -3}: no positive found → loop exits, "goto done" path taken.
--   The "goto found" branch target is never reached → "partial".
--   L410 is the `if v > 0` conditional.
--
-- goto_early_return (M.goto_early_return): `if err then goto bail end`
--   Never called from run_test.lua → fully "uncovered".
--   L425 is the `if err then` conditional.
-- ---------------------------------------------------------------------------

local goto_filter_branch = nil
local goto_first_match_branch = nil
local goto_early_return_branch = nil
for _, b in ipairs(result.branches) do
   if b.line == 394 and b.kind == "test" then
      goto_filter_branch = b
   end
   if b.line == 410 and b.kind == "test" then
      goto_first_match_branch = b
   end
   if b.line == 425 and b.kind == "test" then
      goto_early_return_branch = b
   end
end

assert_eq("goto_filter: test branch found at L394",
   goto_filter_branch ~= nil, true)
assert_eq("goto_filter: branch status is covered",
   goto_filter_branch and goto_filter_branch.status, "covered")
assert_eq("goto_filter: has 2 targets",
   goto_filter_branch and #goto_filter_branch.targets, 2)
local gf_hits = {}
if goto_filter_branch then
   for _, t in ipairs(goto_filter_branch.targets) do
      gf_hits[#gf_hits + 1] = t.hits
   end
end
assert_eq("goto_filter: all targets hit",
   (gf_hits[1] or 0) > 0 and (gf_hits[2] or 0) > 0, true)

assert_eq("goto_first_match: test branch found at L410",
   goto_first_match_branch ~= nil, true)
assert_eq("goto_first_match: branch status is partial",
   goto_first_match_branch and goto_first_match_branch.status, "partial")
assert_eq("goto_first_match: has 2 targets",
   goto_first_match_branch and #goto_first_match_branch.targets, 2)
local gfm_hits = {}
if goto_first_match_branch then
   for _, t in ipairs(goto_first_match_branch.targets) do
      gfm_hits[#gfm_hits + 1] = t.hits
   end
end
local gfm_any_hit = (gfm_hits[1] or 0) + (gfm_hits[2] or 0) > 0
local gfm_any_miss = (gfm_hits[1] or 0) == 0 or (gfm_hits[2] or 0) == 0
assert_eq("goto_first_match: at least one target hit", gfm_any_hit, true)
assert_eq("goto_first_match: at least one target not hit (partial)", gfm_any_miss, true)

assert_eq("goto_early_return: test branch found at L425",
   goto_early_return_branch ~= nil, true)
assert_eq("goto_early_return: branch status is uncovered",
   goto_early_return_branch and goto_early_return_branch.status, "uncovered")
assert_eq("goto_early_return: has 2 targets",
   goto_early_return_branch and #goto_early_return_branch.targets, 2)
local ger_hits = {}
if goto_early_return_branch then
   for _, t in ipairs(goto_early_return_branch.targets) do
      ger_hits[#ger_hits + 1] = t.hits
   end
end
assert_eq("goto_early_return: all targets zero hit",
   (ger_hits[1] or 0) == 0 and (ger_hits[2] or 0) == 0, true)

print("\n=== E2E test PASSED ===")
