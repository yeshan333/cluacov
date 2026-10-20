local M = {}

function M.exchange()
   local request = coroutine.yield("request") -- @request
   local response = coroutine.yield(request .. ":waiting") -- @waiting
   if response then -- @decision
      return response .. ":ok" -- @success
   else
      return "timeout" -- @timeout
   end
end

function M.fail_after_yield()
   local message = coroutine.yield("pending") -- @pending
   error(message) -- @error
   return "unreachable" -- @unreachable
end

return M
