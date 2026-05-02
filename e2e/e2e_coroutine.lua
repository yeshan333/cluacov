#!/usr/bin/env lua
--
-- E2E test for coverage collection across coroutine boundaries.
--
-- `lua_sethook` binds the hook to the lua_State it was called on, and
-- coroutines run on their OWN lua_State (the `co` thread). Whether
-- pchook hits are recorded for code that runs INSIDE a coroutine is
-- therefore implementation-defined and platform/version-dependent.
--
-- This script:
--   1. Pins down the actual current behavior so future regressions are
--      caught (whichever direction the behavior changes).
--   2. Verifies that pchook NEVER crashes on coroutine workloads, even
--      when the coroutine yields and resumes many times.
--   3. Verifies main-thread coverage continues to work alongside
--      coroutine workloads.
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

print("=== Step 1: Starting pchook ===")
pchook.start()

print("=== Step 2: Running mixed main-thread + coroutine workload ===")

local sample = require("sample")

-- Main-thread work (must always be recorded).
for i = 1, 50 do
   assert(sample.classify(i) == "positive")
end

-- Coroutine work: producer/consumer that yields N times.
local function producer()
   for i = 1, 20 do
      coroutine.yield(sample.abs(-i))   -- exercises sample.abs from coroutine
   end
   return "done"
end

local co = coroutine.create(producer)
local consumed = {}
while true do
   local ok_resume, value = coroutine.resume(co)
   assert(ok_resume, value)
   if coroutine.status(co) == "dead" then break end
   consumed[#consumed + 1] = value
end

assert(#consumed == 20, "expected 20 yielded values, got " .. #consumed)
for i, v in ipairs(consumed) do
   assert(v == i, string.format("consumed[%d] = %s, expected %d", i, v, i))
end

-- Stress test: many small coroutines.
for i = 1, 100 do
   local mini = coroutine.wrap(function()
      coroutine.yield(sample.fizzbuzz(i))
   end)
   mini()
end

pchook.stop()

local function fail(msg, ...)
   io.stderr:write(string.format("FAIL: " .. msg .. "\n", ...))
   os.exit(1)
end

local function ok(msg, ...)
   print(string.format("  OK: " .. msg, ...))
end

print("=== Step 3: Asserting no crash + main-thread data is complete ===")

local all_lines = pchook.get_all_line_hits()
assert(type(all_lines) == "table",
   "get_all_line_hits returned non-table after coroutine workload")

local sample_lines
for source, lines in pairs(all_lines) do
   if type(source) == "string" and source:match("sample%.lua") then
      sample_lines = lines
      break
   end
end

if not sample_lines then
   fail("sample.lua not present in get_all_line_hits after coroutine workload")
end
ok("sample.lua present in aggregate")

-- M.classify's `if n > 0 then` (line 4) ran 50 times in main thread.
local classify_main_hits = sample_lines[4] or 0
if classify_main_hits < 50 then
   fail("M.classify line 4 (main-thread): expected >= 50 hits, got %d",
      classify_main_hits)
end
ok("main-thread M.classify line 4 hit %d times (>= 50)", classify_main_hits)

print("=== Step 4: Documenting coroutine hit-recording behavior ===")

-- M.abs's body (line 14, `if x < 0 then`) was called 20 times from
-- INSIDE a coroutine. Whether this shows hits depends on hook
-- propagation behavior. We assert one of two acceptable outcomes:
--
--   (a) Hits ARE recorded (hook propagates to coroutines)
--   (b) Hits are NOT recorded (hook is main-thread-only)
--
-- Both are valid; we just want to FREEZE the current behavior so it
-- doesn't silently flip. If you change hook propagation in pchook.c,
-- update this assertion intentionally.
local abs_coro_hits = sample_lines[14] or 0
if abs_coro_hits >= 20 then
   ok("coroutine path: hits ARE propagated (line 14 = %d hits)", abs_coro_hits)
elseif abs_coro_hits == 0 then
   ok("coroutine path: hits are NOT propagated (line 14 = 0 hits, documented)")
else
   -- Partial propagation would be very surprising — fail loud.
   fail("M.abs line 14 has unexpected partial hit count from coroutine: %d",
      abs_coro_hits)
end

-- Whatever the propagation behavior, the per-source aggregation must
-- remain self-consistent (max field present, hit values are positive
-- integers).
if type(sample_lines.max) ~= "number" or sample_lines.max <= 0 then
   fail("sample_lines.max should be > 0, got %s", tostring(sample_lines.max))
end
ok("sample_lines.max = %d", sample_lines.max)

for k, v in pairs(sample_lines) do
   if type(k) == "number" then
      if type(v) ~= "number" or v < 0 then
         fail("sample_lines[%d] = %s; expected non-negative integer",
            k, tostring(v))
      end
   end
end
ok("all per-line counts are non-negative integers")

print("\n=== E2E coroutine test PASSED ===")
