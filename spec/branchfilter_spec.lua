-- luacheck: std +busted
local branchfilter = require "cluacov.branchfilter"

local function make_branch(line, kind, t1_line, t2_line)
   return {
      line = line, pc = 1, kind = kind, linedefined = 1,
      targets = {
         { line = t1_line, pc = 1 },
         { line = t2_line, pc = 2 },
      }
   }
end

describe("branchfilter", function()
   describe("filter", function()
      it("keeps single branches on a line unchanged", function()
         local branches = {
            make_branch(4, "test", 5, 7),
         }
         local result, skipped = branchfilter.filter(branches)
         assert.equal(1, #result)
         assert.equal(0, skipped)
         assert.equal(4, result[1].line)
      end)

      it("skips branches with a same-line target", function()
         local branches = {
            make_branch(10, "test", 10, 11),
            make_branch(10, "test", 10, 11),
            make_branch(10, "test", 11, 13),
         }
         local result, skipped = branchfilter.filter(branches)
         assert.equal(1, #result)
         assert.equal(2, skipped)
         assert.equal(11, result[1].targets[1].line)
         assert.equal(13, result[1].targets[2].line)
      end)

      it("deduplicates same target-line pairs on the same line", function()
         local branches = {
            make_branch(5, "loop-entry", 6, 8),
            make_branch(5, "loop", 6, 8),
         }
         local result, skipped = branchfilter.filter(branches)
         assert.equal(1, #result)
         assert.equal(1, skipped)
      end)

      it("keeps branches from different lines independently", function()
         local branches = {
            make_branch(4, "test", 5, 7),
            make_branch(8, "test", 9, 11),
         }
         local result, skipped = branchfilter.filter(branches)
         assert.equal(2, #result)
         assert.equal(0, skipped)
      end)

      it("handles compound or: if a or b or c", function()
         local branches = {
            make_branch(10, "test", 10, 11),
            make_branch(10, "test", 10, 11),
            make_branch(10, "test", 11, 13),
         }
         local result, skipped = branchfilter.filter(branches)
         assert.equal(1, #result)
         assert.equal(2, skipped)
         assert.equal("test", result[1].kind)
      end)

      it("handles compound and: if a and b", function()
         local branches = {
            make_branch(10, "test", 10, 13),
            make_branch(10, "test", 11, 13),
         }
         local result, skipped = branchfilter.filter(branches)
         assert.equal(1, #result)
         assert.equal(1, skipped)
      end)

      it("returns empty for empty input", function()
         local result, skipped = branchfilter.filter({})
         assert.equal(0, #result)
         assert.equal(0, skipped)
      end)
   end)
end)
