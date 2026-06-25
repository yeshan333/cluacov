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

-- ===========================================================================
-- Lua-language showcase block (line 132+).
--
-- Everything ABOVE this line is locked: the e2e suite asserts on hard-coded
-- line numbers (L30, L76, L84, L106, L108, L123). DO NOT shuffle those.
--
-- Everything BELOW intentionally exercises a wide variety of Lua control
-- flow / syntax to make the public coverage demo richer:
--
--   * while / break / repeat-until
--   * numeric-for with explicit step (incl. negative)
--   * generic-for with pairs / ipairs early-return
--   * deeply nested if / elseif chains
--   * short-circuit `or` / `and` for default values & ternary
--   * pcall / xpcall error capture branches
--   * goto / continue idiom (Lua 5.2+)
--   * vararg `...` + select
--   * multiple return values + destructuring
--   * closures with upvalues, factory pattern
--   * direct recursion + mutual recursion
--   * metatable __index / __call dispatch
--   * string-keyed dispatch table
--   * method-call colon syntax
--
-- run_test.lua deliberately exercises ONLY a subset of the paths so the
-- public HTML report shows a believable mix of red & green lines, which
-- is exactly what someone evaluating cluacov wants to see.
-- ===========================================================================

-- while + break: walks t looking for `target`, returns the 1-based index
-- (or nil if absent). The break path is only taken when target is found
-- in the middle of the table.
function M.while_break(t, target)
   local i = 1
   while i <= #t do
      if t[i] == target then
         break
      end
      i = i + 1
   end
   if i > #t then
      return nil
   end
   return i
end

-- repeat..until: collects squares until the running total exceeds limit.
-- The until-condition is evaluated AFTER the body runs at least once.
function M.repeat_until(limit)
   local i = 0
   local total = 0
   repeat
      i = i + 1
      total = total + i * i
   until total >= limit
   return i, total
end

-- numeric for with explicit (and possibly negative) step. Three branches
-- on the step sign let cluacov demonstrate "branch not taken" rendering
-- when the caller never exercises a particular step direction.
function M.for_step(start_n, stop_n, step)
   local out = {}
   if step == 0 then
      return nil, "step cannot be zero"
   end
   for i = start_n, stop_n, step do
      out[#out + 1] = i
   end
   return out
end

-- generic-for with pairs + early return. `pairs` ordering is undefined,
-- but the early-return branch is deterministic when key is present.
function M.find_in_map(map, key)
   for k, v in pairs(map) do
      if k == key then
         return v, true
      end
   end
   return nil, false
end

-- Deeply nested if/elseif (HTTP status code classifier). Designed to
-- have many branches; run_test.lua only covers some of them.
function M.classify_status(code)
   if code >= 500 then
      if code == 503 then
         return "unavailable"
      elseif code == 504 then
         return "gateway timeout"
      else
         return "server error"
      end
   elseif code >= 400 then
      if code == 404 then
         return "not found"
      elseif code == 401 or code == 403 then
         return "auth error"
      else
         return "client error"
      end
   elseif code >= 300 then
      return "redirect"
   elseif code >= 200 then
      return "ok"
   else
      return "informational"
   end
end

-- Short-circuit `or` for default values. The default branch (a == nil)
-- is only taken when caller passes nil.
function M.with_default(a, default)
   local v = a or default
   return v
end

-- Lua's idiomatic ternary: `cond and then_value or else_value`.
-- The pitfall (then_value being false/nil) is intentionally NOT guarded
-- here so cluacov shows both branch arms.
function M.ternary_max(a, b)
   return a > b and a or b
end

-- pcall: protected call with branch on success vs. failure.
function M.try_parse_int(s)
   local ok, result = pcall(function()
      local n = tonumber(s)
      if n == nil then
         error("not a number: " .. tostring(s))
      end
      if n ~= math.floor(n) then
         error("not an integer: " .. tostring(n))
      end
      return n
   end)
   if ok then
      return result, nil
   else
      return nil, result   -- result is the error message
   end
end

-- goto/continue idiom (Lua 5.2+). Skips even numbers in the source list.
function M.sum_odd(t)
   local total = 0
   for _, v in ipairs(t) do
      if v % 2 == 0 then
         goto continue
      end
      total = total + v
      ::continue::
   end
   return total
end

-- Vararg + select: count how many args are non-nil.
function M.count_args(...)
   local n = select("#", ...)
   local count = 0
   for i = 1, n do
      if select(i, ...) ~= nil then
         count = count + 1
      end
   end
   return count
end

-- Multiple return values, exercised via destructuring at the call site.
function M.divmod(a, b)
   if b == 0 then
      return nil, nil, "division by zero"
   end
   local q = math.floor(a / b)
   local r = a - q * b
   return q, r
end

-- Closure factory: returns a counter closure capturing `count` as upvalue.
-- Each invocation returns a fresh closure with its own state.
function M.make_counter(start_n)
   local count = start_n or 0
   return function(step)
      step = step or 1
      count = count + step
      return count
   end
end

-- Direct recursion + base case. The base case is naturally taken once
-- per top-level call; the recursive case is taken for any n >= 2.
function M.factorial(n)
   if n <= 1 then
      return 1
   end
   return n * M.factorial(n - 1)
end

-- Mutual recursion (even/odd). Forward declaration via local.
local is_even, is_odd
function is_even(n)
   if n == 0 then return true end
   return is_odd(n - 1)
end
function is_odd(n)
   if n == 0 then return false end
   return is_even(n - 1)
end
M.is_even = is_even
M.is_odd  = is_odd

-- String-keyed dispatch table: typical alternative to long if/elseif.
-- The fallback branch (unknown verb) is only hit when caller passes an
-- unknown key.
local dispatch = {
   add = function(a, b) return a + b end,
   sub = function(a, b) return a - b end,
   mul = function(a, b) return a * b end,
   div = function(a, b)
      if b == 0 then return nil, "div by zero" end
      return a / b
   end,
}
function M.dispatch(op, a, b)
   local fn = dispatch[op]
   if not fn then
      return nil, "unknown op: " .. tostring(op)
   end
   return fn(a, b)
end

-- Metatable __index + colon-syntax method call. The `Point` "class"
-- mixes both data fields and bound methods.
local Point = {}
Point.__index = Point
function Point.new(x, y)
   return setmetatable({ x = x, y = y }, Point)
end
function Point:translate(dx, dy)
   self.x = self.x + dx
   self.y = self.y + dy
   return self
end
function Point:length()
   return math.sqrt(self.x * self.x + self.y * self.y)
end
M.Point = Point

-- table.concat with separator + conditional empty branch.
function M.join(t, sep)
   if #t == 0 then
      return ""
   end
   return table.concat(t, sep or ",")
end

-- goto/continue: accumulates only non-negative values.
-- Both branches of `if v < 0` are exercisable:
--   taken    → goto skip (negative input)
--   not taken → total = total + v (non-negative input)
function M.goto_filter(t)
   local total = 0
   for _, v in ipairs(t) do
      if v < 0 then
         goto skip
      end
      total = total + v
      ::skip::
   end
   return total
end

-- goto with multiple forward labels: returns the first positive value,
-- or -1 if none found.
--   if v > 0  → goto found  (early exit with value)
--   end of loop → goto done (fall-through, no positive found)
function M.goto_first_match(t)
   local result = -1
   for _, v in ipairs(t) do
      if v > 0 then
         result = v
         goto found
      end
   end
   goto done
   ::found::
   ::done::
   return result
end

-- goto uncovered: never called from run_test.lua, so the conditional
-- goto branch stays fully uncovered in the report.
function M.goto_early_return(err)
   local result
   if err then
      goto bail
   end
   result = "ok"
   ::bail::
   if result then return result end
   return nil, err
end

-- assert: exercises assert branches
function M.verify_assert(val)
   assert(val, "value must be truthy")
   return "ok"
end

-- assert: exercises partial assert branches (always true)
function M.verify_partial_assert(val)
   assert(val, "always true in test")
   return "partial-ok"
end

return M
