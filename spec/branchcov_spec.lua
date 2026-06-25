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

   local lua_version = tonumber(_VERSION:match("(%d+%.%d+)"))

   if jit or lua_version < 5.4 then
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

         it("distinguishes protos that only differ by lastlinedefined", function()
            local saved_branchcov = package.loaded["cluacov.branchcov"]
            local saved_deepbranches = package.loaded["cluacov.deepbranches"]
            local saved_pchook = package.loaded["cluacov.pchook"]

            package.loaded["cluacov.branchcov"] = nil
            package.loaded["cluacov.deepbranches"] = {
               get = function()
                  return {
                     {
                        line = 10,
                        pc = 1,
                        kind = "test",
                        linedefined = 3,
                        lastlinedefined = 5,
                        sizecode = 7,
                        targets = {
                           { pc = 2, line = 11 },
                           { pc = 3, line = 12 },
                        },
                     },
                     {
                        line = 20,
                        pc = 1,
                        kind = "test",
                        linedefined = 3,
                        lastlinedefined = 8,
                        sizecode = 7,
                        targets = {
                           { pc = 2, line = 21 },
                           { pc = 3, line = 22 },
                        },
                     },
                  }
               end,
            }
            package.loaded["cluacov.pchook"] = {
               get_hits = function()
                  return {
                     {
                        linedefined = 3,
                        lastlinedefined = 5,
                        sizecode = 7,
                        hits = { [1] = 1, [2] = 4 },
                     },
                     {
                        linedefined = 3,
                        lastlinedefined = 8,
                        sizecode = 7,
                        hits = { [1] = 1, [3] = 6 },
                     },
                  }
               end,
               get_line_hits = function()
                  return {}
               end,
            }

            local fake_branchcov = require("cluacov.branchcov")
            local result = fake_branchcov.analyze(function() end)

            package.loaded["cluacov.branchcov"] = saved_branchcov
            package.loaded["cluacov.deepbranches"] = saved_deepbranches
            package.loaded["cluacov.pchook"] = saved_pchook

            assert.equal(2, #result.branches)
            assert.equal(4, result.branches[1].targets[1].hits)
            assert.equal(0, result.branches[1].targets[2].hits)
            assert.equal(0, result.branches[2].targets[1].hits)
            assert.equal(6, result.branches[2].targets[2].hits)
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

         it("handles lua assert as branch", function()
            local func = load_function([[
               return function(x)
                  assert(x)
                  return 3
               end
            ]])

            -- Scenario 1: Only true case executed
            pchook.start()
            func(true)
            pchook.stop()

            local result = branchcov.analyze(func)
            assert.equal(1, #result.branches)
            local branch = result.branches[1]
            assert.equal("assert", branch.kind)
            assert.equal("partial", branch.status)
            -- Check targets: one should have hit > 0, the other should be 0.
            local success_hits = 0
            local failure_hits = 0
            for _, t in ipairs(branch.targets) do
               if t.pc < 0 then
                  failure_hits = t.hits
               else
                  success_hits = t.hits
               end
            end
            assert.equal(1, success_hits)
            assert.equal(0, failure_hits)

            -- Scenario 2: Both true and false cases executed
            pchook.reset()
            pchook.start()
            func(true)
            pcall(func, false)
            pchook.stop()

            result = branchcov.analyze(func)
            branch = result.branches[1]
            assert.equal("covered", branch.status)
            for _, t in ipairs(branch.targets) do
               if t.pc < 0 then
                  failure_hits = t.hits
               else
                  success_hits = t.hits
               end
            end
            assert.equal(1, success_hits)
            assert.equal(1, failure_hits)
         end)

         it("safely ignores assert tail calls", function()
            local func = load_function([[
               return function(x)
                  return assert(x)
               end
            ]])

            pchook.start()
            func(true)
            pchook.stop()

            local result = branchcov.analyze(func)
            assert.equal(0, #result.branches)
         end)

         it("handles nested assert wrapped inside pcall", function()
            local func = load_function([[
               return function(x)
                  pcall(function()
                     assert(x)
                  end)
               end
            ]])

            pchook.start()
            func(true)
            func(false)
            pchook.stop()

            local result = branchcov.analyze(func)
            local assert_branch = nil
            for _, b in ipairs(result.branches) do
               if b.kind == "assert" then
                  assert_branch = b
                  break
               end
            end
            assert.is_not_nil(assert_branch)
            assert.equal("covered", assert_branch.status)
         end)

         it("handles aliased assert upvalues correctly", function()
            local func = load_function([[
               return function(x)
                  local assert = assert
                  local inner = function(y)
                     assert(y)
                  end
                  inner(x)
                  return inner
               end
            ]])

            pchook.start()
            local inner = func(true)
            pcall(inner, false)
            pchook.stop()

            local result = branchcov.analyze(func)
            local assert_branch = nil
            for _, b in ipairs(result.branches) do
               if b.kind == "assert" then
                  assert_branch = b
                  break
               end
            end
            assert.is_not_nil(assert_branch)
            assert.equal("covered", assert_branch.status)
         end)

         it("safely ignores non-assert named upvalue aliases", function()
            local func = load_function([[
               return function(x)
                  local my_assert = assert
                  local inner = function(y)
                     my_assert(y)
                  end
                  inner(x)
                  return inner
               end
            ]])

            pchook.start()
            local inner = func(true)
            pchook.stop()

            local result = branchcov.analyze(func)
            local assert_branch = nil
            for _, b in ipairs(result.branches) do
               if b.kind == "assert" then
                  assert_branch = b
                  break
               end
            end
            assert.is_nil(assert_branch)
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
