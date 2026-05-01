local M = {}

function M.filter(branches)
   local line_counts = {}
   for _, branch in ipairs(branches) do
      line_counts[branch.line] = (line_counts[branch.line] or 0) + 1
   end

   local result = {}
   local skipped = 0
   local seen_target_pairs = {}

   for _, branch in ipairs(branches) do
      if line_counts[branch.line] == 1 then
         result[#result + 1] = branch
      else
         local t1 = branch.targets[1].line
         local t2 = branch.targets[2].line
         if t1 ~= branch.line and t2 ~= branch.line then
            local key = branch.line .. ":" .. t1 .. ":" .. t2
            if not seen_target_pairs[key] then
               seen_target_pairs[key] = true
               result[#result + 1] = branch
            else
               skipped = skipped + 1
            end
         else
            skipped = skipped + 1
         end
      end
   end

   return result, skipped
end

return M
