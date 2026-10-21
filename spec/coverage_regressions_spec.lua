-- luacheck: std +busted
local pchook = require "cluacov.pchook"
local branchcov = require "cluacov.branchcov"
local load = loadstring or load -- luacheck: compat

describe("coverage across function identities and call frames", function()
   if not jit and tonumber(_VERSION:match("(%d+%.%d+)")) < 5.4 then
      pending("requires PUC-Rio Lua 5.4+ or LuaJIT 2.1")
      return
   end

   after_each(function()
      pchook.stop()
      pchook.reset()
   end)

   local function compile(source)
      return assert(load(source, "@coverage_fixture.lua"))()
   end

   local function calls(func)
      return pchook.get_hits(func)[1].calls
   end

   it("keeps identical same-line siblings separate when only the first is called", function()
      local source = "return function(x) if x then return 1 else return 2 end end, "
         .. "function(x) if x then return 1 else return 2 end end"
      local first, second = compile(source)
      pchook.start()
      first(true)
      pchook.stop()
      assert.equal(1, calls(first))
      assert.equal(0, calls(second))
      assert.equal("partial", branchcov.analyze(first).branches[1].status)
      assert.equal("uncovered", branchcov.analyze(second).branches[1].status)
   end)

   it("joins each nested branch to its own function when same-line siblings take opposite paths", function()
      local source = "return function(x) if x then return 1 else return 2 end end, "
         .. "function(x) if x then return 1 else return 2 end end"
      local chunk = assert(load(source))
      pchook.start()
      local first, second = chunk()
      first(true)
      second(false)
      pchook.stop()
      local result = branchcov.analyze(chunk)
      assert.equal(2, #result.branches)
      assert.equal("partial", result.branches[1].status)
      assert.equal("partial", result.branches[2].status)
      assert.equal(2, result.hit)
   end)

   it("preserves every query after stop/start without executing the function again", function()
      local func = compile("return function(x) if x then return 1 else return 2 end end")
      pchook.start()
      func(true)
      pchook.stop()
      local hits = pchook.get_hits(func)
      local lines = pchook.get_line_hits(func)
      local branches = branchcov.analyze(func)
      pchook.start()
      pchook.stop()
      assert.same(hits, pchook.get_hits(func))
      assert.same(lines, pchook.get_line_hits(func))
      assert.same(branches, branchcov.analyze(func))
   end)

   it("reuses one record for stripped bytecode across repeated calls and garbage collections", function()
      local original = compile("return function(x) return x + 1 end")
      local func = assert(load(string.dump(original, true)))
      pchook.start()
      for i = 1, 1000 do
         func(i)
         if i % 100 == 0 then collectgarbage("collect") end
      end
      pchook.stop()
      assert.equal(1, #pchook.get_all_hits()["?"])
      assert.equal(1000, calls(func))
      assert.equal(1000, pchook.get_hits(func)[1].hits[1])
   end)

   for _, mode in ipairs(jit and { "incremental" } or { "incremental", "generational" }) do
      it("does not retain closures or their captured objects under " .. mode .. " GC", function()
         local old_mode = not jit and collectgarbage(mode)
         local ok, err = pcall(function()
            local weak = setmetatable({}, { __mode = "v" })
            pchook.start()
            do
               local captured = { value = 1 }
               local factory = compile("return function(value) return function() return value.value end end")
               local func = factory(captured)
               weak[1], weak[2] = func, captured
               assert.equal(1, func())
            end
            collectgarbage("collect")
            collectgarbage("collect")
            pchook.stop()
            assert.is_nil(weak[1])
            assert.is_nil(weak[2])
            assert.is_table(pchook.get_all_hits()["@coverage_fixture.lua"])
         end)
         pchook.stop()
         if old_mode then collectgarbage(old_mode) end
         assert.is_true(ok, tostring(err))
      end)
   end

   it("counts calls independently of a while or repeat loop at the function entry", function()
      local spin, repeat_spin = compile([[
return function(n) while n > 0 do n = n - 1 end end,
function(n) repeat n = n - 1 until n == 0 end
]])
      pchook.start()
      spin(3)
      spin(0)
      repeat_spin(5)
      pchook.stop()
      assert.equal(2, calls(spin))
      assert.equal(1, calls(repeat_spin))
   end)

   it("does not count loop completion as the numeric loop's zero-iteration entry edge", function()
      local func = compile("return function(n) local sum=0; for i=1,n do sum=sum+i end; return sum end")
      pchook.start()
      assert.equal(6, func(3))
      pchook.stop()
      local result = branchcov.analyze(func)
      assert.equal("loop-entry", result.branches[1].kind)
      assert.equal("partial", result.branches[1].status)
      assert.equal(1, result.branches[1].targets[1].hits)
      assert.equal(0, result.branches[1].targets[2].hits)
      assert.equal("covered", result.branches[2].status)
      assert.equal(2, result.branches[2].targets[1].hits)
      assert.equal(1, result.branches[2].targets[2].hits)
   end)

   it("records the generic iterator's continuation and exhaustion after Lua iterator calls", function()
      local func = compile([[
return function()
   local function next_value(_, value)
      if value < 3 then return value + 1 end
   end
   local sum = 0
   for value in next_value, nil, 0 do sum = sum + value end
   return sum
end
]])
      pchook.start()
      assert.equal(6, func())
      pchook.stop()
      local iterator
      for _, branch in ipairs(branchcov.analyze(func).branches) do
         if branch.kind == "iterator" then iterator = branch end
      end
      assert.is_table(iterator)
      assert.equal(3, iterator.targets[1].hits)
      assert.equal(1, iterator.targets[2].hits)
   end)

   for _, scenario in ipairs({
      { name = "tail recursion", code = "return recur(n - 1)" },
      { name = "ordinary recursion", code = "local value = recur(n - 1); return value" },
   }) do
      it("counts four calls and the 1/3 branch outcomes under " .. scenario.name, function()
         local source = "local function recur(n) if n == 0 then return 0 end; "
            .. scenario.code .. " end; return recur"
         local func = compile(source)
         pchook.start()
         assert.equal(0, func(3))
         pchook.stop()
         assert.equal(4, calls(func))
         local result = branchcov.analyze(func)
         assert.equal("covered", result.branches[1].status)
         local counts = { result.branches[1].targets[1].hits, result.branches[1].targets[2].hits }
         table.sort(counts)
         assert.same({ 1, 3 }, counts)
      end)
   end

   it("keeps edges separate when two coroutines yield in the same function", function()
      local func = compile([[
return function(x)
   if x then coroutine.yield('true') else coroutine.yield('false') end
   return x
end
]])
      pchook.start()
      local first, second = coroutine.create(func), coroutine.create(func)
      assert.same({ true, "true" }, { coroutine.resume(first, true) })
      assert.same({ true, "false" }, { coroutine.resume(second, false) })
      assert.same({ true, true }, { coroutine.resume(first) })
      assert.same({ true, false }, { coroutine.resume(second) })
      pchook.stop()
      assert.equal(2, calls(func))
      local branch = branchcov.analyze(func).branches[1]
      assert.equal(1, branch.targets[1].hits)
      assert.equal(1, branch.targets[2].hits)
   end)

   it("does not invent an edge across the interval in which collection was stopped", function()
      local func = compile([[
return function()
   local value = 1
   coroutine.yield(value)
   value = 2
   return value
end
]])
      local co = coroutine.create(func)
      pchook.start()
      assert.is_true(coroutine.resume(co))
      pchook.stop()
      local before = pchook.get_hits(func)[1]
      local previous
      for pc in pairs(before.hits) do previous = math.max(previous or 0, pc) end
      pchook.start()
      assert.is_true(coroutine.resume(co))
      pchook.stop()
      local after = pchook.get_hits(func)[1]
      assert.is_nil(after.edges[previous])
      assert.equal(1, after.calls)
   end)

   it("does not reuse aborted call frames when a failed call is followed by a successful call", function()
      local func = compile("return function(ok) assert(ok); return 1 end")
      pchook.start()
      assert.is_false(pcall(func, false))
      assert.equal(1, func(true))
      pchook.stop()
      assert.equal(2, calls(func))
      local branch = branchcov.analyze(func).branches[1]
      assert.equal("covered", branch.status)
      assert.equal(1, branch.targets[1].hits)
      assert.equal(1, branch.targets[2].hits)
   end)

   it("keeps reset within the active tick session and makes the next start idempotent", function()
      local saves = 0
      local func = compile("return function() return 1 end")
      pchook.start({ savestepsize = 1, save_stats = function() saves = saves + 1 end })
      func()
      pchook.reset()
      local before = saves
      pchook.start()
      func()
      pchook.stop()
      assert.is_true(saves > before)
      assert.equal(1, calls(func))
   end)
end)
