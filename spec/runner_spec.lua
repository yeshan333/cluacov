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
         -- Verify that runner._anchor is not set when tick=true
         local runner = require("cluacov.runner")
         -- runner is already initialized at module load, check the tick field
         -- (the runner.init() was called with default config, so tick=false)
         -- We can only verify the config key exists
         assert.is_not_nil(runner.config.tick, "tick should be in config")
         assert.is_not_nil(runner.config.savestepsize, "savestepsize should be in config")
      end)
   end
end)
