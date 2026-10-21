#!/usr/bin/env lua
-- Exercise the public runner in fresh processes, then inspect the reports
-- written at natural exit. Target functions are called ONLY in coroutines,
-- so main-thread hits cannot hide missing coroutine coverage.

local function read_file(path)
   local file = assert(io.open(path, "r"))
   local content = file:read("*a")
   file:close()
   return content
end

local function write_file(path, content)
   local file = assert(io.open(path, "w"))
   assert(file:write(content))
   assert(file:close())
end

local function shell_quote(value)
   return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function execute(command)
   local ok, kind, code = os.execute(command)
   assert(ok == 0 or (ok == true and kind == "exit" and code == 0),
      string.format("command failed (%s %s): %s", tostring(kind), tostring(code), command))
end

local cwd_pipe = assert(io.popen("pwd"))
local cwd = assert(cwd_pipe:read("*l"))
assert(cwd_pipe:close())
local e2e_dir = arg[0]:match("(.-)[^/]*$") or "./"
if e2e_dir:sub(1, 1) ~= "/" then e2e_dir = cwd .. "/" .. e2e_dir end
local repo_root = e2e_dir:gsub("/e2e/$", "")
local lua_version = _VERSION:match("%d+%.%d+")
local output_dir = e2e_dir .. "output/coroutine_runner/" .. lua_version
local fixture = read_file(e2e_dir .. "fixtures/coroutine_target.lua")
local markers = {}
local line_number = 0
for line in fixture:gmatch("[^\n]*\n") do
   line_number = line_number + 1
   local name = line:match("%-%- @(%w+)")
   if name then
      assert(not markers[name], "duplicate source marker: " .. name)
      markers[name] = line_number
   end
end

local cases = {
   {
      id = "created_before_start",
      name = "a coroutine created before collection records coverage through a cached resume",
      before_start = [[
local resume = coroutine.resume
local co = coroutine.create(function() return target.exchange() end)
]],
      workload = [[
assert(select(2, resume(co)) == "request")
assert(select(2, resume(co, "rpc")) == "rpc:waiting")
local ok, result = resume(co, "reply")
assert(ok and result == "reply:ok")
assert(coroutine.status(co) == "dead")
]],
      lines = { request = 1, waiting = 1, decision = 1, success = 1 },
      branches = { 1, 0 },
   },
   {
      id = "suspended_before_start",
      name = "a coroutine suspended before collection records coverage when resumed",
      before_start = [[
local co = coroutine.create(function()
   coroutine.yield("ready")
   return target.exchange()
end)
assert(select(2, coroutine.resume(co)) == "ready")
]],
      workload = [[
assert(select(2, coroutine.resume(co)) == "request")
assert(select(2, coroutine.resume(co, "rpc")) == "rpc:waiting")
local ok, result = coroutine.resume(co, false)
assert(ok and result == "timeout")
assert(coroutine.status(co) == "dead")
]],
      lines = { request = 1, waiting = 1, decision = 1, timeout = 1 },
      branches = { 0, 1 },
   },
   {
      id = "wrapped_before_start",
      name = "a coroutine.wrap closure created before collection records its resumed branches",
      before_start = [[
local next_response = coroutine.wrap(function() return target.exchange() end)
]],
      workload = [[
assert(next_response() == "request")
assert(next_response("rpc") == "rpc:waiting")
assert(next_response("reply") == "reply:ok")
]],
      lines = { request = 1, waiting = 1, decision = 1, success = 1 },
      branches = { 1, 0 },
   },
   {
      id = "child_of_preexisting_coroutine",
      name = "a child created by a preexisting coroutine inherits collection after start",
      before_start = [[
local parent = coroutine.create(function()
   local child = coroutine.wrap(target.exchange)
   assert(child() == "request")
   assert(child("rpc") == "rpc:waiting")
   return child("reply")
end)
]],
      workload = [[
local ok, result = coroutine.resume(parent)
assert(ok and result == "reply:ok")
assert(coroutine.status(parent) == "dead")
]],
      lines = { request = 1, waiting = 1, decision = 1, success = 1 },
      branches = { 1, 0 },
   },
   {
      id = "create",
      name = "coroutine.create records both resumes and only the successful response branch",
      workload = [[
local co = coroutine.create(target.exchange)
assert(select(2, coroutine.resume(co)) == "request")
assert(select(2, coroutine.resume(co, "rpc")) == "rpc:waiting")
local ok, result = coroutine.resume(co, "reply")
assert(ok and result == "reply:ok")
assert(coroutine.status(co) == "dead")
]],
      lines = { request = 1, waiting = 1, decision = 1, success = 1 },
      branches = { 1, 0 }, -- success target, timeout target
   },
   {
      id = "wrap",
      name = "coroutine.wrap records both resumes and only the timeout branch",
      workload = [[
local next_response = coroutine.wrap(target.exchange)
assert(next_response() == "request")
assert(next_response("rpc") == "rpc:waiting")
assert(next_response(false) == "timeout")
]],
      lines = { request = 1, waiting = 1, decision = 1, timeout = 1 },
      branches = { 0, 1 },
   },
   {
      id = "interleaved",
      name = "interleaved coroutines sharing a function retain both response branches",
      workload = [[
local first = coroutine.create(target.exchange)
local second = coroutine.create(target.exchange)
assert(select(2, coroutine.resume(first)) == "request")
assert(select(2, coroutine.resume(second)) == "request")
assert(select(2, coroutine.resume(second, "second")) == "second:waiting")
assert(select(2, coroutine.resume(first, "first")) == "first:waiting")
assert(select(2, coroutine.resume(first, "reply")) == "reply:ok")
assert(select(2, coroutine.resume(second, false)) == "timeout")
assert(coroutine.status(first) == "dead" and coroutine.status(second) == "dead")
]],
      lines = { request = 2, waiting = 2, decision = 2, success = 1, timeout = 1 },
      branches = { 1, 1 },
   },
   {
      id = "nested",
      name = "a coroutine created inside a yielding parent retains response coverage",
      workload = [[
local parent = coroutine.create(function()
   local child = coroutine.wrap(target.exchange)
   assert(child() == "request")
   local request = coroutine.yield("parent waiting")
   assert(child(request) == "rpc:waiting")
   local response = coroutine.yield("child waiting")
   return child(response)
end)
assert(select(2, coroutine.resume(parent)) == "parent waiting")
assert(select(2, coroutine.resume(parent, "rpc")) == "child waiting")
assert(select(2, coroutine.resume(parent, "reply")) == "reply:ok")
assert(coroutine.status(parent) == "dead")
]],
      lines = { request = 1, waiting = 1, decision = 1, success = 1 },
      branches = { 1, 0 },
   },
   {
      id = "error",
      name = "a coroutine failing after resume records the error line but no following code",
      workload = [[
local co = coroutine.create(target.fail_after_yield)
assert(select(2, coroutine.resume(co)) == "pending")
local ok, message = coroutine.resume(co, "expected coroutine failure")
assert(not ok and message:match("expected coroutine failure"))
assert(coroutine.status(co) == "dead")
]],
      lines = { pending = 1, error = 1 },
      branches = { 0, 0 },
   },
   {
      id = "close",
      name = "closing a suspended coroutine leaves its unresumed lines and branches uncovered",
      workload = [[
local co = coroutine.create(target.exchange)
assert(select(2, coroutine.resume(co)) == "request")
assert(coroutine.close(co))
assert(coroutine.status(co) == "dead")
]],
      lines = { request = 1 },
      branches = { 0, 0 },
   },
}

if not coroutine.close then
   -- LuaJIT has no explicit close; exercise collection of an abandoned thread.
   cases[#cases].id = "abandon"
   cases[#cases].name = "collecting a suspended coroutine leaves its unresumed branches uncovered"
   cases[#cases].workload = [[
local co = coroutine.create(target.exchange)
assert(select(2, coroutine.resume(co)) == "request")
co = nil
collectgarbage("collect")
collectgarbage("collect")
]]
end

local function check_report(directory, case)
   local lines, branches = {}, {}
   local in_target, found = false, false
   for line in read_file(directory .. "/lcov.info"):gmatch("[^\r\n]+") do
      local source = line:match("^SF:(.*)")
      if source then
         in_target = source == directory .. "/target.lua"
         if in_target then
            assert(not found, "duplicate target.lua source record")
            found = true
         end
      elseif line == "end_of_record" then
         in_target = false
      elseif in_target then
         local number, hits = line:match("^DA:(%d+),(%d+)$")
         if number then lines[tonumber(number)] = tonumber(hits) end
         local branch_line, branch, taken = line:match("^BRDA:(%d+),%d+,(%d+),([%d%-]+)$")
         if tonumber(branch_line) == markers.decision then
            local index = tonumber(branch) + 1
            assert(index <= 2 and branches[index] == nil, "unexpected or duplicate branch target")
            branches[index] = taken == "-" and 0 or tonumber(taken)
         end
      end
   end
   assert(found, "target.lua missing from LCOV report")
   for name, number in pairs(markers) do
      local expected = case.lines[name] or 0
      assert(lines[number] == expected, string.format(
         "%s: @%s (line %d): expected %d hits, got %s",
         case.id, name, number, expected, tostring(lines[number])))
   end
   assert(#branches == 2, "expected both BRDA records for the response condition")
   for index, expected in ipairs(case.branches) do
      assert(branches[index] == expected, string.format(
         "%s: expected branch hits {%d, %d}, got {%d, %d}", case.id,
         case.branches[1], case.branches[2], branches[1], branches[2]))
   end

   -- The legacy-compatible stats file must agree with LCOV for executed
   -- and unexecuted lines; merely creating two nonempty files is insufficient.
   local stats = read_file(directory .. "/luacov.stats.out")
   local max_line, counts = stats:match("^(%d+):%./target%.lua\n([^\n]+)")
   assert(max_line and tonumber(max_line) >= markers.unreachable,
      "target.lua missing or truncated in luacov.stats.out")
   local stats_lines = {}
   for count in counts:gmatch("%d+") do stats_lines[#stats_lines + 1] = tonumber(count) end
   for name, number in pairs(markers) do
      assert(stats_lines[number] == (case.lines[name] or 0),
         case.id .. ": stats disagree with expected hits at @" .. name)
   end
end

for _, case in ipairs(cases) do
   print("RUN: " .. case.name)
   local directory = output_dir .. "/" .. case.id
   execute("mkdir -p " .. shell_quote(directory))
   -- Remove old outputs before execution so a missing report cannot pass.
   os.remove(directory .. "/lcov.info")
   os.remove(directory .. "/luacov.stats.out")
   write_file(directory .. "/target.lua", fixture)
   write_file(directory .. "/.luacov", 'include = { "^%./target$" }\n')
   local child = string.format([[
package.path = %q .. "/src/?.lua;" .. package.path
package.cpath = %q .. "/lib/lua/" .. %q .. "/?.so;" .. package.cpath
local saved_create, saved_wrap = coroutine.create, coroutine.wrap
local target
%s
require("cluacov.runner")
assert(not package.loaded["luacov.runner"], "only cluacov.runner should be active")
assert(coroutine.create == saved_create and coroutine.wrap == saved_wrap,
   "cluacov.runner should preserve native coroutine factories")
target = dofile("./target.lua")
%s
]], repo_root, repo_root, lua_version, case.before_start or "", case.workload)
   write_file(directory .. "/child.lua", child)
   execute("cd " .. shell_quote(directory) .. " && LUACOV_CONFIG=.luacov lua child.lua")
   check_report(directory, case)
   print("  PASS: " .. case.name)
end

print("\n=== E2E coroutine runner test PASSED ===")
