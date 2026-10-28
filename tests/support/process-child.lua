-- Disposable subprocess fixtures use the same Neovim/Lua runtime as the tests.
local mode=assert(arg[1])
if mode=='success' then io.stdout:write('success\n');io.stdout:flush()
elseif mode=='exit' then os.exit(7)
elseif mode=='signal' then vim.uv.kill(vim.fn.getpid(),9)
elseif mode=='logs' then io.stdout:write('output detail\n');io.stdout:flush();io.stderr:write('error detail\n');io.stderr:flush();os.exit(2)
elseif mode=='sleep' then vim.wait(60000,function()return false end)
elseif mode=='ignore-term' or mode=='descendant' then
  local ffi=require('ffi')
  ffi.cdef('typedef void (*lilyp_sighandler_t)(int); lilyp_sighandler_t signal(int, lilyp_sighandler_t);')
  ffi.C.signal(15,ffi.cast('lilyp_sighandler_t',1)) -- SIG_IGN, overriding the editor's default handler.
  local pid
  if mode=='descendant' then
    local child=vim.system({vim.v.progpath,'--headless','-u','NONE','-i','NONE','-l',debug.getinfo(1,'S').source:sub(2),'sleep'})
    pid=child.pid
  end
  local file=assert(io.open(assert(arg[2]),'w'));file:write(pid and tostring(pid) or 'ready');file:close()
  vim.wait(60000,function()return false end)
else error('Unknown child fixture: '..mode) end
