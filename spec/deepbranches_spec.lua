-- luacheck: std +busted
local deepbranches = require "cluacov.deepbranches"
local load = loadstring or load -- luacheck: compat

local function load_function(source)
   return assert(load(source))()
end

local function normalize(branches)
   table.sort(branches, function(a, b)
      if a.line == b.line then
         return a.pc < b.pc
      end

      return a.line < b.line
   end)

   for _, branch in ipairs(branches) do
      table.sort(branch.targets, function(a, b)
         return a.pc < b.pc
      end)
   end

   return branches
end

local function branch_lines(branch)
   local lines = {}

   for _, target in ipairs(branch.targets) do
      lines[#lines + 1] = target.line
   end

   return lines
end

local function has_branch(branches, line, target_lines)
   for _, branch in ipairs(branches) do
      local lines = branch_lines(branch)

      if branch.line == line and #lines == #target_lines then
         local matched = true

         for i, target_line in ipairs(target_lines) do
            if lines[i] ~= target_line then
               matched = false
            end
         end

         if matched then
            return true
         end
      end
   end

   return false
end

describe("deepbranches", function()
   describe("version", function()
      it("is a string in MAJOR.MINOR.PATCH format", function()
         assert.match("^%d+%.%d+%.%d+$", deepbranches.version)
      end)
   end)

   describe("get", function()
      it("throws error if the argument is not a function", function()
         assert.error(function() deepbranches.get(5) end)
      end)

      it("throws error if the argument is a C function", function()
         assert.error(function() deepbranches.get(deepbranches.get) end)
      end)

      if jit then
         it("returns an empty list on LuaJIT", function()
            assert.same({}, deepbranches.get(function(a, b, c)
               return a and b or c
            end))
         end)
      else
         it("finds branches for if/else conditionals", function()
            local branches = normalize(deepbranches.get(load_function([[
               return function(a)
                  if a then
                     return 1
                  else
                     return 2
                  end
               end
            ]])))

            assert.equal(1, #branches)
            assert.equal(2, branches[1].line)
            assert.same({3, 5}, branch_lines(branches[1]))
         end)

         it("preserves multiple branch sites on the same source line", function()
            local branches = normalize(deepbranches.get(load_function([[
               return function(a, b, c)
                  return a and b or c
               end
            ]])))

            assert.equal(2, #branches)
            assert.equal(2, branches[1].line)
            assert.equal(2, branches[2].line)
            assert.is_true(branches[1].pc < branches[2].pc)
         end)

         it("finds loop branches", function()
            local branches = normalize(deepbranches.get(load_function([[
               return function(n)
                  local total = 0
                  for i = 1, n do
                     total = total + i
                  end
                  return total
               end
            ]])))

            assert.is_true(has_branch(branches, 3, {4, 6}))
         end)

         it("finds branches inside nested functions", function()
            local branches = normalize(deepbranches.get(load_function([[
               return function()
                  local function inner(flag)
                     if flag then
                        return 1
                     end
                     return 2
                  end

                  return inner
               end
            ]])))

            assert.equal(1, #branches)
            assert.equal(3, branches[1].line)
            assert.same({4, 6}, branch_lines(branches[1]))
         end)

         it("finds generic for iterator branches", function()
            local branches = normalize(deepbranches.get(load_function([[
               return function(xs)
                  for _, x in ipairs(xs) do
                     if x then
                        return x
                     end
                  end
               end
            ]])))

            assert.is_true(has_branch(branches, 2, {3, 7}))
         end)

         it("returns an empty list for stripped functions", function()
            local stripped = load(string.dump(load_function([[
               return function(a)
                  if a then
                     return 1
                  end

                  return 2
               end
            ]]), true))

            if next(debug.getinfo(stripped, "L").activelines) then
               pending("string.dump can not strip functions")
            end

            assert.same({}, deepbranches.get(stripped))
         end)
      end
   end)
end)
