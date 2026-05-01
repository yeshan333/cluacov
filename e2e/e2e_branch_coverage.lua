#!/usr/bin/env lua
--
-- E2E branch coverage test:
--   1. Run sample code under luacov to collect line hits
--   2. Use deepbranches to discover branch sites
--   3. Cross-reference to compute branch coverage
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
local stats_file  = output_dir .. "/luacov.stats.out"
local lcov_file   = output_dir .. "/coverage.lcov"
local html_dir    = output_dir .. "/html"
local sample_file = e2e_dir .. "sample.lua"

os.execute("mkdir -p " .. output_dir)

-- Step 1: Run the test under luacov

print("=== Step 1: Running test under luacov ===")

local luacov_cfg = output_dir .. "/.luacov"
local cfg_fh = assert(io.open(luacov_cfg, "w"))
cfg_fh:write(string.format([[
statsfile = %q
include = { "sample$" }
]], stats_file))
cfg_fh:close()

os.remove(stats_file)

local run_cmd = string.format(
   "cd %s && LUACOV_CONFIG=%s lua -lluacov run_test.lua",
   e2e_dir, luacov_cfg
)
local ok = os.execute(run_cmd)
if not ok then
   io.stderr:write("ERROR: test run failed\n")
   os.exit(1)
end

-- Step 2: Load stats and discover branches

print("\n=== Step 2: Loading stats and discovering branches ===")

local stats_mod = require("luacov.stats")
local data = stats_mod.load(stats_file)

if not data then
   io.stderr:write("ERROR: could not load stats from " .. stats_file .. "\n")
   os.exit(1)
end

local sample_key
for name, _ in pairs(data) do
   if name:match("sample") then
      sample_key = name
      break
   end
end

if not sample_key then
   io.stderr:write("ERROR: no stats for sample.lua found\n")
   for k in pairs(data) do
      io.stderr:write("  found: " .. k .. "\n")
   end
   os.exit(1)
end

local file_stats = data[sample_key]
print(string.format("Loaded stats for %s (max line: %d)", sample_key, file_stats.max))

-- Load sample.lua and get branches
local sample_src = assert(io.open(sample_file)):read("*a")
local sample_func = assert(load(sample_src, "@" .. sample_file))

local deepbranches = require("cluacov.deepbranches")
local branches = deepbranches.get(sample_func)

print(string.format("Discovered %d branch sites", #branches))

-- Step 3: Filter branches and compute coverage
--
-- Lua's debug hook fires per-LINE, not per-instruction. For multi-branch
-- lines (compound conditions, loop entry+backedge), we only report branches
-- whose BOTH targets are on different lines (genuinely distinguishable),
-- and deduplicate by target-line pair to avoid redundant entries.

print("\n=== Step 3: Filtering branches ===")

local line_counts = {}
for _, branch in ipairs(branches) do
   line_counts[branch.line] = (line_counts[branch.line] or 0) + 1
end

local branch_data = {}
local skipped = 0
local seen_target_pairs = {}

local function add_branch(branch)
   local target_details = {}
   local targets_hit = 0
   for _, target in ipairs(branch.targets) do
      local hits = file_stats[target.line] or 0
      local hit = hits > 0
      if hit then targets_hit = targets_hit + 1 end
      target_details[#target_details + 1] = {
         line = target.line, pc = target.pc, hits = hits, hit = hit,
      }
   end

   local status
   if targets_hit == #target_details then
      status = "covered"
   elseif targets_hit > 0 then
      status = "partial"
   else
      status = "uncovered"
   end

   branch_data[#branch_data + 1] = {
      line = branch.line, kind = branch.kind,
      targets = target_details, status = status,
   }
end

for _, branch in ipairs(branches) do
   if line_counts[branch.line] == 1 then
      add_branch(branch)
   else
      local t1 = branch.targets[1].line
      local t2 = branch.targets[2].line
      if t1 ~= branch.line and t2 ~= branch.line then
         local key = branch.line .. ":" .. t1 .. ":" .. t2
         if not seen_target_pairs[key] then
            seen_target_pairs[key] = true
            add_branch(branch)
         else
            skipped = skipped + 1
         end
      else
         skipped = skipped + 1
      end
   end
end

print(string.format("  %d raw branches, %d skipped, %d reportable",
   #branches, skipped, #branch_data))

for i, b in ipairs(branch_data) do
   print(string.format(
      "  Branch #%d at line %d (%s): %s [targets: %s]",
      i, b.line, b.kind, b.status,
      table.concat((function()
         local parts = {}
         for _, t in ipairs(b.targets) do
            parts[#parts + 1] = string.format("L%d=%d", t.line, t.hits)
         end
         return parts
      end)(), ", ")
   ))
end

local total_branches = #branch_data
local covered, partial, uncovered = 0, 0, 0
for _, b in ipairs(branch_data) do
   if b.status == "covered" then covered = covered + 1
   elseif b.status == "partial" then partial = partial + 1
   else uncovered = uncovered + 1 end
end

print(string.format(
   "\nBranch summary: %d reportable, %d covered, %d partial, %d uncovered (%.1f%%)",
   total_branches, covered, partial, uncovered,
   total_branches > 0 and (covered / total_branches * 100) or 0
))

-- Step 4: Generate LCOV data

print("\n=== Step 4: Generating LCOV data ===")

local lcov_fh = assert(io.open(lcov_file, "w"))
lcov_fh:write("TN:cluacov-e2e\n")
lcov_fh:write("SF:" .. sample_file .. "\n")

-- Line coverage: FN/FNDA/DA records
local source_lines = {}
for line in io.lines(sample_file) do
   source_lines[#source_lines + 1] = line
end

-- Discover functions from source for FN records
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
   local hits = file_stats[fd.line] or 0
   lcov_fh:write(string.format("FNDA:%d,%s\n", hits, fd.name))
   if hits > 0 then fns_hit = fns_hit + 1 end
end
lcov_fh:write(string.format("FNH:%d\n", fns_hit))

-- Branch coverage: BRDA records (single-condition branches only)
-- Format: BRDA:line,block,branch,taken
local branch_block_id = 0
local branches_found = 0
local branches_hit = 0

for _, b in ipairs(branch_data) do
   branches_found = branches_found + #b.targets
   for target_idx, t in ipairs(b.targets) do
      local taken = t.hits > 0 and t.hits or 0
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

for line_nr = 1, file_stats.max do
   if active_lines[line_nr] then
      local hits = file_stats[line_nr] or 0
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
   "genhtml %s --output-directory %s --title 'cluacov Branch Coverage E2E' "
   .. "--legend --branch-coverage 2>&1",
   lcov_file, html_dir
)
local genhtml_result = io.popen(genhtml_cmd)
local genhtml_output = genhtml_result:read("*a")
genhtml_result:close()
print(genhtml_output)

-- Verify output exists
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

assert_eq("reportable branches found", #branch_data > 0, true)
assert_eq("some branches partially covered", partial > 0, true)
assert_eq("some branches fully covered", covered > 0, true)
assert_eq("some branches uncovered", uncovered > 0, true)
assert_eq("compound branches skipped", skipped > 0, true)
assert_eq("LCOV file exists", io.open(lcov_file) ~= nil, true)

print("\n=== E2E test PASSED ===")
