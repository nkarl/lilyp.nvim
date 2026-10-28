local plugin=vim.fs.dirname(vim.fs.dirname(debug.getinfo(1,'S').source:sub(2)))
vim.opt.rtp:prepend(plugin)
local fs=require('lilyp.fs')
local function fails(fn,needle)
  local ok,err=pcall(fn)
  assert(not ok,'Expected failure')
  assert(tostring(err):find(needle,1,true),tostring(err))
end

-- A copy failure cleans the newly allocated directory, even after a file was
-- successfully staged. It never touches the source snapshot.
local write=fs.write
local paths={}
fs.write=function(path,text)
  paths[#paths+1]=path
  if #paths==2 then error('injected staging write failure') end
  return write(path,text)
end
fails(function()fs.stage({['one.ly']='one\n',['two.ily']='two\n'})end,'injected staging write failure')
fs.write=write
assert(#paths==2 and not vim.uv.fs_lstat(vim.fs.dirname(paths[1])),'Partial staging directory leaked')

-- A collision with an existing directory must not overwrite or remove its data.
local existing=vim.fn.tempname();vim.fn.mkdir(existing,'p');fs.write(existing..'/keep','keep\n')
local tempname=vim.fn.tempname
vim.fn.tempname=function()return existing end
fails(function()fs.stage({['new.ly']='new\n'})end,'staging directory')
vim.fn.tempname=tempname
assert(fs.read(existing..'/keep')=='keep\n' and not vim.uv.fs_lstat(existing..'/new.ly'))
vim.fn.delete(existing,'rf')

-- If allocating the second validation copy fails, the first copy is already
-- registered with the session so closing/error cleanup can remove it.
local project=fs.stage(fs.snapshot(plugin..'/tests/fixtures'))
local session=require('lilyp.session').open(project)
local plan=session:plan()
local stage,calls,first=fs.stage,0,nil
fs.stage=function(snapshot)
  calls=calls+1
  if calls==2 then error('injected second stage failure') end
  first=stage(snapshot);return first
end
fails(function()require('lilyp.transaction').validate(session,plan)end,'injected second stage failure')
fs.stage=stage
assert(#session.temporary==1 and session.temporary[1]==first,'First validation copy was not tracked')
session:close();assert(not vim.uv.fs_lstat(first))

-- A failed sibling rename leaves the existing destination intact and removes
-- the temporary sibling rather than leaving it in a subsequent source snapshot.
local original=fs.snapshot(project)
local rename=vim.uv.fs_rename
vim.uv.fs_rename=function()return nil,'injected rename failure' end
fails(function()fs.atomic(project..'/style.ily','replacement\n')end,'injected rename failure')
vim.uv.fs_rename=rename
assert(vim.deep_equal(original,fs.snapshot(project)))
vim.fn.delete(project,'rf')
print('PASS: partial staging cleanup, collision preservation, tracked validation copies, and failed atomic-rename cleanup')
