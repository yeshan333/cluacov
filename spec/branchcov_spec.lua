-- luacheck: std +busted
local branchcov = require "cluacov.branchcov"
local pchook = require "cluacov.pchook"
local load = loadstring or load -- luacheck: compat

local function load_function(source)
   return assert(load(source))()
end

describe("branchcov", function()
   after_each(function()
      pchook.stop()
      pchook.reset()
   end)

   if jit then
      pending("branchcov requires PUC-Rio Lua 5.4+")
   else
      describe("analyze", function()
         it("returns correct structure", function()
            local func = load_function([[
               return function(x)
                  if x then return 1 else return 2 end
               end
            ]])

            pchook.start()
            func(true)
            pchook.stop()

            local result = branchcov.analyze(func)
            assert.is_table(result)
            assert.is_table(result.branches)
            assert.number(result.total)
            assert.number(result.hit)
            assert.is_true(result.total > 0)
         end)

         it("detects partial coverage for if/else", function()
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

            local result = branchcov.analyze(func)
            assert.is_true(#result.branches >= 1)

            local has_partial = false
            for _, b in ipairs(result.branches) do
               if b.status == "partial" then
                  has_partial = true
               end
            end
            assert.is_true(has_partial)
         end)

         it("detects full coverage when both paths taken", function()
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
            func(false)
            pchook.stop()

            local result = branchcov.analyze(func)
            local all_covered = true
            for _, b in ipairs(result.branches) do
               if b.status ~= "covered" then
                  all_covered = false
               end
            end
            assert.is_true(all_covered)
         end)

         it("reports compound or as multiple branches", function()
            local func = load_function([[
               return function(a, b, c)
                  if a or b or c then
                     return 1
                  else
                     return 2
                  end
               end
            ]])

            pchook.start()
            func(true, nil, nil)
            pchook.stop()

            local result = branchcov.analyze(func)
            local test_count = 0
            for _, b in ipairs(result.branches) do
               if b.kind == "test" then
                  test_count = test_count + 1
               end
            end
            assert.is_true(test_count >= 3)
            assert.is_true(result.total >= 6)
         end)

         it("shows per-instruction coverage for compound or", function()
            local func = load_function([[
               return function(a, b, c)
                  if a or b or c then
                     return 1
                  else
                     return 2
                  end
               end
            ]])

            pchook.start()
            func(true, nil, nil)
            pchook.stop()

            local result = branchcov.analyze(func)

            local partial_count = 0
            for _, b in ipairs(result.branches) do
               if b.kind == "test" and b.status == "partial" then
                  partial_count = partial_count + 1
               end
            end
            assert.is_true(partial_count >= 2)
            assert.is_true(result.hit < result.total)
         end)

         it("handles compound and", function()
            local func = load_function([[
               return function(a, b)
                  if a and b then
                     return 1
                  else
                     return 2
                  end
               end
            ]])

            pchook.start()
            func(true, true)
            pchook.stop()

            local result = branchcov.analyze(func)
            local test_count = 0
            for _, b in ipairs(result.branches) do
               if b.kind == "test" then
                  test_count = test_count + 1
               end
            end
            assert.is_true(test_count >= 2)
            assert.is_true(result.total >= 4)
         end)

         it("handles nested functions", function()
            local func = load_function([[
               return function()
                  local function inner(x)
                     if x then return 1 else return 2 end
                  end
                  return inner(true)
               end
            ]])

            pchook.start()
            func()
            pchook.stop()

            local result = branchcov.analyze(func)
            assert.is_true(#result.branches >= 1)
            assert.is_true(result.total >= 2)
         end)
      end)

      describe("get_line_hits", function()
         it("returns line hits derived from PC data", function()
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

            local result = branchcov.get_line_hits(func)
            assert.is_table(result)
            assert.is_number(result.max)
            assert.is_true(result.max > 0)

            local hit_count = 0
            for k, v in pairs(result) do
               if type(k) == "number" and v > 0 then
                  hit_count = hit_count + 1
               end
            end
            assert.is_true(hit_count >= 1)
         end)
      end)
   end
end)
