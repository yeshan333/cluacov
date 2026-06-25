local pchook = require("cluacov.pchook")
local deepbranches = require("cluacov.deepbranches")
local deepactivelines = require("cluacov.deepactivelines")

local runner = {}

local debug = require("debug")
local raw_os_exit = os.exit

local function match_any(patterns, str, on_empty)
   if not patterns or not patterns[1] then
      return on_empty
   end
   for _, pattern in ipairs(patterns) do
      if str:match(pattern) then
         return true
      end
   end
   return false
end

local function file_included(config, filename)
   local name = filename:gsub("\\", "/"):gsub("%.lua$", "")
   return match_any(config.include, name, true)
      and not match_any(config.exclude, name, false)
end

local function load_config_chunk(configfile, env)
   if setfenv then
      local chunk, err = loadfile(configfile)
      if not chunk then return nil, err end
      setfenv(chunk, env)
      return chunk
   end
   return loadfile(configfile, "t", env)
end

local function load_user_config(configfile)
   local env = setmetatable({}, { __index = _G })
   local chunk, load_err = load_config_chunk(configfile, env)
   if not chunk then
      return nil, "load", load_err
   end
   local ok, ret = pcall(chunk)
   if not ok then
      return nil, "run", ret
   end
   if type(ret) == "table" then
      for k, v in pairs(ret) do
         if rawget(env, k) == nil then
            env[k] = v
         end
      end
   end
   setmetatable(env, nil)
   if next(env) ~= nil then
      return env
   end
   return nil
end

local MERGE_KEYS = { exclude = true, include = true }

local function load_config(configfile)
   local config = {
      statsfile = "luacov.stats.out",
      lcovfile = "lcov.info",
      tick = false,
      savestepsize = 100,
      include = {},
      exclude = {
         "luacov$", "luacov%.", "luacov/",
         "cluacov%.", "cluacov/",
         "busted%.", "busted/", "busted_bootstrap$",
         "luassert%.", "luassert/",
         "say%.", "say/",
         "pl%.", "pl/",
      },
   }

   local is_explicit = type(configfile) == "string"
   if not is_explicit then
      configfile = os.getenv("LUACOV_CONFIG") or ".luacov"
   end

   local user, err_type, err_msg = load_user_config(configfile)
   if user then
      for k, v in pairs(user) do
         if MERGE_KEYS[k] and type(v) == "table" and type(config[k]) == "table" then
            for _, item in ipairs(v) do
               config[k][#config[k] + 1] = item
            end
         else
            config[k] = v
         end
      end
   elseif err_type == "load" then
      local fh = io.open(configfile, "r")
      if fh then
         fh:close()
         io.stderr:write(string.format(
            "[cluacov] warning: failed to load %s: %s\n",
            configfile, tostring(err_msg)))
      elseif is_explicit or os.getenv("LUACOV_CONFIG") then
         io.stderr:write(string.format(
            "[cluacov] warning: config file not found: %s\n", configfile))
      end
   elseif err_type == "run" then
      io.stderr:write(string.format(
         "[cluacov] warning: error running %s: %s\n",
         configfile, tostring(err_msg)))
   end

   return config
end

local function strip_at(source)
   if source:sub(1, 1) == "@" then
      return source:sub(2)
   end
   return nil
end

local function proto_key(proto)
   return table.concat({
      proto.linedefined or 0,
      proto.lastlinedefined or 0,
      proto.sizecode or 0,
   }, ":")
end

local function resolve_path(filename)
   if filename:sub(1, 1) == "/" then return filename end
   local fh = io.popen("pwd")
   if not fh then return filename end
   local pwd = fh:read("*l")
   fh:close()
   if not pwd then return filename end
   if filename:sub(1, 2) == "./" then
      filename = filename:sub(3)
   end
   return pwd .. "/" .. filename
end

local function write_luacov_stats(config, all_line_hits)
   local stats = {}

   for source, lines in pairs(all_line_hits) do
      local filename = strip_at(source)
      if filename and file_included(config, filename) then
         local max = lines.max or 0
         local max_hits = 0
         local entry = { max = max, max_hits = 0 }
         for i = 1, max do
            local hits = lines[i] or 0
            if hits > 0 then
               entry[i] = hits
               if hits > max_hits then max_hits = hits end
            end
         end
         entry.max_hits = max_hits
         stats[filename] = entry
      end
   end

   local filenames = {}
   for name in pairs(stats) do
      filenames[#filenames + 1] = name
   end
   table.sort(filenames)

   local fd = assert(io.open(config.statsfile, "w"))
   for _, filename in ipairs(filenames) do
      local data = stats[filename]
      fd:write(data.max, ":", filename, "\n")
      for i = 1, data.max do
         fd:write(tostring(data[i] or 0), " ")
      end
      fd:write("\n")
   end
   fd:close()
end

local function write_lcov(config, all_line_hits, all_hits)
   local sources = {}
   for source in pairs(all_line_hits) do
      sources[#sources + 1] = source
   end
   table.sort(sources)

   local fd = assert(io.open(config.lcovfile, "w"))
   fd:write("TN:\n")

   for _, source in ipairs(sources) do
      local filename = strip_at(source)
      if not filename or not file_included(config, filename) then
         goto continue
      end

      local func = loadfile(filename)
      if not func then goto continue end

      local line_data = all_line_hits[source]
      local active_lines = deepactivelines.get(func)
      local branches = deepbranches.get(func)
      local proto_list = all_hits[source] or {}

      fd:write("SF:", resolve_path(filename), "\n")

      local source_lines = {}
      local fh = io.open(filename, "r")
      if fh then
         for line in fh:lines() do
            source_lines[#source_lines + 1] = line
         end
         fh:close()
      end

      local func_defs = {}
      for line_nr, line in ipairs(source_lines) do
         local fname = line:match("^function%s+%S-%.([%w_]+)")
            or line:match("^function%s+([%w_]+)")
            or line:match("^local%s+function%s+([%w_]+)")
         if fname then
            func_defs[#func_defs + 1] = { line = line_nr, name = fname }
         end
      end

      for _, fn in ipairs(func_defs) do
         fd:write(string.format("FN:%d,%s\n", fn.line, fn.name))
      end
      fd:write(string.format("FNF:%d\n", #func_defs))

      -- Build lookup: linedefined -> call count from proto body hits.
      -- A function is only counted as "called" when its Proto's body
      -- was actually entered, not merely when the OP_CLOSURE instruction
      -- at the definition site executed.
      -- Normal functions record their entry-point hit at hits[1] (PC 0
      -- produces savedpc 1). Vararg functions have OP_VARARGPREP at PC 0
      -- which does not trigger the count hook, so hits[1] is absent and
      -- the first recorded hit is hits[2]. Fall back accordingly.
      local fn_call_counts = {}
      for _, entry in ipairs(proto_list) do
         local ld = entry.linedefined
         if ld > 0 then
            local count = entry.hits[1] or entry.hits[2] or 0
            if count > 0 then
               fn_call_counts[ld] = (fn_call_counts[ld] or 0) + count
            end
         end
      end

      local fns_hit = 0
      for _, fn in ipairs(func_defs) do
         local hits = fn_call_counts[fn.line] or 0
         fd:write(string.format("FNDA:%d,%s\n", hits, fn.name))
         if hits > 0 then fns_hit = fns_hit + 1 end
      end
      fd:write(string.format("FNH:%d\n", fns_hit))

      local hits_by_ld = {}
      for _, entry in ipairs(proto_list) do
         local key = proto_key(entry)
         local existing = hits_by_ld[key]
         if existing then
            for pc, count in pairs(entry.hits) do
               existing[pc] = (existing[pc] or 0) + count
            end
         else
            local copy = {}
            for pc, count in pairs(entry.hits) do
               copy[pc] = count
            end
            hits_by_ld[key] = copy
         end
      end

      local block_id = 0
      local brf, brh = 0, 0
      for _, b in ipairs(branches) do
         local proto_hits = hits_by_ld[proto_key(b)] or {}
         -- b.pc is the branch source instruction (savedpc convention).
         -- If the branch instruction itself was never executed, all
         -- target hit counts are noise from other code paths converging
         -- on the same target PCs — suppress them.
         local branch_hit = (proto_hits[b.pc] or 0) > 0
         brf = brf + #b.targets
         for ti, t in ipairs(b.targets) do
            local taken
            if t.pc < 0 then
               local call_pc = -t.pc
               local success_pc = call_pc + 1
               local call_hits = proto_hits[call_pc] or 0
               local success_hits = proto_hits[success_pc] or 0
               local diff = call_hits - success_hits
               taken = branch_hit and (diff > 0 and diff or 0) or 0
            else
               taken = branch_hit and (proto_hits[t.pc] or 0) or 0
            end
            fd:write(string.format("BRDA:%d,%d,%d,%s\n",
               b.line, block_id, ti - 1,
               taken > 0 and tostring(taken) or "-"))
            if taken > 0 then brh = brh + 1 end
         end
         block_id = block_id + 1
      end
      fd:write(string.format("BRF:%d\n", brf))
      fd:write(string.format("BRH:%d\n", brh))

      -- Collect definition lines of uncalled functions. The hit on these
      -- lines comes from OP_CLOSURE in the parent chunk, not from the
      -- function being entered, so it should not count as line coverage.
      -- In Lua 5.4 CLOSURE is at linedefined; in Lua 5.5 it moves to
      -- lastlinedefined (the `end` line), so both must be suppressed.
      -- get_func_defs traverses the full Proto tree of the loaded file,
      -- including protos that were never entered by the hook.
      local uncalled_def_lines = {}
      local uncalled_ld_set = {}
      for _, fn in ipairs(func_defs) do
         if not fn_call_counts[fn.line] then
            uncalled_def_lines[fn.line] = true
            uncalled_ld_set[fn.line] = true
         end
      end
      for _, def in ipairs(pchook.get_func_defs(func)) do
         if uncalled_ld_set[def.linedefined] then
            local lld = def.lastlinedefined
            if lld and lld > 0 and lld ~= def.linedefined then
               uncalled_def_lines[lld] = true
            end
         end
      end

      local lf, lh = 0, 0
      local max = line_data.max or 0
      for line_nr = 1, max do
         if active_lines[line_nr] then
            local hits = line_data[line_nr] or 0
            if uncalled_def_lines[line_nr] then hits = 0 end
            fd:write(string.format("DA:%d,%d\n", line_nr, hits))
            lf = lf + 1
            if hits > 0 then lh = lh + 1 end
         end
      end
      fd:write(string.format("LF:%d\n", lf))
      fd:write(string.format("LH:%d\n", lh))
      fd:write("end_of_record\n")

      ::continue::
   end

   fd:close()
end

runner.tick = false
runner.paused = false

function runner.save_stats()
   if not runner.initialized then return end
   if runner.paused then return end
   local all_line_hits = pchook.get_all_line_hits()
   local all_hits = pchook.get_all_hits()
   write_luacov_stats(runner.config, all_line_hits)
   write_lcov(runner.config, all_line_hits, all_hits)
end

local exit_ran = false

local function on_exit()
   if exit_ran then return end
   exit_ran = true

   pchook.stop()

   local all_line_hits = pchook.get_all_line_hits()
   local all_hits = pchook.get_all_hits()

   write_luacov_stats(runner.config, all_line_hits)
   write_lcov(runner.config, all_line_hits, all_hits)
end

function runner.init(configfile)
   if runner.initialized then return end

   runner.config = load_config(configfile)

   runner.tick = runner.config.tick or false
   runner.initialized = true

   if runner.tick then
      pchook.start({
         savestepsize = runner.config.savestepsize or 100,
         save_stats = runner.save_stats,
      })
   else
      pchook.start()
   end

   os.exit = function(code, close)
      on_exit()
      raw_os_exit(code, close)
   end

   if not runner.tick then
      local anchor = (newproxy or function() return {} end)()
      debug.setmetatable(anchor, { __gc = on_exit })
      runner._anchor = anchor
   end
end

runner.init()

return runner
