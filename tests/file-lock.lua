local root=vim.fn.fnamemodify(debug.getinfo(1,'S').source:sub(2),':p:h:h')
vim.opt.rtp:prepend(root)
local fs=require('lilyp.fs')
local lock=require('lilyp.file_lock')
local folder=assert(vim.uv.fs_mkdtemp('/tmp/lilyp-lock-test-XXXXXX'))
local path=folder..'/.score-build.lock'
-- Python's earlier flock implementation left an empty marker after success.
fs.write(path,'')
local inode=vim.uv.fs_stat(path).ino
local release=lock.acquire(path)
assert(not pcall(lock.acquire,path),'An active holder was ignored')
assert(vim.json.decode(fs.read(path)).locking=='flock')
release();release()
assert(vim.uv.fs_stat(path).ino==inode,'Release replaced/unlinked the shared lock inode')
release=lock.acquire(path);release()
-- Independent editors conflict; SIGKILL automatically releases the kernel lock.
local ready=folder..'/ready'
local child=vim.system({vim.v.progpath,'--headless','-u','NONE','-i','NONE','-l',root..'/tests/support/lock-holder.lua',path,ready},{text=true})
local ok,err=pcall(function()
  assert(vim.wait(5000,function()return vim.fn.filereadable(ready)==1 end,10),'Lock holder did not start')
  assert(not pcall(lock.acquire,path),'A different editor ignored the active lock')
end)
child:kill(9);child:wait(5000)
assert(ok,err)
release=lock.acquire(path);release()
assert(vim.uv.fs_stat(path).ino==inode)
-- Native file-existence locks from the intermediate implementation need a dead
-- owner before migration; a live legacy editor remains protected.
local old=vim.json.encode({pid=vim.fn.getpid(),token='legacy'})
fs.write(path,old)
assert(not pcall(lock.acquire,path) and fs.read(path)==old)
fs.write(path,vim.json.encode({pid=child.pid,token='legacy'}))
release=lock.acquire(path);release()
fs.write(path,'not lock metadata')
assert(not pcall(lock.acquire,path) and fs.read(path)=='not lock metadata')
fs.write(path,'');release=lock.acquire(path);release()
-- A lock path must never cause a score/source file to be truncated.
assert(vim.uv.fs_unlink(path))
local source=folder..'/source.ly';fs.write(source,'keep source')
assert(vim.uv.fs_symlink(source,path))
assert(not pcall(lock.acquire,path) and fs.read(source)=='keep source')
print('PASS: empty legacy marker migration, same/cross-editor exclusion, stable inode, crash recovery, live/dead legacy holders, malformed metadata, and source preservation')
