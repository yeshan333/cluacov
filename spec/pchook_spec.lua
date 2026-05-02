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
