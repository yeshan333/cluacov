-- luacheck: std +busted
local pchook = require "cluacov.pchook"
local load = loadstring or load -- luacheck: compat

local function load_function(source)
   return assert(load(source))()
end

describe("pchook", function()
   after_each(function()
      pchook.stop()
      pchook.reset()
   end)

   describe("version", function()
      it("is a string in MAJOR.MINOR.PATCH format", function()
         assert.match("^%d+%.%d+%.%d+$", pchook.version)
      end)
   end)

   if jit then
      describe("on LuaJIT", function()
         it("errors on start", function()
            assert.error(function() pchook.start() end)
         end)

         it("returns empty table from get_hits", function()
            assert.same({}, pchook.get_hits(function() end))
         end)
      end)
   else
      describe("start/stop lifecycle", function()
         it("starts and stops without error", function()
            assert.has_no.errors(function()
               pchook.start()
               pchook.stop()
            end)
         end)

         it("can be started multiple times", function()
            assert.has_no.errors(function()
               pchook.start()
               pchook.start()
               pchook.stop()
            end)
         end)
      end)

      describe("get_hits", function()
         it("throws error for non-function argument", function()
            assert.error(function() pchook.get_hits(5) end)
         end)

         it("throws error for C function argument", function()
            assert.error(function() pchook.get_hits(pchook.start) end)
         end)

         it("returns empty hits when nothing was executed", function()
            pchook.start()
            pchook.stop()
            local func = load_function([[
               return function(x) return x end
            ]])
            local result = pchook.get_hits(func)
            assert.is_table(result)
            assert.is_true(#result >= 1)
            for _, entry in ipairs(result) do
               assert.number(entry.linedefined)
               assert.number(entry.sizecode)
               assert.is_table(entry.hits)
            end
         end)

         it("records per-PC hits for executed instructions", function()
            local func = load_function([[
               return function(x) return x + 1 end
            ]])
            pchook.start()
            func(42)
            pchook.stop()

            local result = pchook.get_hits(func)
            assert.is_true(#result >= 1)
            local top_hits = result[1].hits
            local total = 0
            for _, count in pairs(top_hits) do
               total = total + count
            end
            assert.is_true(total > 0)
         end)

         it("counts multiple executions", function()
            local func = load_function([[
               return function(x) return x + 1 end
            ]])
            pchook.start()
            func(1)
            func(2)
            func(3)
            pchook.stop()

            local result = pchook.get_hits(func)
            local top_hits = result[1].hits
            local has_count_3 = false
            for _, count in pairs(top_hits) do
               if count >= 3 then has_count_3 = true end
            end
            assert.is_true(has_count_3)
         end)

         it("distinguishes branch target PCs", function()
            local func = load_function([[
               return function(x)
                  if x then
                     return 1
                  else
                     return 2
                  end
               end
            ]])

            pchook.start()
            func(true)
            pchook.stop()

            local deepbranches = require("cluacov.deepbranches")
            local branches = deepbranches.get(func)
            assert.is_true(#branches >= 1)

            local result = pchook.get_hits(func)
            local top_hits = result[1].hits
            local branch = branches[1]

            local t1_hits = top_hits[branch.targets[1].pc] or 0
            local t2_hits = top_hits[branch.targets[2].pc] or 0
            assert.is_true(t1_hits > 0 or t2_hits > 0)
            assert.is_true(t1_hits == 0 or t2_hits == 0)
         end)
      end)

      describe("nested functions", function()
         it("collects hits for nested function protos", function()
            local func = load_function([[
               return function()
                  local function inner(x)
                     return x * 2
                  end
                  return inner(5)
               end
            ]])

            pchook.start()
            func()
            pchook.stop()

            local result = pchook.get_hits(func)
            assert.is_true(#result >= 2)
         end)
      end)

      describe("reset", function()
         it("clears all recorded hits", function()
            local func = load_function([[
               return function(x) return x end
            ]])
            pchook.start()
            func(1)
            pchook.stop()
            pchook.reset()

            local result = pchook.get_hits(func)
            assert.is_true(#result >= 1)
            local total = 0
            for _, entry in ipairs(result) do
               for _, count in pairs(entry.hits) do
                  total = total + count
               end
            end
            assert.equal(0, total)
         end)
      end)

      describe("get_line_hits", function()
         it("throws error for non-function argument", function()
            assert.error(function() pchook.get_line_hits(5) end)
         end)

         it("throws error for C function argument", function()
            assert.error(function() pchook.get_line_hits(pchook.start) end)
         end)

         it("returns table with max field", function()
            local func = load_function([[
               return function(x) return x + 1 end
            ]])
            pchook.start()
            func(1)
            pchook.stop()

            local result = pchook.get_line_hits(func)
            assert.is_table(result)
            assert.is_number(result.max)
            assert.is_true(result.max > 0)
         end)

         it("maps PC hits to line numbers", function()
            local func = load_function([[
               return function(x)
                  local a = x + 1
                  local b = a + 2
                  return b
               end
            ]])
            pchook.start()
            func(10)
            pchook.stop()

            local result = pchook.get_line_hits(func)
            local hit_count = 0
            for k, v in pairs(result) do
               if type(k) == "number" and v > 0 then
                  hit_count = hit_count + 1
               end
            end
            assert.is_true(hit_count >= 2)
         end)

         it("includes lines from nested functions", function()
            local func = load_function([[
               return function()
                  local function inner(x)
                     return x * 2
                  end
                  return inner(5)
               end
            ]])
            pchook.start()
            func()
            pchook.stop()

            local result = pchook.get_line_hits(func)
            local hit_count = 0
            for k, v in pairs(result) do
               if type(k) == "number" and v > 0 then
                  hit_count = hit_count + 1
               end
            end
            assert.is_true(hit_count >= 3)
         end)

         it("returns empty hits for unexecuted function", function()
            pchook.start()
            pchook.stop()
            local func = load_function([[
               return function(x) return x end
            ]])
            local result = pchook.get_line_hits(func)
            assert.is_table(result)
            local hit_count = 0
            for k, v in pairs(result) do
               if type(k) == "number" and v > 0 then
                  hit_count = hit_count + 1
               end
            end
            assert.equal(0, hit_count)
         end)
      end)
   end
end)
