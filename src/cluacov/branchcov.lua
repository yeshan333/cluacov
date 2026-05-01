local deepbranches = require("cluacov.deepbranches")
local pchook = require("cluacov.pchook")

local M = {}

function M.analyze(func)
   local branches = deepbranches.get(func)
   local all_hits = pchook.get_hits(func)

   local hits_by_func = {}
   for _, entry in ipairs(all_hits) do
      hits_by_func[entry.linedefined] = entry.hits
   end

   local result_branches = {}
   local total = 0
   local hit = 0

   for _, branch in ipairs(branches) do
      local proto_hits = hits_by_func[branch.linedefined] or {}
      local targets = {}
      local targets_hit = 0

      for _, target in ipairs(branch.targets) do
         local target_hits = proto_hits[target.pc] or 0
         targets[#targets + 1] = {
            pc = target.pc,
            line = target.line,
            hits = target_hits,
         }
         total = total + 1
         if target_hits > 0 then
            hit = hit + 1
            targets_hit = targets_hit + 1
         end
      end

      local status
      if targets_hit == #targets then
         status = "covered"
      elseif targets_hit > 0 then
         status = "partial"
      else
         status = "uncovered"
      end

      result_branches[#result_branches + 1] = {
         line = branch.line,
         pc = branch.pc,
         kind = branch.kind,
         linedefined = branch.linedefined,
         targets = targets,
         status = status,
      }
   end

   return {
      branches = result_branches,
      total = total,
      hit = hit,
   }
end

function M.get_line_hits(func)
   return pchook.get_line_hits(func)
end

return M
