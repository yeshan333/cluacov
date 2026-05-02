local M = {}

function M.classify(n)
   if n > 0 then
      return "positive"
   elseif n == 0 then
      return "zero"
   else
      return "negative"
   end
end

function M.abs(x)
   if x < 0 then
      return -x
   end
   return x
end

function M.clamp(x, lo, hi)
   if x < lo then
      return lo
   elseif x > hi then
      return hi
   end
   return x
end

function M.sum(t)
   local total = 0
   for i = 1, #t do
      total = total + t[i]
   end
   return total
end

function M.find(t, value)
   for _, v in ipairs(t) do
      if v == value then
         return true
      end
   end
   return false
end

function M.safe_div(a, b)
   if b == 0 then
      return nil, "division by zero"
   end
   return a / b
end

function M.fizzbuzz(n)
   if n % 15 == 0 then
      return "fizzbuzz"
   elseif n % 3 == 0 then
      return "fizz"
   elseif n % 5 == 0 then
      return "buzz"
   else
      return tostring(n)
   end
end

function M.max_of_three(a, b, c)
   if a >= b and a >= c then
      return a
   elseif b >= c then
      return b
   else
      return c
   end
end

function M.any_truthy(a, b, c)
   if a or b or c then
      return "yes"
   else
      return "no"
   end
end

function M.all_truthy(a, b, c)
   if a and b and c then
      return "all"
   else
      return "not all"
   end
end

function M.mixed_logic(x, y)
   if (x > 0 and y > 0) or (x < -10) then
      return "match"
   else
      return "no match"
   end
end

-- Regression target: function-body first line must be HIT.
-- Before the savedpc-off-by-one fix in collect_line_hits_recursive,
-- the very first executable line of a function body (`local t = ...`
-- right after the function header) was reported with hits = 0,
-- because the hits-table key (savedpc - code) is the NEXT instruction's
-- PC and the line aggregator was reading it without the -1 shift.
function M.first_line_local(cobj)
   local t = cobj.kind            -- regression: function-body first line
   if t == "ok" then
      return "ok:" .. t
   end
   return "skip"
end

-- Regression target: first executable line INSIDE an if-block.
-- Same root cause as above. Before the fix this `local cleaned = v` line
-- consistently reported 0, even though the if-block was clearly entered
-- (the next line, `out[#out+1] = cleaned`, absorbed the missing hits).
-- Mirrors the real-world pattern from Path.join_path that triggered
-- the original bug report.
function M.if_block_first_line(items)
   local out = {}
   for _, v in ipairs(items) do
      if type(v) == "string" then
         local cleaned = v        -- regression: if-block first line
         out[#out + 1] = cleaned
      end
   end
   return out
end

return M
