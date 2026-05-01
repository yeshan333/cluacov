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

return M
