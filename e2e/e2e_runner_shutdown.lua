#!/usr/bin/env lua
--
-- E2E regression test for the SIGSEGV-on-__gc-finalizer bug.
--
-- See docs/bugs/2025-05-segv-on-gc-finalizer-with-pchook.md for the
-- full root-cause analysis. The TL;DR:
--
--   `cluacov.runner` registers a `__gc` finalizer that calls
--   `pchook.stop()` + writes lcov/luacov.stats.out at process teardown.
--   The finalizer fires from inside `luaC_freeallobjects`, AFTER all
--   Proto* objects have already been freed. The original pchook stored
--   data keyed by Proto* and dereferenced it at report time → use-after
--   -free → SIGBUS / SIGSEGV at process exit.
--
-- The fix materializes all Proto metadata into Lua-managed tables at
-- write time. This script locks the fix in by spawning a child process
-- that does the minimal repro and asserting that it exits cleanly:
--
--   1. Process exits with code 0 (NOT 139 = SIGSEGV nor 138 = SIGBUS)
--   2. Process produces a non-empty `luacov.stats.out`
--   3. Process produces a non-empty `lcov.info`
--   4. The lcov.info contains `SF:` records for sample.lua
--
-- The child intentionally does NOT call `os.exit()` — it must let the
-- main chunk return normally, which is the exact code path that
-- triggered the original crash.
--

local function resolve_dir(path)
   if path:sub(1, 1) == "/" then return path end
   local pwd = io.popen("pwd"):read("*l")
   if path == "" or path == "./" then return pwd .. "/" end
   return pwd .. "/" .. path
end

local e2e_dir = resolve_dir(arg[0]:match("(.-)[^/]*$") or "./")
local output_dir = e2e_dir .. "output"
os.execute("mkdir -p " .. output_dir)

-- Spawn-side scratch dir: keeps lcov.info / luacov.stats.out isolated
-- from other e2e scripts so we can assert on file contents reliably.
local scratch_dir = output_dir .. "/runner_shutdown"
os.execute("rm -rf " .. scratch_dir .. " && mkdir -p " .. scratch_dir)

local sample_file = e2e_dir .. "sample.lua"

print("=== Step 1: Spawning child process (natural exit path) ===")

-- IMPORTANT: cluacov.runner's DEFAULT exclude list contains "cluacov/"
-- and "cluacov%." patterns (intended to skip the runtime itself).
-- Because user-supplied excludes are MERGED with defaults rather than
-- replacing them, ANY path containing "cluacov/" — including this
-- repo's own e2e/sample.lua at .../cluacov/e2e/sample.lua — will be
-- silently filtered out of the lcov/stats output. To get a meaningful
-- regression assertion, we copy sample.lua to a path that does NOT
-- contain "cluacov" so it survives the default exclude filter.
local sample_copy = scratch_dir .. "/target_sample.lua"
do
   local src_fh = assert(io.open(sample_file, "r"))
   local dst_fh = assert(io.open(sample_copy, "w"))
   dst_fh:write(src_fh:read("*a"))
   src_fh:close()
   dst_fh:close()
end

-- We must guarantee that the child loads EXACTLY this repo's freshly
-- built cluacov (./cluacov/*.so + src/cluacov/*.lua), not whatever
-- pre-existing rock the parent's LUA_PATH/LUA_CPATH happens to
-- resolve to first. The latter is what historically caused this E2E
-- to silently fail: a stale globally-installed pchook.so was loaded
-- alongside this repo's runner.lua, making the hook a no-op.
--
-- Strategy: hard-code absolute paths to THIS repo's local build, and
-- put them at the FRONT of the child's package.path / package.cpath
-- so they win the require race.
local repo_root = e2e_dir:gsub("/e2e/$", "")
local local_lua_path = table.concat({
   repo_root .. "/src/?.lua",
   repo_root .. "/src/?/init.lua",
   e2e_dir .. "?.lua",
}, ";")
local local_cpath = table.concat({
   repo_root .. "/cluacov/?.so",            -- legacy layout
   repo_root .. "/lib/lua/5.5/?.so",        -- luarocks --tree=. layout
   repo_root .. "/lib/lua/5.5/?/init.so",
}, ";")

-- No .luacov config needed: target_sample.lua lives at a path that
-- doesn't match the runner's default exclude patterns, so the default
-- include="all" + exclude=runtime-files behavior is exactly what we
-- want.

-- Build the child's Lua source. We deliberately do NOT call os.exit()
-- so that the __gc shutdown path runs.
local child_src = string.format([[
-- Prepend repo-local paths so this build wins over any global rock.
package.path  = %q .. ";" .. package.path
package.cpath = %q .. ";" .. package.cpath
local pchook_path, why = package.searchpath("cluacov.pchook", package.cpath)
print("child: resolved cluacov.pchook -> " .. tostring(pchook_path))
assert(pchook_path, "child cannot resolve cluacov.pchook: " .. tostring(why))
require("cluacov.runner")  -- installs hook + __gc finalizer
-- Load sample from the COPIED path (outside any 'cluacov/' segment)
-- so it isn't filtered by the runner's default exclude list.
local sample = dofile("./target_sample.lua")
-- Exercise a representative slice so the report has real data.
assert(sample.classify(5) == "positive")
assert(sample.sum({1, 2, 3, 4, 5}) == 15)
assert(sample.find({10, 20, 30}, 20) == true)
assert(sample.fizzbuzz(15) == "fizzbuzz")
print("child: workload finished, returning from main chunk")
-- (intentionally NO os.exit() here; relies on __gc shutdown)
]], local_lua_path, local_cpath)

local child_script = scratch_dir .. "/child.lua"
local fh = assert(io.open(child_script, "w"))
fh:write(child_src)
fh:close()

-- Run the child from inside scratch_dir so its stats files land there.
-- The child seeds its own package paths above, so we don't need to
-- forward the parent's environment. We use whichever `lua` is on PATH
-- (under `mise` / `luarocks --lua-version=5.5 path`, this is the same
-- 5.5 binary the parent uses).
local cmd = string.format(
   "cd %q && lua %q",
   scratch_dir,
   child_script)

print("  child cmd: " .. cmd)
-- IMPORTANT: capture ALL return values from a single call. In 5.2+
-- os.execute returns (ok, "exit"|"signal", code); in 5.1 it returns
-- the raw shell code as the first (and only) value. Calling it twice
-- would re-run the child and double-execute side effects.
local r1, r2, r3 = os.execute(cmd)
local actual_code
if type(r1) == "boolean" then
   actual_code = r3
   print(string.format("  child exit: ok=%s kind=%s code=%s",
      tostring(r1), tostring(r2), tostring(r3)))
else
   actual_code = r1
   print(string.format("  child exit (5.1 style): %s", tostring(actual_code)))
end

local function fail(msg, ...)
   io.stderr:write(string.format("FAIL: " .. msg .. "\n", ...))
   os.exit(1)
end

local function ok(msg, ...)
   print(string.format("  OK: " .. msg, ...))
end

print("=== Step 2: Asserting clean exit ===")

if actual_code ~= 0 then
   if actual_code == 139 then
      fail("child crashed with SIGSEGV (139) — savedpc/__gc bug regressed!")
   elseif actual_code == 138 then
      fail("child crashed with SIGBUS (138) — savedpc/__gc bug regressed!")
   else
      fail("child exited with non-zero code: %s", tostring(actual_code))
   end
end
ok("child exited cleanly (code = 0)")

print("=== Step 3: Asserting output artifacts exist and are non-empty ===")

local function file_size(path)
   local f = io.open(path, "rb")
   if not f then return nil end
   local size = f:seek("end")
   f:close()
   return size
end

local stats_file = scratch_dir .. "/luacov.stats.out"
local lcov_file  = scratch_dir .. "/lcov.info"

local stats_size = file_size(stats_file)
if not stats_size or stats_size == 0 then
   fail("luacov.stats.out missing or empty (path=%s)", stats_file)
end
ok("luacov.stats.out exists, size = %d bytes", stats_size)

local lcov_size = file_size(lcov_file)
if not lcov_size or lcov_size == 0 then
   fail("lcov.info missing or empty (path=%s)", lcov_file)
end
ok("lcov.info exists, size = %d bytes", lcov_size)

print("=== Step 4: Asserting lcov.info content ===")

local lcov_fh = assert(io.open(lcov_file, "r"))
local lcov_content = lcov_fh:read("*a")
lcov_fh:close()

local function must_contain(needle, desc)
   if not lcov_content:find(needle, 1, true) then
      fail("lcov.info missing required content (%s): %q", desc, needle)
   end
   ok("lcov.info contains %s (%q)", desc, needle)
end

must_contain("SF:",            "source-file record header")
must_contain("target_sample",  "target_sample.lua source name")
must_contain("DA:",            "per-line hit record")
must_contain("end_of_record",  "record terminator")
-- Branch records require deepbranches to have parsed something:
must_contain("BRF:",           "branches-found field")
must_contain("BRH:",           "branches-hit field")

print("=== Step 5: Generating HTML report via genhtml ===")

-- The lcov.info SF: paths are absolute (target_sample.lua sits inside
-- scratch_dir), so genhtml can read the source bytes directly to
-- render annotated HTML. We write the HTML alongside the lcov so the
-- whole runner_shutdown/ folder is self-contained.
local html_dir = scratch_dir .. "/html"
os.execute("rm -rf " .. html_dir .. " && mkdir -p " .. html_dir)

local genhtml_cmd = string.format(
   "genhtml --quiet --legend --branch-coverage " ..
      "--title %q --output-directory %q %q 2>&1",
   "cluacov runner shutdown E2E (__gc finalizer path)",
   html_dir,
   lcov_file)

local pipe = io.popen(genhtml_cmd .. "; echo __EXIT__:$?")
local genhtml_out = pipe:read("*a")
pipe:close()

local genhtml_exit = genhtml_out:match("__EXIT__:(%d+)")
if genhtml_exit == "0" then
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

print("\n=== E2E runner-shutdown test PASSED ===")
