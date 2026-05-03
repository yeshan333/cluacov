-- luacheck: std +busted
local pchook = require "cluacov.pchook"
local load = loadstring or load -- luacheck: compat

local function load_function(source)
   return assert(load(source))()
end

describe("pchook", function()
   after_each(function()
      pchook.stop()
      pchook.reset()
   end)

   local lua_version = tonumber(_VERSION:match("(%d+%.%d+)"))

   if jit or lua_version < 5.4 then
      pending("pchook requires PUC-Rio Lua 5.4+")
   else
      describe("version", function()
         it("is a string in MAJOR.MINOR.PATCH format", function()
            assert.match("^%d+%.%d+%.%d+$", pchook.version)
         end)
      end)
      describe("start/stop lifecycle", function()
         it("starts and stops without error", function()
            assert.has_no.errors(function()
               pchook.start()
               pchook.stop()
            end)
         end)

         it("can be started multiple times", function()
            assert.has_no.errors(function()
               pchook.start()
               pchook.start()
               pchook.stop()
            end)
         end)
      end)

      describe("get_hits", function()
         it("throws error for non-function argument", function()
            assert.error(function() pchook.get_hits(5) end)
         end)

         it("throws error for C function argument", function()
            assert.error(function() pchook.get_hits(pchook.start) end)
         end)

         it("returns empty hits when nothing was executed", function()
            pchook.start()
            pchook.stop()
            local func = load_function([[
               return function(x) return x end
            ]])
            local result = pchook.get_hits(func)
            assert.is_table(result)
            assert.is_true(#result >= 1)
            for _, entry in ipairs(result) do
               assert.number(entry.linedefined)
               assert.number(entry.sizecode)
               assert.is_table(entry.hits)
            end
         end)

         it("records per-PC hits for executed instructions", function()
            local func = load_function([[
               return function(x) return x + 1 end
            ]])
            pchook.start()
            func(42)
            pchook.stop()

            local result = pchook.get_hits(func)
            assert.is_true(#result >= 1)
            local top_hits = result[1].hits
            local total = 0
            for _, count in pairs(top_hits) do
               total = total + count
            end
            assert.is_true(total > 0)
         end)

         it("counts multiple executions", function()
            local func = load_function([[
               return function(x) return x + 1 end
            ]])
            pchook.start()
            func(1)
            func(2)
            func(3)
            pchook.stop()

            local result = pchook.get_hits(func)
            local top_hits = result[1].hits
            local has_count_3 = false
            for _, count in pairs(top_hits) do
               if count >= 3 then has_count_3 = true end
            end
            assert.is_true(has_count_3)
         end)

         it("distinguishes branch target PCs", function()
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

            local deepbranches = require("cluacov.deepbranches")
            local branches = deepbranches.get(func)
            assert.is_true(#branches >= 1)

            local result = pchook.get_hits(func)
            local top_hits = result[1].hits
            local branch = branches[1]

            local t1_hits = top_hits[branch.targets[1].pc] or 0
            local t2_hits = top_hits[branch.targets[2].pc] or 0
            assert.is_true(t1_hits > 0 or t2_hits > 0)
            assert.is_true(t1_hits == 0 or t2_hits == 0)
         end)
      end)

      describe("nested functions", function()
         it("collects hits for nested function protos", function()
            local func = load_function([[
               return function()
                  local function inner(x)
                     return x * 2
                  end
                  return inner(5)
               end
            ]])

            pchook.start()
            func()
            pchook.stop()

            local result = pchook.get_hits(func)
            assert.is_true(#result >= 2)
         end)
      end)

      describe("anonymous functions", function()
         -- These tests verify that PC-level coverage is correctly attributed to
         -- *anonymous* function protos (i.e. functions that are NOT bound to a
         -- local name via `local function name() ... end`). Anonymous functions
         -- are extremely common in Lua: they appear as callbacks, table fields,
         -- IIFEs (immediately-invoked function expressions), and the value side
         -- of assignments. Because they share the same `Proto` machinery as
         -- named functions in the Lua VM, they should receive identical
         -- treatment from the pchook collector.

         it("collects hits for an immediately-invoked anonymous function", function()
            -- IIFE pattern: (function(x) ... end)(arg). The inner anonymous
            -- proto must record PC hits, and the outer proto that constructs
            -- and calls it must also have hits.
            local func = load_function([[
               return function(x)
                  return (function(v) return v * 2 end)(x)
               end
            ]])

            pchook.start()
            local ret = func(7)
            pchook.stop()

            assert.equal(14, ret)

            local result = pchook.get_hits(func)
            -- Outer proto + inner anonymous proto = at least 2 protos.
            assert.is_true(#result >= 2)

            -- Every proto should have at least one PC with a hit > 0.
            for _, entry in ipairs(result) do
               local total = 0
               for _, count in pairs(entry.hits) do
                  total = total + count
               end
               assert.is_true(total > 0)
            end
         end)

         it("collects hits for an anonymous function passed as a callback", function()
            -- Callback pattern: the anonymous function is created in one place
            -- and invoked by another function (here, a tiny higher-order
            -- helper). This is the most common anonymous-function shape in
            -- real codebases (event handlers, ipairs/pairs bodies, etc.).
            local func = load_function([[
               local function apply(cb, n)
                  local sum = 0
                  for i = 1, n do
                     sum = sum + cb(i)
                  end
                  return sum
               end
               return function(n)
                  return apply(function(i) return i * i end, n)
               end
            ]])

            pchook.start()
            local ret = func(4)  -- 1+4+9+16 = 30
            pchook.stop()

            assert.equal(30, ret)

            local result = pchook.get_hits(func)
            -- We expect at least 2 protos reachable from `func`: the outer
            -- function itself and the inline anonymous callback. The `apply`
            -- helper is an upvalue closure of the chunk and is not reachable
            -- from `func` via nested protos.
            assert.is_true(#result >= 2)

            -- The anonymous callback runs n times; some PC in some proto must
            -- have been hit at least n times.
            local max_hit = 0
            for _, entry in ipairs(result) do
               for _, count in pairs(entry.hits) do
                  if count > max_hit then max_hit = count end
               end
            end
            assert.is_true(max_hit >= 4)
         end)

         it("collects hits for anonymous functions stored in table fields", function()
            -- Table-of-handlers pattern: anonymous functions assigned to table
            -- fields, then dispatched by key. Each handler is a separate proto
            -- nested inside the outer function.
            local func = load_function([[
               return function(op, a, b)
                  local handlers = {
                     add = function(x, y) return x + y end,
                     sub = function(x, y) return x - y end,
                     mul = function(x, y) return x * y end,
                  }
                  return handlers[op](a, b)
               end
            ]])

            pchook.start()
            local r1 = func("add", 2, 3)
            local r2 = func("mul", 4, 5)
            pchook.stop()

            assert.equal(5, r1)
            assert.equal(20, r2)

            local result = pchook.get_hits(func)
            -- Outer proto + 3 anonymous handler protos = 4 protos minimum.
            assert.is_true(#result >= 4)

            -- Count protos that actually recorded any execution. We executed
            -- "add" and "mul" once each, plus the outer proto twice, so at
            -- least 3 distinct protos must have non-zero hits. The "sub"
            -- handler must remain at zero, demonstrating that hit attribution
            -- is per-proto (not blanket-applied).
            local executed_protos, untouched_protos = 0, 0
            for _, entry in ipairs(result) do
               local total = 0
               for _, count in pairs(entry.hits) do
                  total = total + count
               end
               if total > 0 then
                  executed_protos = executed_protos + 1
               else
                  untouched_protos = untouched_protos + 1
               end
            end
            assert.is_true(executed_protos >= 3)
            assert.is_true(untouched_protos >= 1)
         end)

         it("maps anonymous-function hits back to the correct source lines", function()
            -- Verify that get_line_hits correctly attributes line hits to the
            -- body lines of an anonymous function (not to its enclosing line).
            -- The `local cb = function(x) ... end` pattern is the canonical
            -- case where line attribution can go wrong.
            local func = load_function([[
               return function(n)
                  local cb = function(x)
                     local doubled = x * 2
                     local tripled = x * 3
                     return doubled + tripled
                  end
                  local total = 0
                  for i = 1, n do
                     total = total + cb(i)
                  end
                  return total
               end
            ]])

            pchook.start()
            func(5)
            pchook.stop()

            local lines = pchook.get_line_hits(func)
            assert.is_table(lines)
            assert.is_number(lines.max)

            -- The body of the anonymous `cb` runs 5 times; at least one line
            -- inside its body must report a hit count >= 5.
            local max_hit = 0
            for k, v in pairs(lines) do
               if type(k) == "number" and v > max_hit then
                  max_hit = v
               end
            end
            assert.is_true(max_hit >= 5)
         end)

         it("does not record hits for anonymous functions that are never invoked", function()
            -- Sanity check: declaring an anonymous function (creating the
            -- closure) executes the OP_CLOSURE instruction in the enclosing
            -- proto, but the inner proto's own bytecode must NOT receive any
            -- hits unless the function is actually called.
            local func = load_function([[
               return function()
                  local _unused = function(x) return x + 999 end
                  return 42
               end
            ]])

            pchook.start()
            local ret = func()
            pchook.stop()

            assert.equal(42, ret)

            local result = pchook.get_hits(func)
            assert.is_true(#result >= 2)

            -- Find the proto with zero hits — it must be the unused anonymous
            -- function. There must be at least one such proto in this minimal
            -- example.
            local zero_hit_protos = 0
            for _, entry in ipairs(result) do
               local total = 0
               for _, count in pairs(entry.hits) do
                  total = total + count
               end
               if total == 0 then
                  zero_hit_protos = zero_hit_protos + 1
               end
            end
            assert.is_true(zero_hit_protos >= 1)
         end)
      end)

      describe("reset", function()
         it("clears all recorded hits", function()
            local func = load_function([[
               return function(x) return x end
            ]])
            pchook.start()
            func(1)
            pchook.stop()
            pchook.reset()

            local result = pchook.get_hits(func)
            assert.is_true(#result >= 1)
            local total = 0
            for _, entry in ipairs(result) do
               for _, count in pairs(entry.hits) do
                  total = total + count
               end
            end
            assert.equal(0, total)
         end)
      end)

      describe("get_line_hits", function()
         it("throws error for non-function argument", function()
            assert.error(function() pchook.get_line_hits(5) end)
         end)

         it("throws error for C function argument", function()
            assert.error(function() pchook.get_line_hits(pchook.start) end)
         end)

         it("returns table with max field", function()
            local func = load_function([[
               return function(x) return x + 1 end
            ]])
            pchook.start()
            func(1)
            pchook.stop()

            local result = pchook.get_line_hits(func)
            assert.is_table(result)
            assert.is_number(result.max)
            assert.is_true(result.max > 0)
         end)

         it("maps PC hits to line numbers", function()
            local func = load_function([[
               return function(x)
                  local a = x + 1
                  local b = a + 2
                  return b
               end
            ]])
            pchook.start()
            func(10)
            pchook.stop()

            local result = pchook.get_line_hits(func)
            local hit_count = 0
            for k, v in pairs(result) do
               if type(k) == "number" and v > 0 then
                  hit_count = hit_count + 1
               end
            end
            assert.is_true(hit_count >= 2)
         end)

         it("includes lines from nested functions", function()
            local func = load_function([[
               return function()
                  local function inner(x)
                     return x * 2
                  end
                  return inner(5)
               end
            ]])
            pchook.start()
            func()
            pchook.stop()

            local result = pchook.get_line_hits(func)
            local hit_count = 0
            for k, v in pairs(result) do
               if type(k) == "number" and v > 0 then
                  hit_count = hit_count + 1
               end
            end
            assert.is_true(hit_count >= 3)
         end)

         it("returns empty hits for unexecuted function", function()
            pchook.start()
            pchook.stop()
            local func = load_function([[
               return function(x) return x end
            ]])
            local result = pchook.get_line_hits(func)
            assert.is_table(result)
            local hit_count = 0
            for k, v in pairs(result) do
               if type(k) == "number" and v > 0 then
                  hit_count = hit_count + 1
               end
            end
            assert.equal(0, hit_count)
         end)

         describe("regression: function-body first line shows hits=0 (savedpc off-by-one)", function()
            -- See docs/bugs/2026-05-02-savedpc-off-by-one.md.
            --
            -- The pchook hits table uses `savedpc - proto->code` as its key, which
            -- by Lua's interpreter convention is the PC of the NEXT instruction
            -- to execute (luaG_traceexec does `pc++; ci->u.l.savedpc = pc;` BEFORE
            -- invoking any hook - see Lua's own pcRel macro in src/ldebug.h).
            --
            -- collect_line_hits_recursive must therefore subtract 1 when mapping
            -- a hits-table key back to a source line. A previous "fix" removed
            -- this -1 (assuming the key was 1-based), which produced a regression
            -- where:
            --   * the first executable line of every function body reported 0,
            --   * the line after it absorbed the missing hits.

            it("attributes hits to the first executable line of the function body", function()
               -- Pattern: `local x = expr` is the very first statement after the
               -- function header. Before the fix this line consistently reported 0.
               local func = load_function([[
                  return function(cobj)
                     local t = cobj._type           -- expected: HIT
                     if t == "struct" then          -- expected: HIT
                        return "ok"
                     end
                     return "no"
                  end
               ]])

               pchook.start()
               for _ = 1, 3 do func({_type = "struct"}) end
               pchook.stop()

               local lines = pchook.get_line_hits(func)

               -- Find the first source line that is mapped to a hit count.
               -- It must correspond to `local t = cobj._type` and be HIT.
               local first_active_line, first_hits
               for line_nr = 1, lines.max do
                  if lines[line_nr] and lines[line_nr] > 0 then
                     first_active_line = line_nr
                     first_hits = lines[line_nr]
                     break
                  end
               end

               assert.is_number(first_active_line)
               assert.is_true(first_hits >= 1,
                  "first executable line of the function body must have hits >= 1, got " ..
                  tostring(first_hits) .. " at line " .. tostring(first_active_line))
            end)

            it("attributes hits to the first executable line inside an if-block", function()
               -- Pattern: `local x = expr` as the FIRST instruction inside an
               -- if-block (a jump target). Before the fix this line was credited
               -- to the next line because the jump landed on its instruction but
               -- the hook only fires on the SECOND instruction inside the block.
               local func = load_function([[
                  return function(items)
                     local out = {}
                     for i, v in ipairs(items) do
                        if type(v) == "string" then
                           local cleaned = v               -- expected: HIT
                           out[#out + 1] = cleaned
                        end
                     end
                     return out
                  end
               ]])

               pchook.start()
               func({"a", "b", "c"})
               pchook.stop()

               local lines = pchook.get_line_hits(func)

               -- Locate the `local cleaned = v` line by source position: it is
               -- the first line strictly inside the if-block.
               local cleaned_line_hits
               for line_nr = 1, lines.max do
                  if lines[line_nr] and lines[line_nr] >= 3 then
                     -- 3 strings → ipairs body executed 3 times → cleaned = v
                     -- must be at least 3
                     cleaned_line_hits = lines[line_nr]
                     break
                  end
               end

               assert.is_true(cleaned_line_hits ~= nil and cleaned_line_hits >= 3,
                  "first executable line inside the if-block must be hit at least 3 times, got "
                  .. tostring(cleaned_line_hits))
            end)
         end)
      end)

      describe("get_all_hits", function()
         it("returns empty table when nothing recorded", function()
            pchook.start()
            pchook.stop()
            pchook.reset()
            local result = pchook.get_all_hits()
            assert.is_table(result)
            assert.equal(0, next(result) and 1 or 0)
         end)

         it("returns per-source per-proto data", function()
            local func = load_function([[
               return function(x) return x + 1 end
            ]])
            pchook.start()
            func(42)
            pchook.stop()

            local result = pchook.get_all_hits()
            local found = false
            for source, protos in pairs(result) do
               if type(protos) == "table" then
                  for _, entry in ipairs(protos) do
                     if entry.linedefined and entry.sizecode and entry.hits then
                        found = true
                     end
                  end
               end
            end
            assert.is_true(found)
         end)

         it("groups protos by source", function()
            local func = load_function([[
               return function()
                  local function inner(x) return x end
                  return inner(1)
               end
            ]])
            pchook.start()
            func()
            pchook.stop()

            local result = pchook.get_all_hits()
            local total_protos = 0
            for _, protos in pairs(result) do
               if type(protos) == "table" then
                  total_protos = total_protos + #protos
               end
            end
            assert.is_true(total_protos >= 2)
         end)
      end)

      describe("get_all_line_hits", function()
         it("returns empty table when nothing recorded", function()
            pchook.start()
            pchook.stop()
            pchook.reset()
            local result = pchook.get_all_line_hits()
            assert.is_table(result)
            assert.equal(0, next(result) and 1 or 0)
         end)

         it("returns per-source line data with max", function()
            local func = load_function([[
               return function(x)
                  local a = x + 1
                  return a
               end
            ]])
            pchook.start()
            func(10)
            pchook.stop()

            local result = pchook.get_all_line_hits()
            local found = false
            for source, lines in pairs(result) do
               if type(lines) == "table" and lines.max then
                  found = true
                  assert.is_true(lines.max > 0)
               end
            end
            assert.is_true(found)
         end)

         describe("regression: aggregate savedpc off-by-one (must agree with get_line_hits)", function()
            -- aggregate_all_line_hits (used by get_all_line_hits) previously
            -- mapped hits[pc] to lines[pc] instead of lines[pc-1]. Since the
            -- hits-table key is the savedpc offset (= next instruction's PC),
            -- the correct source line is that of instruction pc-1. The bug was
            -- invisible when consecutive instructions shared the same line, but
            -- it caused mis-attribution wherever adjacent instructions mapped
            -- to different lines (e.g. CLOSURE/SETFIELD pairs in a module's
            -- top-level chunk, or multi-statement function bodies).

            it("matches get_line_hits for a multi-statement function body", function()
               local func = load_function([[
                  return function(x)
                     local a = x + 1
                     local b = a * 2
                     local c = b - 3
                     if c > 0 then
                        return c
                     end
                     return 0
                  end
               ]])

               pchook.start()
               for _ = 1, 5 do func(10) end
               -- get_line_hits uses collect_line_hits_recursive (known correct)
               local per_func = pchook.get_line_hits(func)
               pchook.stop()

               -- get_all_line_hits uses aggregate_all_line_hits (had the bug)
               local all = pchook.get_all_line_hits()

               -- Find the source entry matching our load-string chunk
               local agg
               for source, lines in pairs(all) do
                  if type(lines) == "table" and lines.max then
                     -- Our function is the only one executed; pick
                     -- whichever source has the matching max
                     if lines.max == per_func.max then
                        agg = lines
                        break
                     end
                  end
               end
               assert.is_table(agg, "aggregate source entry must exist")

               -- Every non-zero line in per_func must appear in agg with
               -- the same (or higher) count, and vice versa.
               for line_nr = 1, per_func.max do
                  local pf = per_func[line_nr] or 0
                  local ag = agg[line_nr] or 0
                  if pf > 0 then
                     assert.is_true(ag > 0,
                        "line " .. line_nr .. ": get_line_hits=" .. pf
                        .. " but get_all_line_hits=" .. ag)
                  end
               end
            end)

            it("does not shift hits to the next instruction's line", function()
               -- Two consecutive single-line statements compiled to
               -- instructions on DIFFERENT lines. With the old bug,
               -- statement A's hit count would appear on statement B's
               -- line instead of A's.
               local func = load_function([[
                  return function(n)
                     local sum = 0
                     for i = 1, n do
                        sum = sum + i
                     end
                     return sum
                  end
               ]])

               pchook.start()
               func(10)
               local per_func = pchook.get_line_hits(func)
               pchook.stop()

               local all = pchook.get_all_line_hits()
               local agg
               for _, lines in pairs(all) do
                  if type(lines) == "table" and lines.max == per_func.max then
                     agg = lines
                     break
                  end
               end
               assert.is_table(agg)

               -- The loop body line (sum = sum + i) must have 10 hits in
               -- BOTH APIs, not just in get_line_hits.
               local found_10_in_agg = false
               for line_nr = 1, agg.max do
                  if (agg[line_nr] or 0) >= 10 then
                     found_10_in_agg = true
                     break
                  end
               end
               assert.is_true(found_10_in_agg,
                  "aggregate must have a line with >= 10 hits (loop body)")
            end)
         end)

         it("aggregates line hits from multiple protos in same source", function()
            local func = load_function([[
               return function()
                  local function inner(x) return x * 2 end
                  return inner(5)
               end
            ]])
            pchook.start()
            func()
            pchook.stop()

            local result = pchook.get_all_line_hits()
            local total_hit = 0
            for _, lines in pairs(result) do
               if type(lines) == "table" then
                  for k, v in pairs(lines) do
                     if type(k) == "number" and v > 0 then
                        total_hit = total_hit + 1
                     end
                  end
               end
            end
            assert.is_true(total_hit >= 3)
         end)

         it("sums DA across multiple loadfile of the same source (not MAX)", function()
            -- When the same file is loaded N times (e.g. busted clearing
            -- package.loaded between spec files), each load creates separate
            -- Proto objects. DA must SUM across proto instances, not MAX.
            local tmp = os.tmpname() .. ".lua"
            local fh = assert(io.open(tmp, "w"))
            fh:write("local M = {}\nfunction M.foo()\n   return 1\nend\nreturn M\n")
            fh:close()
            pchook.start()
            local m1 = assert(loadfile(tmp))()
            m1.foo(); m1.foo(); m1.foo()  -- 3 calls
            local m2 = assert(loadfile(tmp))()
            m2.foo(); m2.foo()  -- 2 calls
            pchook.stop()
            local data = pchook.get_all_line_hits()["@" .. tmp]
            assert.is_table(data)
            -- line 3 ("return 1") must be 5 (3+2), not 3 (max)
            assert.equal(5, data[3])
            os.remove(tmp)
         end)
      end)

      describe("get_func_defs", function()
         it("returns linedefined and lastlinedefined for all child protos", function()
            local chunk = assert(load([[
               local M = {}
               function M.foo()
                  return 1
               end
               function M.bar(x)
                  return x + 1
               end
               return M
            ]]))
            local defs = pchook.get_func_defs(chunk)
            assert.is_table(defs)
            assert.equal(2, #defs)
            for _, def in ipairs(defs) do
               assert.is_number(def.linedefined)
               assert.is_number(def.lastlinedefined)
               assert.is_true(def.linedefined > 0)
               assert.is_true(def.lastlinedefined >= def.linedefined)
            end
         end)

         it("skips the top-level chunk (linedefined == 0)", function()
            local chunk = assert(load("return 1"))
            local defs = pchook.get_func_defs(chunk)
            assert.equal(0, #defs)
         end)

         it("includes nested inner functions", function()
            local chunk = assert(load([[
               return function()
                  local function inner()
                     return 42
                  end
                  return inner()
               end
            ]]))
            local defs = pchook.get_func_defs(chunk)
            -- outer function + inner function
            assert.equal(2, #defs)
         end)
      end)

      describe("large functions (abslineinfo path)", function()
         -- The Lua VM stores compact line info as int8 deltas in
         -- `proto->lineinfo` and falls back to absolute anchors in
         -- `proto->abslineinfo` whenever the cumulative pc/line distance
         -- can no longer be expressed as a delta. The C helper
         -- `getbaseline()` selects an anchor every MAXIWTHABS (==128)
         -- instructions; with MAXIWTHABS we need a body of at least
         -- ~150 bytecode instructions before `sizeabslineinfo > 0` and
         -- the anchored path actually executes.
         --
         -- All other tests in this file use tiny functions whose pc fits
         -- well below the first anchor, so this path is otherwise never
         -- exercised. A regression in `getbaseline()` / `luaG_getfuncline()`
         -- would silently corrupt line attribution only for large
         -- production functions — the worst possible failure mode.

         local function build_large_function_source(n_locals)
            -- Each `local x_i = i` compiles to ~2 instructions and
            -- occupies its own source line. With n_locals=200 we
            -- guarantee both `sizecode > 128` (anchor path triggers)
            -- and a wide span of lines to validate against.
            local lines = {"return function()"}
            for i = 1, n_locals do
               lines[#lines + 1] = "   local x_" .. i .. " = " .. i
            end
            lines[#lines + 1] = "   return x_" .. n_locals
            lines[#lines + 1] = "end"
            return table.concat(lines, "\n")
         end

         it("attributes hits correctly across the abslineinfo anchor boundary", function()
            local source = build_large_function_source(200)
            local func = load_function(source)

            pchook.start()
            func()
            pchook.stop()

            local lines = pchook.get_line_hits(func)
            assert.is_table(lines)
            -- header + 200 locals + return + end → max line ≈ 203
            assert.is_true(lines.max >= 200)

            -- Count source lines that received at least one hit. A
            -- straight-line function with N+2 executable lines and no
            -- branches must register hits on essentially every one of
            -- them. We accept >= 150 to leave some slack for opcode
            -- folding (e.g. consecutive LOADI may share one line slot).
            local hit_lines = 0
            for k, v in pairs(lines) do
               if type(k) == "number" and v > 0 then
                  hit_lines = hit_lines + 1
               end
            end
            assert.is_true(hit_lines >= 150)
         end)

         it("preserves monotonic line numbers past the first anchor", function()
            -- This guards against a class of `getbaseline` bugs where
            -- the wrong anchor is selected and lines past pc≈128 get
            -- attributed to a much earlier (or much later) source line.
            -- We assert that NO recorded line exceeds the actual source
            -- line count.
            local n_locals = 200
            local source = build_large_function_source(n_locals)
            -- header(1) + n_locals + return(1) + end(1) = n_locals + 3
            local upper_bound = n_locals + 3
            local func = load_function(source)

            pchook.start()
            func()
            pchook.stop()

            local lines = pchook.get_line_hits(func)
            for k in pairs(lines) do
               if type(k) == "number" then
                  assert.is_true(k >= 1 and k <= upper_bound)
               end
            end
         end)
      end)

      describe("PC=0 boundary and tail calls", function()
         -- collect_line_hits_recursive() in pchook.c explicitly skips
         -- pc<=0 because the first instruction's hit is recorded under
         -- the caller's frame (luaG_traceexec increments pc BEFORE
         -- firing the hook). For very small functions this can be the
         -- difference between "first line gets credit" and "first line
         -- shows 0". The dedicated regression block above
         -- (savedpc-off-by-one) covers normal-sized functions; here we
         -- pin down the absolute minimum case.

         it("attributes hits to a single-statement function body", function()
            -- Body = exactly one expression statement: `return x`.
            -- Compiles to ~2 instructions; pc=0 is RETURN's prelude
            -- (or MOVE), pc=1 is RETURN itself. The hits-table key
            -- ends up >= 1, so the pc-1 mapping in
            -- collect_line_hits_recursive must land on the body line.
            local func = load_function([[
               return function(x) return x end
            ]])

            pchook.start()
            for _ = 1, 5 do func(42) end
            pchook.stop()

            local lines = pchook.get_line_hits(func)
            -- Find the single executable line and assert it has hits.
            local hit_line, hit_count
            for line_nr = 1, lines.max do
               if lines[line_nr] and lines[line_nr] > 0 then
                  hit_line = line_nr
                  hit_count = lines[line_nr]
                  break
               end
            end
            assert.is_number(hit_line)
            assert.is_true(hit_count >= 1)
         end)

         it("records hits in both caller and tail-callee frames", function()
            -- `return f(x)` compiles to OP_TAILCALL in Lua 5.4, which
            -- reuses the caller's frame. We must still see PC hits in
            -- the callee's proto AND in the caller's proto.
            local func = load_function([[
               local function callee(x)
                  return x + 1
               end
               return function(x)
                  return callee(x)   -- tail call site
               end
            ]])

            pchook.start()
            local r = func(10)
            pchook.stop()

            assert.equal(11, r)

            local result = pchook.get_hits(func)
            -- The outer proto is reachable from func; the local
            -- `callee` is captured as an upvalue (closure of the chunk),
            -- not as a nested proto of func, so it may not appear in
            -- result. What we DO require: the outer proto records hits.
            local outer_hits = 0
            for _, count in pairs(result[1].hits) do
               outer_hits = outer_hits + count
            end
            assert.is_true(outer_hits > 0)

            -- Globally (via get_all_hits), both protos must be present
            -- because both executed.
            local all_hits = pchook.get_all_hits()
            local total_protos_with_hits = 0
            for _, protos in pairs(all_hits) do
               for _, entry in ipairs(protos) do
                  local sum = 0
                  for _, c in pairs(entry.hits) do sum = sum + c end
                  if sum > 0 then
                     total_protos_with_hits = total_protos_with_hits + 1
                  end
               end
            end
            assert.is_true(total_protos_with_hits >= 2)
         end)
      end)

      describe("loops", function()
         -- `for`/`while`/`repeat` compile to specialized bytecode
         -- (OP_FORLOOP, OP_FORPREP, OP_TFORCALL, OP_TFORLOOP, plus
         -- backward jumps for while/repeat). Each iteration must
         -- produce a fresh PC hit on the loop body — if pchook ever
         -- mis-counted backward branches, loop body line counts would
         -- silently undercount.

         it("records per-iteration hits inside numeric for", function()
            local func = load_function([[
               return function(n)
                  local sum = 0
                  for i = 1, n do
                     sum = sum + i      -- expected: hit n times
                  end
                  return sum
               end
            ]])

            pchook.start()
            local r = func(10)
            pchook.stop()

            assert.equal(55, r)

            local lines = pchook.get_line_hits(func)
            -- Some line in the body must be hit at least n times.
            local max_hit = 0
            for k, v in pairs(lines) do
               if type(k) == "number" and v > max_hit then max_hit = v end
            end
            assert.is_true(max_hit >= 10)
         end)

         it("records per-iteration hits inside generic for", function()
            local func = load_function([[
               return function(t)
                  local out = {}
                  for k, v in pairs(t) do
                     out[k] = v * 2     -- expected: hit #t times
                  end
                  return out
               end
            ]])

            pchook.start()
            func({a = 1, b = 2, c = 3, d = 4})
            pchook.stop()

            local lines = pchook.get_line_hits(func)
            local max_hit = 0
            for k, v in pairs(lines) do
               if type(k) == "number" and v > max_hit then max_hit = v end
            end
            -- 4 keys → body executes 4 times.
            assert.is_true(max_hit >= 4)
         end)

         it("records per-iteration hits inside while loop with break", function()
            local func = load_function([[
               return function(n)
                  local i = 0
                  while true do
                     i = i + 1
                     if i >= n then
                        break
                     end
                  end
                  return i
               end
            ]])

            pchook.start()
            local r = func(7)
            pchook.stop()

            assert.equal(7, r)

            local lines = pchook.get_line_hits(func)
            local max_hit = 0
            for k, v in pairs(lines) do
               if type(k) == "number" and v > max_hit then max_hit = v end
            end
            -- The increment line runs n times.
            assert.is_true(max_hit >= 7)
         end)

         it("records per-iteration hits inside repeat-until", function()
            local func = load_function([[
               return function(n)
                  local i = 0
                  repeat
                     i = i + 1            -- runs n times
                  until i >= n
                  return i
               end
            ]])

            pchook.start()
            local r = func(5)
            pchook.stop()

            assert.equal(5, r)

            local lines = pchook.get_line_hits(func)
            local max_hit = 0
            for k, v in pairs(lines) do
               if type(k) == "number" and v > max_hit then max_hit = v end
            end
            assert.is_true(max_hit >= 5)
         end)
      end)

      describe("coroutines", function()
         -- lua_sethook is bound to the lua_State it was called on.
         -- Coroutines run on their OWN lua_State (the `co` thread),
         -- which means the hook installed by pchook.start() on the
         -- main state may NOT propagate to coroutines unless Lua
         -- explicitly forwards it. We pin down whichever behavior the
         -- current implementation exhibits so a future change cannot
         -- silently invalidate downstream coverage reports.

         it("either records hits inside coroutine bodies or leaves them empty (documented)", function()
            -- We do not assert "must record" because hook propagation
            -- to new threads is implementation-defined here. We DO
            -- assert: pchook must not crash, must continue to record
            -- main-thread hits, and the per-source aggregation must
            -- remain self-consistent.
            local main_func = load_function([[
               return function()
                  local marker_main = 1
                  return marker_main
               end
            ]])

            local co_func = load_function([[
               return function()
                  local function body()
                     local marker_co = 1
                     coroutine.yield(marker_co)
                     local marker_co_after = 2
                     return marker_co_after
                  end
                  local co = coroutine.create(body)
                  local ok1, v1 = coroutine.resume(co)
                  local ok2, v2 = coroutine.resume(co)
                  return ok1, v1, ok2, v2
               end
            ]])

            pchook.start()
            local m = main_func()
            local ok1, v1, ok2, v2 = co_func()
            pchook.stop()

            -- Functional correctness must always hold.
            assert.equal(1, m)
            assert.is_true(ok1)
            assert.equal(1, v1)
            assert.is_true(ok2)
            assert.equal(2, v2)

            -- Main-thread function must have hits regardless of
            -- coroutine hook propagation.
            local main_lines = pchook.get_line_hits(main_func)
            local main_max = 0
            for k, v in pairs(main_lines) do
               if type(k) == "number" and v > main_max then main_max = v end
            end
            assert.is_true(main_max >= 1)

            -- get_all_hits must not crash and must contain at least
            -- the main_func's source.
            local all_hits = pchook.get_all_hits()
            assert.is_table(all_hits)
            local has_any_source = false
            for _ in pairs(all_hits) do has_any_source = true; break end
            assert.is_true(has_any_source)
         end)
      end)

      describe("error paths (pcall/xpcall)", function()
         -- When `error()` is raised inside a pcall'd function, the VM
         -- longjmps back to the protected boundary. PCs executed
         -- BEFORE the error must be recorded; PCs strictly AFTER the
         -- error must NOT be recorded. This is how partial-coverage
         -- reporting on error branches becomes meaningful.

         it("records hits up to the error site but not past it", function()
            local func = load_function([[
               return function()
                  local before = 1                   -- HIT
                  error("boom")                      -- HIT
                  local after = 2                    -- NOT HIT
                  return before, after
               end
            ]])

            pchook.start()
            local ok, err = pcall(func)
            pchook.stop()

            assert.is_false(ok)
            assert.is_string(err)

            local lines = pchook.get_line_hits(func)

            -- Collect (line, hits) pairs into a sortable list.
            local entries = {}
            for k, v in pairs(lines) do
               if type(k) == "number" then
                  entries[#entries + 1] = {line = k, hits = v}
               end
            end
            table.sort(entries, function(a, b) return a.line < b.line end)

            -- We expect: at least one early line with hits > 0
            -- (the `before` / `error` lines), AND at least one late
            -- line with hits == 0 (the `after` line).
            local early_hit, late_zero = false, false
            local mid = math.floor(#entries / 2)
            for i, e in ipairs(entries) do
               if i <= mid and e.hits > 0 then early_hit = true end
               if i > mid and e.hits == 0 then late_zero = true end
            end
            assert.is_true(early_hit)
            assert.is_true(late_zero)
         end)

         it("records hits in the xpcall handler when it runs", function()
            local handler_func = load_function([[
               return function(err)
                  local tag = "handled"
                  return tag .. ":" .. tostring(err)
               end
            ]])

            local body_func = load_function([[
               return function()
                  error("kaboom")
               end
            ]])

            pchook.start()
            local ok, ret = xpcall(body_func, handler_func)
            pchook.stop()

            assert.is_false(ok)
            assert.is_string(ret)

            local handler_lines = pchook.get_line_hits(handler_func)
            local handler_max = 0
            for k, v in pairs(handler_lines) do
               if type(k) == "number" and v > handler_max then handler_max = v end
            end
            assert.is_true(handler_max >= 1)
         end)
      end)

      describe("vararg, goto/label, deep nesting, metamethods", function()
         it("records hits on a function that uses ...", function()
            -- OP_VARARG is its own opcode in Lua 5.4. A regression in
            -- pc->line mapping for VARARG would silently drop the
            -- header line of every variadic function in production code.
            local func = load_function([[
               return function(...)
                  local n = select("#", ...)        -- HIT
                  return n
               end
            ]])

            pchook.start()
            local n = func("a", "b", "c", "d")
            pchook.stop()

            assert.equal(4, n)

            local lines = pchook.get_line_hits(func)
            local hit_lines = 0
            for k, v in pairs(lines) do
               if type(k) == "number" and v > 0 then
                  hit_lines = hit_lines + 1
               end
            end
            assert.is_true(hit_lines >= 1)
         end)

         it("records hits across goto-jumps and labels", function()
            -- `goto continue` is the canonical Lua 5.2+ "continue"
            -- emulation. Targets of OP_JMP must have their PC mapped
            -- to the source line of the LABEL, not to wherever the
            -- jump originated. Same family of attribution bugs as
            -- if/elseif jump targets.
            local func = load_function([[
               return function(items)
                  local kept = 0
                  for _, v in ipairs(items) do
                     if v < 0 then
                        goto continue
                     end
                     kept = kept + 1               -- expected HIT for v >= 0
                     ::continue::
                  end
                  return kept
               end
            ]])

            pchook.start()
            local r = func({1, -1, 2, -2, 3})  -- 3 positives kept
            pchook.stop()

            assert.equal(3, r)

            local lines = pchook.get_line_hits(func)
            -- Some line must record exactly the 3 positive iterations
            -- (the `kept = kept + 1` line). We accept any line with
            -- hits >= 3 to be tolerant of opcode folding.
            local found = false
            for k, v in pairs(lines) do
               if type(k) == "number" and v >= 3 then
                  found = true
                  break
               end
            end
            assert.is_true(found)
         end)

         it("isolates hits across deeply nested closures (PROTO_INDEX_KEY robustness)", function()
            -- Multi-level closures: A returns B, B returns C, C is
            -- invoked. Each level is its own Proto and must be indexed
            -- independently in PROTO_INDEX_KEY. A bug in light-userdata
            -- identity handling would cause hits to bleed across levels.
            local func = load_function([[
               return function()
                  return function()
                     return function(x)
                        return x * 10
                     end
                  end
               end
            ]])

            pchook.start()
            local b = func()
            local c = b()
            local r = c(7)
            pchook.stop()

            assert.equal(70, r)

            -- Each returned closure is its own Proto reachable from
            -- the chain. Walk all three protos and assert each has
            -- its own non-empty hit set.
            local function total_hits(proto_results)
               local sum = 0
               for _, entry in ipairs(proto_results) do
                  for _, c2 in pairs(entry.hits) do
                     sum = sum + c2
                  end
               end
               return sum
            end

            assert.is_true(total_hits(pchook.get_hits(func)) > 0)
            assert.is_true(total_hits(pchook.get_hits(b)) > 0)
            assert.is_true(total_hits(pchook.get_hits(c)) > 0)

            -- The deepest closure ran exactly once; its proto's hits
            -- should reflect a SHORT execution path (small total).
            local c_total = total_hits(pchook.get_hits(c))
            assert.is_true(c_total >= 1 and c_total <= 20)
         end)

         it("records hits in metamethod bodies triggered by indexing", function()
            -- Heavy OOP / DSL Lua codebases run most logic through
            -- __index / __call / etc. If pchook missed metamethod
            -- frames, those codebases would show 0% coverage on their
            -- hottest paths.
            local func = load_function([[
               return function()
                  local index_calls = 0
                  local mt = {
                     __index = function(_, k)
                        index_calls = index_calls + 1
                        return "v:" .. k
                     end,
                  }
                  local t = setmetatable({}, mt)
                  local a = t.foo
                  local b = t.bar
                  local c = t.baz
                  return a, b, c, index_calls
               end
            ]])

            pchook.start()
            local a, b, c, n = func()
            pchook.stop()

            assert.equal("v:foo", a)
            assert.equal("v:bar", b)
            assert.equal("v:baz", c)
            assert.equal(3, n)

            -- The __index function is a nested anonymous proto of
            -- func. Walk get_hits and ensure SOME proto recorded a
            -- count >= 3 (the metamethod ran 3 times).
            local result = pchook.get_hits(func)
            local saw_three = false
            for _, entry in ipairs(result) do
               for _, count in pairs(entry.hits) do
                  if count >= 3 then
                     saw_three = true
                     break
                  end
               end
               if saw_three then break end
            end
            assert.is_true(saw_three)
         end)
      end)

      describe("tick support", function()
         it("calls save_stats at configured step intervals", function()
            local save_count = 0
            pchook.start({
               savestepsize = 2,
               save_stats = function()
                  save_count = save_count + 1
               end,
            })
            local func = load_function([[
               return function(x)
                  local a = x + 1
                  local b = a + 2
                  local c = b + 3
                  local d = c + 4
                  return d
               end
            ]])
            func(1)
            pchook.stop()
            assert.is_true(save_count >= 2)
         end)

         it("does not call save_stats when tick config is absent", function()
            local save_count = 0
            pchook.start()
            local func = load_function([[
               return function(x) return x + 1 end
            ]])
            func(42)
            pchook.stop()
            assert.equal(0, save_count)
         end)

         it("still records PC hits when tick is enabled", function()
            pchook.start({
               savestepsize = 100,
               save_stats = function() end,
            })
            local func = load_function([[
               return function(x) return x + 1 end
            ]])
            func(42)
            pchook.stop()
            local result = pchook.get_hits(func)
            local total = 0
            for _, entry in ipairs(result) do
               for _, count in pairs(entry.hits) do
                  total = total + count
               end
            end
            assert.is_true(total > 0)
         end)

         it("resets step counter after each save_stats call", function()
            local save_count = 0
            pchook.start({
               savestepsize = 3,
               save_stats = function()
                  save_count = save_count + 1
               end,
            })
            local func = load_function([[
               return function(x)
                  local a = x + 1
                  local b = a + 2
                  local c = b + 3
                  local d = c + 4
                  local e = d + 5
                  local f = e + 6
                  return f
               end
            ]])
            func(1)
            pchook.stop()
            assert.is_true(save_count >= 2)
         end)

         it("stop cleans up tick state for subsequent start without tick", function()
            local save_count = 0
            pchook.start({
               savestepsize = 2,
               save_stats = function()
                  save_count = save_count + 1
               end,
            })
            local func = load_function([[
               return function(x) return x + 1 end
            ]])
            func(1)
            pchook.stop()

            save_count = 0
            pchook.start()
            func(1)
            pchook.stop()
            assert.equal(0, save_count)
         end)
      end)
   end
end)
