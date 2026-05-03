-- luacheck: std +busted
local load = loadstring or load -- luacheck: compat
local is_windows = package.config:sub(1, 1) == "\\"

describe("cluacov.runner", function()
   local lua_version = tonumber(_VERSION:match("(%d+%.%d+)"))

   if jit or lua_version < 5.4 then
      pending("runner requires PUC-Rio Lua 5.4+")
   else
      local tmpdir
      local sample_file
      local test_file

      setup(function()
         tmpdir = os.tmpname() .. "_runner_test"
         if is_windows then
            os.execute('mkdir "' .. tmpdir .. '"')
         else
            os.execute("mkdir -p " .. tmpdir)
         end

         sample_file = tmpdir .. (is_windows and "\\" or "/") .. "sample.lua"
         local fh = assert(io.open(sample_file, "w"))
         fh:write([[
local M = {}
function M.add(a, b) return a + b end
function M.check(x)
   if x > 0 then
      return "positive"
   else
      return "non-positive"
   end
end
return M
]])
         fh:close()

         test_file = tmpdir .. (is_windows and "\\" or "/") .. "test.lua"
         fh = assert(io.open(test_file, "w"))
         fh:write(string.format([[
package.path = %q .. "/?.lua;" .. package.path
local sample = require("sample")
assert(sample.add(1, 2) == 3)
assert(sample.check(5) == "positive")
]], tmpdir))
         fh:close()
      end)

      teardown(function()
         if tmpdir then
            if is_windows then
               os.execute('rmdir /s /q "' .. tmpdir .. '"')
            else
               os.execute("rm -rf " .. tmpdir)
            end
         end
      end)

      local function run_with_config(tmpdir_path, luacov_cfg)
         local cmd
         if is_windows then
            cmd = string.format(
               'set "LUACOV_CONFIG=%s" && cd /d "%s" && lua -lcluacov.runner test.lua 2>&1',
               luacov_cfg, tmpdir_path)
         else
            cmd = string.format(
               "cd %s && LUACOV_CONFIG=%s lua -lcluacov.runner test.lua 2>&1",
               tmpdir_path, luacov_cfg)
         end
         os.execute(cmd)
      end

      it("generates luacov stats and LCOV files", function()
         local stats_file = tmpdir .. (is_windows and "\\" or "/") .. "luacov.stats.out"
         local lcov_file = tmpdir .. (is_windows and "\\" or "/") .. "lcov.info"
         local luacov_cfg = tmpdir .. (is_windows and "\\" or "/") .. ".luacov"

         local cfg_fh = assert(io.open(luacov_cfg, "w"))
         cfg_fh:write(string.format([[
return {
   statsfile = %q,
   lcovfile = %q,
   include = { "sample$" },
}
]], stats_file, lcov_file))
         cfg_fh:close()

         run_with_config(tmpdir, luacov_cfg)

         local sfh = io.open(stats_file, "r")
         assert.is_truthy(sfh, "stats file should exist")
         local stats_content = sfh:read("*a")
         sfh:close()
         assert.is_truthy(stats_content:match("sample"), "stats should contain sample")

         local lfh = io.open(lcov_file, "r")
         assert.is_truthy(lfh, "lcov file should exist")
         local lcov_content = lfh:read("*a")
         lfh:close()
         assert.is_truthy(lcov_content:match("^TN:"), "LCOV should start with TN:")
         assert.is_truthy(lcov_content:match("SF:"), "LCOV should have SF records")
         assert.is_truthy(lcov_content:match("DA:"), "LCOV should have DA records")
         assert.is_truthy(lcov_content:match("BRDA:"), "LCOV should have BRDA records")
         assert.is_truthy(lcov_content:match("end_of_record"), "LCOV should have end_of_record")
      end)

      it("excludes cluacov modules from output", function()
         local stats_file = tmpdir .. (is_windows and "\\" or "/") .. "luacov2.stats.out"
         local lcov_file = tmpdir .. (is_windows and "\\" or "/") .. "lcov2.info"

         local luacov_cfg = tmpdir .. (is_windows and "\\" or "/") .. ".luacov2"
         local cfg_fh = assert(io.open(luacov_cfg, "w"))
         cfg_fh:write(string.format([[
return {
   statsfile = %q,
   lcovfile = %q,
}
]], stats_file, lcov_file))
         cfg_fh:close()

         run_with_config(tmpdir, luacov_cfg)

         local lfh = io.open(lcov_file, "r")
         assert.is_truthy(lfh)
         local lcov_content = lfh:read("*a")
         lfh:close()
         assert.is_falsy(lcov_content:match("cluacov"), "LCOV should not contain cluacov files")
      end)

      it("saves stats periodically when tick is enabled", function()
         local stats_file = tmpdir .. (is_windows and "\\" or "/") .. "luacov_tick.stats.out"
         local lcov_file = tmpdir .. (is_windows and "\\" or "/") .. "lcov_tick.info"

         local luacov_cfg = tmpdir .. (is_windows and "\\" or "/") .. ".luacov_tick"
         local cfg_fh = assert(io.open(luacov_cfg, "w"))
         cfg_fh:write(string.format([[
return {
   statsfile = %q,
   lcovfile = %q,
   include = { "sample$" },
   tick = true,
   savestepsize = 1,
}
]], stats_file, lcov_file))
         cfg_fh:close()

         run_with_config(tmpdir, luacov_cfg)

         local sfh = io.open(stats_file, "r")
         assert.is_truthy(sfh, "tick stats file should exist")
         local stats_content = sfh:read("*a")
         sfh:close()
         assert.is_truthy(stats_content:match("sample"), "tick stats should contain sample")

         local lfh = io.open(lcov_file, "r")
         assert.is_truthy(lfh, "tick lcov file should exist")
         local lcov_content = lfh:read("*a")
         lfh:close()
         assert.is_truthy(lcov_content:match("^TN:"), "tick LCOV should start with TN:")
      end)

      it("does not create GC anchor when tick is true", function()
         -- Run a subprocess with tick=true and verify _anchor is nil
         local luacov_cfg = tmpdir .. (is_windows and "\\" or "/") .. ".luacov_anchor"
         local cfg_fh = assert(io.open(luacov_cfg, "w"))
         cfg_fh:write(string.format([[
return {
   statsfile = %q,
   lcovfile = %q,
   tick = true,
   savestepsize = 100,
}
]], tmpdir .. (is_windows and "\\" or "/") .. "anchor_stats.out",
   tmpdir .. (is_windows and "\\" or "/") .. "anchor_lcov.info"))
         cfg_fh:close()

         local check_script = tmpdir .. (is_windows and "\\" or "/") .. "check_anchor.lua"
         local cs_fh = assert(io.open(check_script, "w"))
         cs_fh:write([[
local runner = require("cluacov.runner")
io.write(runner._anchor and "HAS_ANCHOR" or "NO_ANCHOR")
io.flush()
]])
         cs_fh:close()

         local cmd
         if is_windows then
            cmd = string.format(
               'set "LUACOV_CONFIG=%s" && lua "%s"',
               luacov_cfg, check_script)
         else
            cmd = string.format(
               'LUACOV_CONFIG=%s lua "%s"',
               luacov_cfg, check_script)
         end
         local fh = io.popen(cmd)
         local result = fh:read("*a")
         fh:close()

         assert.equal("NO_ANCHOR", result, "runner._anchor should be nil when tick=true")
      end)

      describe("function coverage (FNDA)", function()
         local sep = is_windows and "\\" or "/"

         local function write_file(path, content)
            local fh = assert(io.open(path, "w"))
            fh:write(content)
            fh:close()
         end

         it("reports FNDA:0 for defined-but-uncalled functions", function()
            local fn_sample = tmpdir .. sep .. "fn_sample.lua"
            write_file(fn_sample, [[
local M = {}
function M.called(x) return x + 1 end
function M.uncalled(x) return x * 2 end
function M.also_called(a, b) return a + b end
return M
]])
            local fn_test = tmpdir .. sep .. "fn_test.lua"
            write_file(fn_test, string.format([[
package.path = %q .. "/?.lua;" .. package.path
local m = require("fn_sample")
assert(m.called(1) == 2)
assert(m.also_called(3, 4) == 7)
]], tmpdir))

            local stats_f = tmpdir .. sep .. "fn_stats.out"
            local lcov_f = tmpdir .. sep .. "fn_lcov.info"
            local cfg_f = tmpdir .. sep .. ".luacov_fn"
            write_file(cfg_f, string.format([[
return {
   statsfile = %q,
   lcovfile = %q,
   include = { "fn_sample$" },
}
]], stats_f, lcov_f))

            local cmd
            if is_windows then
               cmd = string.format(
                  'set "LUACOV_CONFIG=%s" && cd /d "%s" && lua -lcluacov.runner fn_test.lua 2>&1',
                  cfg_f, tmpdir)
            else
               cmd = string.format(
                  "cd %s && LUACOV_CONFIG=%s lua -lcluacov.runner fn_test.lua 2>&1",
                  tmpdir, cfg_f)
            end
            os.execute(cmd)

            local lfh = io.open(lcov_f, "r")
            assert.is_truthy(lfh, "lcov file should exist")
            local lcov = lfh:read("*a")
            lfh:close()

            -- called and also_called should have FNDA > 0
            local called_hits = lcov:match("FNDA:(%d+),called\n")
            assert.is_truthy(called_hits, "FNDA for 'called' should exist")
            assert.is_true(tonumber(called_hits) > 0,
               "called() was invoked, FNDA should be > 0")

            local also_called_hits = lcov:match("FNDA:(%d+),also_called\n")
            assert.is_truthy(also_called_hits, "FNDA for 'also_called' should exist")
            assert.is_true(tonumber(also_called_hits) > 0,
               "also_called() was invoked, FNDA should be > 0")

            -- uncalled should have FNDA:0
            local uncalled_hits = lcov:match("FNDA:(%d+),uncalled\n")
            assert.is_truthy(uncalled_hits, "FNDA for 'uncalled' should exist")
            assert.equal(0, tonumber(uncalled_hits),
               "uncalled() was never invoked, FNDA must be 0")
         end)

         it("reports correct FNH count excluding uncalled functions", function()
            local fn2_sample = tmpdir .. sep .. "fn2_sample.lua"
            write_file(fn2_sample, [[
local M = {}
function M.alpha() return "a" end
function M.beta() return "b" end
function M.gamma() return "g" end
return M
]])
            local fn2_test = tmpdir .. sep .. "fn2_test.lua"
            write_file(fn2_test, string.format([[
package.path = %q .. "/?.lua;" .. package.path
local m = require("fn2_sample")
assert(m.alpha() == "a")
]], tmpdir))

            local stats_f = tmpdir .. sep .. "fn2_stats.out"
            local lcov_f = tmpdir .. sep .. "fn2_lcov.info"
            local cfg_f = tmpdir .. sep .. ".luacov_fn2"
            write_file(cfg_f, string.format([[
return {
   statsfile = %q,
   lcovfile = %q,
   include = { "fn2_sample$" },
}
]], stats_f, lcov_f))

            local cmd
            if is_windows then
               cmd = string.format(
                  'set "LUACOV_CONFIG=%s" && cd /d "%s" && lua -lcluacov.runner fn2_test.lua 2>&1',
                  cfg_f, tmpdir)
            else
               cmd = string.format(
                  "cd %s && LUACOV_CONFIG=%s lua -lcluacov.runner fn2_test.lua 2>&1",
                  tmpdir, cfg_f)
            end
            os.execute(cmd)

            local lfh = io.open(lcov_f, "r")
            assert.is_truthy(lfh, "lcov file should exist")
            local lcov = lfh:read("*a")
            lfh:close()

            -- FNF should be 3 (all defined), FNH should be 1 (only alpha called)
            local fnf = lcov:match("FNF:(%d+)")
            local fnh = lcov:match("FNH:(%d+)")
            assert.is_truthy(fnf)
            assert.is_truthy(fnh)
            assert.equal(3, tonumber(fnf), "FNF should count all 3 defined functions")
            assert.equal(1, tonumber(fnh), "FNH should count only the 1 called function")
         end)

         it("counts multiple calls in FNDA", function()
            local fn3_sample = tmpdir .. sep .. "fn3_sample.lua"
            write_file(fn3_sample, [[
local M = {}
function M.inc(x) return x + 1 end
return M
]])
            local fn3_test = tmpdir .. sep .. "fn3_test.lua"
            write_file(fn3_test, string.format([[
package.path = %q .. "/?.lua;" .. package.path
local m = require("fn3_sample")
for i = 1, 5 do m.inc(i) end
]], tmpdir))

            local stats_f = tmpdir .. sep .. "fn3_stats.out"
            local lcov_f = tmpdir .. sep .. "fn3_lcov.info"
            local cfg_f = tmpdir .. sep .. ".luacov_fn3"
            write_file(cfg_f, string.format([[
return {
   statsfile = %q,
   lcovfile = %q,
   include = { "fn3_sample$" },
}
]], stats_f, lcov_f))

            local cmd
            if is_windows then
               cmd = string.format(
                  'set "LUACOV_CONFIG=%s" && cd /d "%s" && lua -lcluacov.runner fn3_test.lua 2>&1',
                  cfg_f, tmpdir)
            else
               cmd = string.format(
                  "cd %s && LUACOV_CONFIG=%s lua -lcluacov.runner fn3_test.lua 2>&1",
                  tmpdir, cfg_f)
            end
            os.execute(cmd)

            local lfh = io.open(lcov_f, "r")
            assert.is_truthy(lfh, "lcov file should exist")
            local lcov = lfh:read("*a")
            lfh:close()

            local inc_hits = lcov:match("FNDA:(%d+),inc\n")
            assert.is_truthy(inc_hits, "FNDA for 'inc' should exist")
            assert.is_true(tonumber(inc_hits) >= 5,
               "inc() called 5 times, FNDA should be >= 5, got " .. inc_hits)
         end)

         it("reports correct FNDA for vararg functions", function()
            local fn4_sample = tmpdir .. sep .. "fn4_sample.lua"
            write_file(fn4_sample, [[
local M = {}
function M.sum_args(...)
   local n = select("#", ...)
   local s = 0
   for i = 1, n do s = s + select(i, ...) end
   return s
end
function M.plain(x) return x end
return M
]])
            local fn4_test = tmpdir .. sep .. "fn4_test.lua"
            write_file(fn4_test, string.format([[
package.path = %q .. "/?.lua;" .. package.path
local m = require("fn4_sample")
assert(m.sum_args(1, 2, 3) == 6)
assert(m.sum_args(10) == 10)
assert(m.plain(42) == 42)
]], tmpdir))

            local stats_f = tmpdir .. sep .. "fn4_stats.out"
            local lcov_f = tmpdir .. sep .. "fn4_lcov.info"
            local cfg_f = tmpdir .. sep .. ".luacov_fn4"
            write_file(cfg_f, string.format([[
return {
   statsfile = %q,
   lcovfile = %q,
   include = { "fn4_sample$" },
}
]], stats_f, lcov_f))

            local cmd
            if is_windows then
               cmd = string.format(
                  'set "LUACOV_CONFIG=%s" && cd /d "%s" && lua -lcluacov.runner fn4_test.lua 2>&1',
                  cfg_f, tmpdir)
            else
               cmd = string.format(
                  "cd %s && LUACOV_CONFIG=%s lua -lcluacov.runner fn4_test.lua 2>&1",
                  tmpdir, cfg_f)
            end
            os.execute(cmd)

            local lfh = io.open(lcov_f, "r")
            assert.is_truthy(lfh, "lcov file should exist")
            local lcov = lfh:read("*a")
            lfh:close()

            -- Vararg function sum_args called twice: FNDA >= 2
            local va_hits = lcov:match("FNDA:(%d+),sum_args\n")
            assert.is_truthy(va_hits, "FNDA for 'sum_args' should exist")
            assert.is_true(tonumber(va_hits) >= 2,
               "sum_args() called 2 times, FNDA should be >= 2, got " .. va_hits)

            -- Plain function also works
            local plain_hits = lcov:match("FNDA:(%d+),plain\n")
            assert.is_truthy(plain_hits, "FNDA for 'plain' should exist")
            assert.is_true(tonumber(plain_hits) >= 1,
               "plain() called 1 time, FNDA should be >= 1, got " .. plain_hits)
         end)
      end)

      describe("config loading", function()
         local sep = is_windows and "\\" or "/"

         local function write_file(path, content)
            local fh = assert(io.open(path, "w"))
            fh:write(content)
            fh:close()
         end

         local function run_dump(cfg_path)
            local dump_path = tmpdir .. sep .. "dump_config.lua"
            write_file(dump_path, [[
local runner = require("cluacov.runner")
for _, v in ipairs(runner.config.exclude or {}) do
   io.write("EXCLUDE:" .. v .. "\n")
end
for _, v in ipairs(runner.config.include or {}) do
   io.write("INCLUDE:" .. v .. "\n")
end
io.flush()
]])
            local cmd
            if is_windows then
               cmd = string.format(
                  'set "LUACOV_CONFIG=%s" && cd /d "%s" && lua dump_config.lua 2>&1',
                  cfg_path, tmpdir)
            else
               cmd = string.format(
                  "cd %s && LUACOV_CONFIG=%s lua dump_config.lua 2>&1",
                  tmpdir, cfg_path)
            end
            local fh = io.popen(cmd)
            local output = fh:read("*a")
            fh:close()
            return output
         end

         it("loads bare-assignment .luacov config", function()
            local cfg_path = tmpdir .. sep .. ".luacov_bare"
            write_file(cfg_path, 'include = { "mymodule$" }\n')

            local output = run_dump(cfg_path)
            assert.is_truthy(output:match("INCLUDE:mymodule%$"),
               "bare-assignment include should be loaded")
         end)

         it("merges user exclude with defaults for return-style config", function()
            local cfg_path = tmpdir .. sep .. ".luacov_merge_ret"
            write_file(cfg_path, 'return {\n   exclude = { "%.spec$" },\n}\n')

            local output = run_dump(cfg_path)
            assert.is_truthy(output:match("EXCLUDE:%%.spec%$"),
               "user exclude pattern should be present")
            assert.is_truthy(output:match("EXCLUDE:busted%%."),
               "default exclude 'busted%%.' should be preserved")
            assert.is_truthy(output:match("EXCLUDE:cluacov%%."),
               "default exclude 'cluacov%%.' should be preserved")
         end)

         it("merges bare-assignment exclude with defaults", function()
            local cfg_path = tmpdir .. sep .. ".luacov_merge_bare"
            write_file(cfg_path, 'exclude = { "%.spec$" }\n')

            local output = run_dump(cfg_path)
            assert.is_truthy(output:match("EXCLUDE:%%.spec%$"),
               "user exclude pattern should be present")
            assert.is_truthy(output:match("EXCLUDE:busted%%."),
               "default exclude 'busted%%.' should be preserved")
         end)

         it("prioritizes bare assignment over return table for same key", function()
            local cfg_path = tmpdir .. sep .. ".luacov_mixed"
            write_file(cfg_path, [[
exclude = { "%.spec$" }
return {
   include = { "mymodule$" },
   exclude = { "%.test$" },
}
]])

            local output = run_dump(cfg_path)
            assert.is_truthy(output:match("EXCLUDE:%%.spec%$"),
               "bare-assignment exclude should be present")
            assert.is_falsy(output:match("EXCLUDE:%%.test%$"),
               "return-table exclude should be ignored when bare assignment exists")
            assert.is_truthy(output:match("INCLUDE:mymodule%$"),
               "return-table include should be loaded (no bare-assignment conflict)")
         end)

         it("warns on config file with runtime error", function()
            local cfg_path = tmpdir .. sep .. ".luacov_runerr"
            write_file(cfg_path, 'error("intentional test error")\n')

            local output = run_dump(cfg_path)
            assert.is_truthy(output:match("%[cluacov%] warning"),
               "should warn on config runtime error")
         end)

         it("warns on config file with syntax error", function()
            local cfg_path = tmpdir .. sep .. ".luacov_syntax"
            write_file(cfg_path, 'this is not valid lua {{{}\n')

            local output = run_dump(cfg_path)
            assert.is_truthy(output:match("%[cluacov%] warning"),
               "should warn on config syntax error")
         end)
      end)
   end
end)
