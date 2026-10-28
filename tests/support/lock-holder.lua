local root=vim.fn.fnamemodify(debug.getinfo(1,'S').source:sub(2),':p:h:h:h')
vim.opt.rtp:prepend(root)
local release=require('lilyp.file_lock').acquire(assert(arg[1]))
require('lilyp.fs').write(assert(arg[2]),tostring(vim.fn.getpid()))
-- The test kills this process without allowing Lua cleanup to run.
vim.wait(20000,function()return false end,20)
release()
