-- vim.system may report code=0 with a nonzero termination signal. Keep failures
-- actionable even when a child emits no stdout/stderr.
local M={}
function M.failure(args,result,timeout)
  if result.code==0 and (result.signal or 0)==0 then return nil end
  local reason
  if result.code==124 then reason='timed out after '..tostring(timeout/1000)..' seconds'
  elseif (result.signal or 0)~=0 then reason='terminated by signal '..tostring(result.signal)
  else reason='exited with status '..tostring(result.code) end
  local log=(result.stdout or '')..(result.stderr or '')
  return tostring(args[1])..' '..reason..(log~='' and '\n'..log or '')
end
return M
