-- luacheck: std +busted
local hook_module = require "cluacov.hook"

local function new_runner(overrides)
   local runner = {
      initialized = true,
      data = {},
      configuration = {
         codefromstrings = false,
         savestepsize = 100
      },
      tick = false,
      paused = false
   }

   runner.file_included_calls = {}
   runner.save_stats_calls = 0

   function runner.file_included(filename)
      table.insert(runner.file_included_calls, filename)
      return true
   end

   function runner.save_stats()
      runner.save_stats_calls = runner.save_stats_calls + 1
   end

   if overrides then
      for key, value in pairs(overrides) do
         if key == "configuration" then
            for config_key, config_value in pairs(value) do
               runner.configuration[config_key] = config_value
            end
         else
            runner[key] = value
         end
      end
   end

   return runner
end

local function invoke(hook, line_nr, level)
   hook("line", line_nr, level)
end

local function get_only_tracked_file(runner)
   local filename, file_data = next(runner.data)
   assert.string(filename)
   assert.is_nil(next(runner.data, filename))
   return filename, file_data
end

describe("hook", function()
   describe("new", function()
      it("returns a function", function()
         assert.is_function(hook_module.new(new_runner()))
      end)
   end)

   describe("debug hook", function()
      it("records line hits and updates per-file maxima", function()
         local runner = new_runner()
         local hook = hook_module.new(runner)

         invoke(hook, 10)
         invoke(hook, 10)
         invoke(hook, 4)
         invoke(hook, 12)

         local filename, file_data = get_only_tracked_file(runner)
         assert.equal(filename, runner.file_included_calls[1])
         assert.same({filename}, runner.file_included_calls)
         assert.equal(2, file_data[10])
         assert.equal(1, file_data[4])
         assert.equal(1, file_data[12])
         assert.equal(12, file_data.max)
         assert.equal(2, file_data.max_hits)
      end)

      it("ignores hits before the runner is initialized", function()
         local runner = new_runner({
            initialized = false
         })

         invoke(hook_module.new(runner), 10)

         assert.same({}, runner.data)
         assert.same({}, runner.file_included_calls)
      end)

      it("remembers ignored files and skips repeated inclusion checks", function()
         local include_calls = 0
         local runner = new_runner({
            file_included = function()
               include_calls = include_calls + 1
               return false
            end
         })

         local hook = hook_module.new(runner)

         invoke(hook, 7)
         invoke(hook, 9)

         assert.same({}, runner.data)
         assert.equal(1, include_calls)
      end)

      it("ignores code loaded from strings unless configured otherwise", function()
         local function run(codefromstrings)
            local runner = new_runner({
               configuration = {
                  codefromstrings = codefromstrings
               }
            })
            local hook = hook_module.new(runner)
            local chunk = assert(loadstring(
               "return function(h, line_nr) h('line', line_nr) end"
            ))()

            chunk(hook, 7)
            return runner
         end

         local ignored_runner = run(false)
         local tracked_runner = run(true)
         local filename, file_data = get_only_tracked_file(tracked_runner)

         assert.same({}, ignored_runner.data)
         assert.equal("return function(h, line_nr) h('line', line_nr) end", filename)
         assert.equal(1, file_data[7])
         assert.equal(7, file_data.max)
         assert.equal(1, file_data.max_hits)
      end)

      it("saves stats every configured number of hits when ticking", function()
         local runner = new_runner({
            tick = true,
            configuration = {
               savestepsize = 2
            }
         })

         local hook = hook_module.new(runner)

         invoke(hook, 1)
         invoke(hook, 2)
         invoke(hook, 3)
         invoke(hook, 4)

         assert.equal(2, runner.save_stats_calls)
      end)

      it("does not save stats while paused", function()
         local runner = new_runner({
            tick = true,
            paused = true,
            configuration = {
               savestepsize = 2
            }
         })

         local hook = hook_module.new(runner)

         invoke(hook, 1)
         invoke(hook, 2)

         assert.equal(0, runner.save_stats_calls)
      end)
   end)
end)
