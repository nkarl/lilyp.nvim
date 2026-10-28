-- Attempt every cleanup, even when an earlier resource cannot be released.
local M={}
function M.clean(tasks,result)
  for i=#tasks,1,-1 do
    local task=tasks[i];tasks[i]=nil
    local ok,err=pcall(task.run,result)
    if not ok then result.cleanup[#result.cleanup+1]=task.label..': '..tostring(err) end
  end
  return result
end
function M.timer(timer)
  if timer and not timer:is_closing() then
    local stopped,stop_error=pcall(timer.stop,timer)
    local closed,close_error=pcall(timer.close,timer)
    assert(stopped and closed,table.concat({not stopped and tostring(stop_error) or '',not closed and tostring(close_error) or ''},' '))
  end
end
function M.signal(process,number)
  if not process then return end
  local ok=vim.uv.kill(-process.pid,number)
  if not ok then pcall(process.kill,process,number) end
end
return M
