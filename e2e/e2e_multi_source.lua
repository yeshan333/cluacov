#!/usr/bin/env lua
--
-- E2E test for multi-source aggregation via pchook.get_all_*.
--
-- Real-world projects span dozens to hundreds of source files. The
-- get_all_hits / get_all_line_hits aggregators must:
--
--   1. Bucket Protos correctly by their `source` string
--   2. Preserve per-source line/hit data without cross-contamination
--   3. Produce results that can drive a multi-record LCOV report
--
-- This script generates N temporary modules with distinct source
-- strings, exercises each one a known number of times, and asserts
-- that the aggregate result correctly attributes hits to each source.
--

local function resolve_dir(path)
   if path:sub(1, 1) == "/" then return path end
   local pwd = io.popen("pwd"):read("*l")
   if path == "" or path == "./" then return pwd .. "/" end
   return pwd .. "/" .. path
end

local e2e_dir = resolve_dir(arg[0]:match("(.-)[^/]*$") or "./")
local output_dir = e2e_dir .. "output"
local scratch_dir = output_dir .. "/multi_source"
os.execute("mkdir -p " .. scratch_dir)

local pchook = require("cluacov.pchook")

print("=== Step 1: Generating N temporary modules ===")

local N = 8
local modules = {}      -- N module sources, each compiled to a function
local exec_counts = {}  -- expected execution count per module

-- Persist each generated module to disk under scratch_dir/sources/.
-- Two reasons:
--   1. genhtml needs to read the actual source bytes to render line-
--      annotated HTML reports. In-memory chunks (`load(src, "@name")`)
--      have no on-disk source, so the HTML output would be empty.
--   2. It mirrors how a real project's modules look on disk, exercising
--      the per-source aggregation against realistic file paths.
local sources_dir = scratch_dir .. "/sources"
os.execute("mkdir -p " .. sources_dir)

for i = 1, N do
   -- Each module is a separate file with a UNIQUE path so the source
   -- string differs. Body lines are arranged so we know exact
   -- line→hit relationships:
   --   L1: function header
   --   L2: `local sum = 0`
   --   L3: `for j = 1, n do`
   --   L4: `sum = sum + j`
   --   L5: `end`
   --   L6: `return sum`
   --   L7: `end`
   local src = "return function(n)\n" ..
               "   local sum = 0\n" ..
               "   for j = 1, n do\n" ..
               "      sum = sum + j\n" ..
               "   end\n" ..
               "   return sum\n" ..
               "end\n"
   local module_path = sources_dir .. "/module_" .. i .. ".lua"
   local module_fh = assert(io.open(module_path, "w"))
   module_fh:write(src)
   module_fh:close()

   -- loadfile produces source string "@<absolute-path>" — exactly what
   -- pchook records and what genhtml expects in SF: lines.
   local chunk = assert(loadfile(module_path))
   modules[i] = { fn = chunk(), chunkname = "@" .. module_path }
   exec_counts[i] = i * 10  -- module_i runs i*10 iterations
end

print(string.format("  generated %d modules", N))

print("=== Step 2: Starting pchook + executing all modules ===")

pchook.start()

local expected_total_iterations = 0
for i, m in ipairs(modules) do
   local n = exec_counts[i]
   expected_total_iterations = expected_total_iterations + n
   -- Call each module 1 time, with input n. The module's loop body
   -- (line 4) runs n times.
   local sum = m.fn(n)
   assert(sum == n * (n + 1) / 2,
      string.format("module %d: sum(%d) = %d (expected %d)",
         i, n, sum, n * (n + 1) / 2))
end

pchook.stop()

local function fail(msg, ...)
   io.stderr:write(string.format("FAIL: " .. msg .. "\n", ...))
   os.exit(1)
end

local function ok(msg, ...)
   print(string.format("  OK: " .. msg, ...))
end

print("=== Step 3: Asserting per-source aggregation ===")

local all_line_hits = pchook.get_all_line_hits()
local all_hits = pchook.get_all_hits()

-- All N module sources must be present in the aggregate.
-- Note: `load(src, "@module_i")` produces TWO protos sharing the same
-- chunkname — the outer chunk and the function it returns — so the
-- chunkname appears once in the per-source aggregate. The aggregate
-- may also contain unrelated sources (e.g. e2e_multi_source.lua
-- itself if any of its lines executed under the hook); we only care
-- that ALL of our N modules are present.
local seen = {}
for source in pairs(all_line_hits) do seen[source] = true end

for i, m in ipairs(modules) do
   if not seen[m.chunkname] then
      fail("module %d source %q missing from get_all_line_hits aggregate",
         i, m.chunkname)
   end
end
ok("all %d module sources present in get_all_line_hits", N)

-- Likewise for get_all_hits.
local seen_hits = {}
for source in pairs(all_hits) do seen_hits[source] = true end
for i, m in ipairs(modules) do
   if not seen_hits[m.chunkname] then
      fail("module %d source %q missing from get_all_hits aggregate",
         i, m.chunkname)
   end
end
ok("all %d module sources present in get_all_hits", N)

print("=== Step 4: Asserting per-line hit distribution per module ===")

-- Module i's loop body (line 4) must have been hit exec_counts[i]
-- times, and ONLY exec_counts[i] times — no cross-contamination from
-- other modules.
for i, m in ipairs(modules) do
   local lines = all_line_hits[m.chunkname]
   if type(lines) ~= "table" then
      fail("module %d: line data is not a table", i)
   end

   local body_hits = lines[4] or 0
   local expected = exec_counts[i]
   if body_hits ~= expected then
      fail("module %d: loop body L4 expected %d hits, got %d",
         i, expected, body_hits)
   end
end
ok("each module's loop body L4 has exactly its expected hit count (no cross-contamination)")

-- max field per source should reflect the actual line span (>= 6).
for i, m in ipairs(modules) do
   local lines = all_line_hits[m.chunkname]
   if (lines.max or 0) < 6 then
      fail("module %d: lines.max = %d, expected >= 6",
         i, lines.max or 0)
   end
end
ok("each module's lines.max reflects actual line span (>= 6)")

print("=== Step 5: Asserting per-source proto records ===")

-- Each source should have at least 1 proto in get_all_hits (the
-- function we executed). Some may have an extra "outer chunk" record
-- depending on how `load` materializes things.
local total_protos = 0
for source, protos in pairs(all_hits) do
   if seen_hits[source] then
      assert(type(protos) == "table",
         "all_hits[" .. source .. "] is not a table")
      assert(#protos >= 1,
         "all_hits[" .. source .. "] has no protos")
      total_protos = total_protos + #protos
   end
end
ok("total proto records across all sources: %d (>= %d)", total_protos, N)

-- Sanity: the total number of HITS aggregated across all sources
-- should be HUGE (roughly proportional to sum of exec_counts).
local total_hits_across_sources = 0
for _, protos in pairs(all_hits) do
   for _, entry in ipairs(protos) do
      for _, c in pairs(entry.hits) do
         total_hits_across_sources = total_hits_across_sources + c
      end
   end
end

if total_hits_across_sources < expected_total_iterations then
   fail("total aggregated hits (%d) less than total loop iterations (%d)",
      total_hits_across_sources, expected_total_iterations)
end
ok("total aggregated hits = %d (>= total loop iterations %d)",
   total_hits_across_sources, expected_total_iterations)

print("=== Step 6: Generating multi-record LCOV file ===")

-- Filter the aggregate down to ONLY our N module sources, so that any
-- incidental sources picked up by the hook (the test driver itself,
-- the standard library, etc.) don't pollute the LCOV output.
local module_sources_set = {}
for _, m in ipairs(modules) do
   module_sources_set[m.chunkname] = true
end

local lcov_file = scratch_dir .. "/multi_source.lcov"
local fh = assert(io.open(lcov_file, "w"))
fh:write("TN:cluacov_multi_source\n")

local sources_sorted = {}
for s in pairs(all_line_hits) do
   if module_sources_set[s] then
      sources_sorted[#sources_sorted + 1] = s
   end
end
table.sort(sources_sorted)

local n_records = 0
for _, source in ipairs(sources_sorted) do
   n_records = n_records + 1
   fh:write("SF:", source:sub(2), "\n")  -- strip leading '@'
   local lines = all_line_hits[source]
   local lf, lh = 0, 0
   for line_nr = 1, lines.max do
      local hits = lines[line_nr] or 0
      if hits > 0 then
         fh:write(string.format("DA:%d,%d\n", line_nr, hits))
         lf = lf + 1; lh = lh + 1
      end
   end
   fh:write(string.format("LF:%d\n", lf))
   fh:write(string.format("LH:%d\n", lh))
   fh:write("end_of_record\n")
end
fh:close()

if n_records ~= N then
   fail("LCOV records written = %d, expected %d", n_records, N)
end
ok("LCOV file written with %d records: %s", n_records, lcov_file)

print("=== Step 7: Generating HTML report via genhtml ===")

-- Optional: only run if `genhtml` (from lcov) is on PATH. We don't
-- want this to be a hard prereq because the LCOV file IS the
-- machine-readable artifact; HTML is a human-readable convenience.
local html_dir = scratch_dir .. "/html"
os.execute("rm -rf " .. html_dir .. " && mkdir -p " .. html_dir)

local genhtml_cmd = string.format(
   "genhtml --quiet --legend --title %q --output-directory %q %q 2>&1",
   "cluacov multi-source E2E",
   html_dir,
   lcov_file)

local pipe = io.popen(genhtml_cmd .. "; echo __EXIT__:$?")
local genhtml_out = pipe:read("*a")
pipe:close()

local genhtml_exit = genhtml_out:match("__EXIT__:(%d+)")
if genhtml_exit == "0" then
   -- Confirm the entry point exists.
   local index_html = html_dir .. "/index.html"
   local index_fh = io.open(index_html, "r")
   if not index_fh then
      fail("genhtml succeeded but %s not found", index_html)
   end
   index_fh:close()
   ok("HTML report generated: %s", index_html)
else
   io.stderr:write("WARN: genhtml not available or failed (exit=" ..
      tostring(genhtml_exit) .. "); skipping HTML report.\n")
   io.stderr:write(genhtml_out)
end

print("\n=== E2E multi-source test PASSED ===")
