-- luacheck: std +busted
local pchook = require "cluacov.pchook"
local branchcov = require "cluacov.branchcov"
local deepbranches = require "cluacov.deepbranches"
local load = loadstring or load -- luacheck: compat

describe("LuaJIT branch coverage", function()
   if not jit then return end

   local was_enabled
   before_each(function()
      was_enabled = jit.status()
   end)
   after_each(function()
      debug.sethook()
      pchook.stop()
      pchook.reset()
      if was_enabled then jit.on() else jit.off() end
   end)

   local function compile(source)
      return assert(load(source, "@luajit_fixture.lua"))()
   end

   local function branch(func, kind)
      for _, site in ipairs(branchcov.analyze(func).branches) do
         if site.kind == kind then return site end
      end
      error("missing " .. kind .. " branch")
   end

   local function counts(site)
      return { site.targets[1].hits, site.targets[2].hits }
   end

   it("distinguishes literal table values while matching separately loaded copies", function()
      local source = "return function() local t={value=1, [true]='yes', 10, 20}; return t end, "
         .. "function() local t={value=2, [true]='yes', 10, 20}; return t end"
      local first, second = compile(source)
      local copy = compile(source)
      local a = pchook.get_hits(first)[1].signature
      local b = pchook.get_hits(second)[1].signature
      assert.not_equal(a, b)
      assert.equal(a, pchook.get_hits(copy)[1].signature)
   end)

   it("omits an empty conditional whose two outcomes compile to the same successor", function()
      local func = compile("return function(x) if x then end return 1 end")
      pchook.start()
      assert.equal(1, func(true))
      pchook.stop()
      assert.same({}, deepbranches.get(func))
      assert.equal(0, branchcov.analyze(func).total)
   end)

   if pcall(require, "ffi") then
      for _, suffix in ipairs({ "LL", "ULL", "i" }) do
         it("distinguishes " .. suffix .. " literal values when matching separately loaded functions", function()
            local template = "return function(x) local n=%s; if x then return n end end"
            local first = compile(template:format("1" .. suffix))
            local second = compile(template:format("2" .. suffix))
            local copy = compile(template:format("1" .. suffix))
            local signature = pchook.get_hits(first)[1].signature
            assert.not_equal(signature, pchook.get_hits(second)[1].signature)
            assert.equal(signature, pchook.get_hits(copy)[1].signature)
         end)
      end
   end

   it("keeps ordinary-call counts unchanged when LuaJIT suppresses hooks inside a finalizer", function()
      local runs = 0
      local func = compile("return function(x) if x then return 1 end return 2 end")
      pchook.start()
      assert.equal(1, func(true))
      do
         local anchor = newproxy(true)
         getmetatable(anchor).__gc = function()
            runs = runs + func(false)
         end
      end
      collectgarbage("collect")
      collectgarbage("collect")
      pchook.stop()
      assert.equal(2, runs, "the finalizer must actually run")
      assert.equal(1, pchook.get_hits(func)[1].calls)
      assert.equal("partial", branch(func, "test").status)
   end)

   for _, mode in ipairs({ "removed", "replaced" }) do
      it("collects branches and restores JIT after the global require is " .. mode, function()
         local func = compile("return function(x) if x then return 1 end return 2 end")
         local original_require = _G.require
         local replacement_called = false
         local collecting_jit, result
         jit.on()
         local ok, err = pcall(function()
            _G.require = mode == "replaced" and function()
               replacement_called = true
               error("application loader must not be called")
            end or nil
            pchook.start()
            collecting_jit = jit.status()
            result = func(true)
            pchook.stop()
         end)
         _G.require = original_require
         assert.is_true(ok, tostring(err))
         assert.is_false(replacement_called)
         assert.is_false(collecting_jit)
         assert.equal(1, result)
         assert.is_true(jit.status())
         assert.equal("partial", branch(func, "test").status)
      end)
   end

   it("counts every iteration of a loop compiled before collection starts", function()
      jit.on()
      jit.flush()
      local func = compile("return function(n) local s=0; for i=1,n do s=s+i end; return s end")
      for _ = 1, 100 do func(100) end
      assert.is_table(require("jit.util").traceinfo(1), "fixture must create a trace")
      pchook.start()
      assert.is_false(jit.status())
      assert.equal(5050, func(100))
      pchook.stop()
      assert.is_true(jit.status())
      assert.same({ 99, 1 }, counts(branch(func, "loop")))
      assert.same({ 1, 0 }, counts(branch(func, "loop-entry")))
      assert.equal(1, pchook.get_hits(func)[1].calls)
   end)

   it("discovers the branches of a previously compiled function", function()
      jit.on()
      local func = compile("return function(n) local s=0; for i=1,n do s=s+i end; return s end")
      for _ = 1, 100 do func(100) end
      local sites = deepbranches.get(func)
      assert.equal(2, #sites)
      assert.equal("loop-entry", sites[1].kind)
      assert.equal("loop", sites[2].kind)
      assert.is_true(jit.status())
   end)

   for _, enabled in ipairs({ false, true }) do
      it("restores the initial JIT state " .. tostring(enabled) .. " after repeated start and stop", function()
         if enabled then jit.on() else jit.off() end
         pchook.start()
         pchook.start()
         assert.is_false(jit.status())
         pchook.stop()
         pchook.stop()
         assert.equal(enabled, jit.status())
      end)
   end

   it("freezes hits in a finalizer and restores JIT when ordinary collection resumes", function()
      jit.on()
      local func = compile("return function() return 1 end")
      local finalized = false
      pchook.start()
      func()
      do
         local anchor = newproxy(true)
         getmetatable(anchor).__gc = function()
            pchook.stop()
            finalized = true
         end
      end
      collectgarbage("collect")
      collectgarbage("collect")
      assert.is_true(finalized)
      assert.is_false(jit.status())
      assert.equal(1, pchook.get_hits(func)[1].calls)
      pchook.start()
      func()
      pchook.stop()
      assert.is_true(jit.status())
      assert.equal(2, pchook.get_hits(func)[1].calls)
   end)

   it("leaves JIT enabled when an invalid tick configuration rejects start", function()
      jit.on()
      assert.has_error(function() pchook.start({ savestepsize = 0 }) end)
      assert.is_true(jit.status())
   end)

   it("preserves a replacement VM-wide hook installed from a coroutine", function()
      local replacement = function() end
      pchook.start()
      local co = coroutine.create(function() debug.sethook(replacement, "l") end)
      assert.is_true(coroutine.resume(co))
      pchook.stop()
      local hook, mask = debug.gethook()
      assert.equal(replacement, hook)
      assert.equal("l", mask)
   end)

   it("disables a preexisting VM-wide hook throughout collection and after stop", function()
      local external_calls = 0
      debug.sethook(function() external_calls = external_calls + 1 end, "l")
      pchook.start()
      local before = external_calls
      local func = compile("return function(x) if x then return 1 end return 2 end")
      assert.equal(1, func(true))
      pchook.stop()
      assert.equal(before, external_calls)
      local _, mask, interval = debug.gethook()
      assert.equal("", mask)
      assert.equal(0, interval)
      assert.equal("partial", branch(func, "test").status)
   end)

   for _, scenario in ipairs({
      { name = "empty", input = {}, expected = { 0, 1 } },
      { name = "array and hash", input = { 1, 2, key = 3 }, expected = { 3, 1 } },
   }) do
      it("counts continuation and exhaustion of specialized pairs over an " .. scenario.name .. " table", function()
         local func = compile("return function(t) local s=0; for _,v in pairs(t) do s=s+v end; return s end")
         pchook.start()
         func(scenario.input)
         pchook.stop()
         assert.same(scenario.expected, counts(branch(func, "iterator")))
      end)
   end

   it("keeps iterator counts when next specialization falls back to a Lua iterator", function()
      local func = compile([[return function(next, t)
         local n=0
         for _ in next, t do n=n+1 end
         return n
      end]])
      local function custom(t, key) return next(t, key) end
      pchook.start()
      assert.equal(2, func(next, { a=1, b=2 }))
      assert.equal(1, func(custom, { c=3 }))
      pchook.stop()
      assert.same({ 3, 2 }, counts(branch(func, "iterator")))
   end)

   for _, expression in ipairs({ "a < b", "a <= b", "a > b", "a >= b", "a == b", "a ~= b" }) do
      it("records both outcomes of " .. expression .. " when comparison invokes a Lua metamethod", function()
         local mt = { __lt = function(a, b) return a.x < b.x end,
            __le = function(a, b) return a.x <= b.x end,
            __eq = function(a, b) return a.x == b.x end }
         local a, b = setmetatable({ x=1 }, mt), setmetatable({ x=2 }, mt)
         local func = compile("return function(a,b) if " .. expression .. " then return 1 end return 0 end")
         pchook.start()
         func(a, b)
         func(b, a)
         func(a, setmetatable({ x=1 }, mt))
         pchook.stop()
         local result = counts(branch(func, "test"))
         table.sort(result)
         assert.same({ 1, 2 }, result)
      end)
   end

   it("counts vararg tail recursion independently of reused frames", function()
      local func = compile([[local function f(n, ...)
         if n == 0 then return ... end
         return f(n-1, ...)
      end return f]])
      pchook.start()
      assert.same({ "a", "b" }, { func(20, "a", "b") })
      pchook.stop()
      assert.equal(21, pchook.get_hits(func)[1].calls)
      local result = counts(branch(func, "test"))
      table.sort(result)
      assert.same({ 1, 20 }, result)
   end)

   it("does not join an aborted vararg call to the next invocation reusing its stack", function()
      local func = compile("return function(ok, ...) assert(ok); return ... end")
      pchook.start()
      for i = 1, 2 do pcall(func, i == 2, "value", 2) end
      pchook.stop()
      local record = pchook.get_hits(func)[1]
      assert.equal(2, record.calls)
      for _, edges in pairs(record.edges) do
         assert.is_nil(edges[1], "a new invocation has no incoming edge")
      end
      assert.same({ 1, 1 }, counts(branch(func, "assert")))
   end)

   it("keeps captured values collectible while retaining materialized coverage through full GC", function()
      local weak = setmetatable({}, { __mode = "v" })
      pchook.start()
      for i = 1, 200 do
         local value = { i }
         local func = compile("return function(value) return function(x) if x then return value[1] end end end")(value)
         weak[i] = value
         func(true)
      end
      collectgarbage("collect")
      collectgarbage("collect")
      pchook.stop()
      assert.is_nil(next(weak))
      assert.is_table(pchook.get_all_hits()["@luajit_fixture.lua"])
   end)
end)
