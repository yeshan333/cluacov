local pchook = require("cluacov.pchook")
local deepbranches = require("cluacov.deepbranches")
local deepactivelines = require("cluacov.deepactivelines")
local branchcov = require("cluacov.branchcov")

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
      proto.signature or "",
   }, ":")
end

-- Read only real Lua tokens for display names. Function existence and lexical
-- order come from the Proto tree, so comments/strings cannot change FNF.
local function function_names(source, definitions)
   local tokens = {}
   local i, line = 1, 1
   local function advance(next_i)
      local _, newlines = source:sub(i, next_i - 1):gsub("\n", "")
      line = line + newlines
      i = next_i
   end
   while i <= #source do
      local char = source:sub(i, i)
      local comment = source:sub(i, i + 1) == "--"
      local start = comment and i + 2 or i
      local equals = source:match("^%[(=*)%[", start)
      if equals then
         local _, finish = source:find("]" .. equals .. "]", start + #equals + 2, true)
         advance(finish and finish + 1 or #source + 1)
      elseif comment or (i == 1 and source:sub(1, 2) == "#!") then
         advance(source:find("\n", i, true) or #source + 1)
      elseif char == "'" or char == '"' then
         local finish = i + 1
         while finish <= #source do
            local next_char = source:sub(finish, finish)
            if next_char == "\\" then
               finish = finish + 2
            elseif next_char == char then
               finish = finish + 1
               break
            else
               finish = finish + 1
            end
         end
         advance(finish)
      elseif char:match("%s") then
         advance(i + 1)
      else
         local word = source:match("^[_%a][_%w]*", i)
         tokens[#tokens + 1] = { value = word or char, line = line }
         advance(i + #(word or char))
      end
   end

   local names = {}
   for index, token in ipairs(tokens) do
      if token.value == "function" then
         local name
         local j = index + 1
         while tokens[j] and tokens[j].value ~= "(" do
            if tokens[j].value:match("^[_%a][_%w]*$") then
               name = tokens[j].value
            end
            j = j + 1
         end
         if not name and tokens[index - 1] and tokens[index - 1].value == "=" then
            local previous = tokens[index - 2]
            if previous and previous.value:match("^[_%a][_%w]*$")
               and not (tokens[index - 3] and tokens[index - 3].value == ",")
            then
               name = previous.value
            end
         end
         names[#names + 1] = { name = name, line = token.line }
      end
   end

   local used = {}
   for index, def in ipairs(definitions) do
      local token = names[index]
      local name = token and token.line == def.linedefined and token.name
         or ("anonymous@" .. def.linedefined .. ":" .. def.proto_path)
      if used[name] then
         name = name .. "@" .. def.linedefined .. ":" .. def.proto_path
      end
      used[name] = true
      def.name = name
   end
end

local function add_counts(to, from)
   for key, count in pairs(from or {}) do
      to[key] = (to[key] or 0) + count
   end
end

local function match_records(root, definitions, entries)
   local by_path, by_shape, result = {}, {}, {}
   local unmatched = 0
   local function add_definition(def)
      by_path[def.proto_path] = def
      local key = proto_key(def)
      if by_shape[key] == nil then
         by_shape[key] = def
      else
         by_shape[key] = false -- ambiguous without an observed lexical path
      end
   end
   root.proto_path = "0"
   add_definition(root)
   for _, def in ipairs(definitions) do add_definition(def) end
   for _, entry in ipairs(entries) do
      local def
      if entry.proto_path then
         def = by_path[entry.proto_path]
         if def and proto_key(def) ~= proto_key(entry) then def = nil end
      else
         def = by_shape[proto_key(entry)]
      end
      if def then
         local target = result[def.proto_path]
         if not target then
            target = { hits = {}, edges = {}, calls = 0 }
            result[def.proto_path] = target
         end
         target.calls = target.calls + (entry.calls or 0)
         add_counts(target.hits, entry.hits)
         for pc, successors in pairs(entry.edges or {}) do
            target.edges[pc] = target.edges[pc] or {}
            add_counts(target.edges[pc], successors)
         end
      elseif (entry.calls or 0) > 0 or next(entry.hits or {}) then
         unmatched = unmatched + 1
      end
   end
   return result, unmatched
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

local warned_sources = {}

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

      local source_text = ""
      local fh = io.open(filename, "r")
      if fh then
         source_text = fh:read("*a")
         fh:close()
      end
      local func_defs = pchook.get_func_defs(func)
      function_names(source_text, func_defs)
      local records, unmatched = match_records(pchook.get_hits(func)[1], func_defs, proto_list)
      if unmatched > 0 and not warned_sources[source] then
         warned_sources[source] = true
         io.stderr:write(string.format(
            "[cluacov] warning: %d function record(s) cannot be matched uniquely to %s; "
               .. "their function/branch counts are omitted (source changed or collection started after loading)\n",
            unmatched, filename))
      end

      for _, fn in ipairs(func_defs) do
         fd:write(string.format("FN:%d,%s\n", fn.linedefined, fn.name))
      end
      fd:write(string.format("FNF:%d\n", #func_defs))

      local fns_hit = 0
      local definition_lines = {}
      for _, fn in ipairs(func_defs) do
         local entry = records[fn.proto_path]
         local hits = entry and entry.calls or 0
         fd:write(string.format("FNDA:%d,%s\n", hits, fn.name))
         if hits > 0 then fns_hit = fns_hit + 1 end
         if not active_lines[fn.linedefined] then
            definition_lines[fn.linedefined] = (definition_lines[fn.linedefined] or 0) + hits
         end
      end
      -- genhtml needs a DA category at every FN start. A nested function's
      -- declaration need not have its own line-hook instruction (e.g. Lua
      -- puts CLOSURE on its end line); use call counts for that marker.
      for line in pairs(definition_lines) do active_lines[line] = true end
      fd:write(string.format("FNH:%d\n", fns_hit))

      local block_id = 0
      local brf, brh = 0, 0
      for _, b in ipairs(branches) do
         local entry = records[b.proto_path]
         brf = brf + #b.targets
         for ti, t in ipairs(b.targets) do
            local taken = branchcov.target_hits(b, t, entry)
            fd:write(string.format("BRDA:%d,%d,%d,%s\n",
               b.line, block_id, ti - 1,
               taken > 0 and tostring(taken) or "-"))
            if taken > 0 then brh = brh + 1 end
         end
         block_id = block_id + 1
      end
      fd:write(string.format("BRF:%d\n", brf))
      fd:write(string.format("BRH:%d\n", brh))

      -- Do not turn a shared line red when another function on it was called.
      local uncalled_def_lines, called_def_lines = {}, {}
      for _, def in ipairs(func_defs) do
         local entry = records[def.proto_path]
         local lines = entry and entry.calls > 0 and called_def_lines or uncalled_def_lines
         lines[def.linedefined] = true
         lines[def.lastlinedefined] = true
      end
      for line in pairs(called_def_lines) do uncalled_def_lines[line] = nil end

      local lf, lh = 0, 0
      local max = line_data.max or 0
      for line_nr in pairs(active_lines) do
         if line_nr > max then max = line_nr end
      end
      for line_nr = 1, max do
         if active_lines[line_nr] then
            local hits = definition_lines[line_nr] or line_data[line_nr] or 0
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

   -- Periodic saves do not replace the final flush: a short process may
   -- exit before its first tick, or execute more code after its last tick.
   local anchor = (newproxy or function() return {} end)()
   debug.setmetatable(anchor, { __gc = on_exit })
   runner._anchor = anchor
end

runner.init()

return runner
