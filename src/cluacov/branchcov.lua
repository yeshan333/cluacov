local deepbranches = require("cluacov.deepbranches")
local pchook = require("cluacov.pchook")

local M = {}

local function proto_key(proto)
   if proto.proto_id then return proto.proto_id end
   return table.concat({
      proto.linedefined or 0,
      proto.lastlinedefined or 0,
      proto.sizecode or 0,
   }, ":")
end

-- Share the exact same edge interpretation with the LCOV writer. An absent
-- source instruction never acquires hits from a converging control-flow path.
function M.target_hits(branch, target, entry)
   entry = entry or {}
   local hits = entry.hits or {}
   if (hits[branch.pc] or 0) + (hits[branch.entry_pc] or 0) == 0 then return 0 end
   local successors = entry.edges and entry.edges[branch.pc] or {}
   if target.pc < 0 then
      local call_pc = -target.pc
      local successes = entry.edges and (successors[call_pc + 1] or 0)
         or (hits[call_pc + 1] or 0)
      return math.max(0, (hits[call_pc] or 0) - successes)
   end
   if entry.edges then
      local first_iteration = entry.edges[branch.entry_pc] or {}
      return (successors[target.pc] or 0) + (first_iteration[target.pc] or 0)
   end
   return hits[target.pc] or 0
end

function M.analyze(func)
   local branches = deepbranches.get(func)
   local all_hits = pchook.get_hits(func)

   local hits_by_func = {}
   for _, entry in ipairs(all_hits) do
      hits_by_func[proto_key(entry)] = entry
   end

   local result_branches = {}
   local total = 0
   local hit = 0

   for _, branch in ipairs(branches) do
      local entry = hits_by_func[proto_key(branch)]
      local targets = {}
      local targets_hit = 0

      for _, target in ipairs(branch.targets) do
         local target_hits = M.target_hits(branch, target, entry)
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
