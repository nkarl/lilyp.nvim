local plugin=vim.fs.dirname(vim.fs.dirname(debug.getinfo(1,'S').source:sub(2)))
vim.opt.rtp:prepend(plugin)
local fs,g=require('lilyp.fs'),require('lilyp.git')
local function fixture()return fs.stage(fs.snapshot(plugin..'/tests/fixtures'))end
local function cmd(root,args,options)
  local command={'git','-C',root};vim.list_extend(command,args)
  local r=vim.system(command,vim.tbl_extend('force',{text=true},options or {})):wait(10000)
  assert(r.code==0,r.stderr);return vim.trim(r.stdout)
end
local function rejects(fn,needle)
  local ok,err=pcall(fn);assert(not ok,'Expected failure: '..needle)
  assert(tostring(err):find(needle,1,true),tostring(err))
end
local function identity(root)
  cmd(root,{'config','user.name','Lylip test'});cmd(root,{'config','user.email','test@example.invalid'})
end
local function index(root)
  local path=cmd(root,{'rev-parse','--git-path','index'})
  if not vim.startswith(path,'/') then path=root..'/'..path end
  return vim.fn.filereadable(path)==1 and fs.read(path) or ''
end
local root=fixture()
local before=fs.snapshot(root)
assert(not g.inspect(root).enabled)
g.snapshot(root)
assert(vim.deep_equal(before,fs.snapshot(root)) and not vim.uv.fs_lstat(root..'/.git'),'Inspection wrote files')
assert(g.enable(root).branch=='main');identity(root)
vim.fn.mkdir(root..'/build','p');fs.write(root..'/build/main.pdf','generated')
vim.fn.mkdir(root..'/backups','p');fs.write(root..'/backups/old.ly','old')
fs.write(root..'/outside.pdf','generated')
fs.write(root..'/unknown.txt','not a score source')
local plan=g.plan(root,'record')
assert(#plan.changes==5)
local first=g.save(plan,'Enter notation: refrain')
assert(cmd(root,{'symbolic-ref','--short','HEAD'})=='main')
assert(cmd(root,{'diff','--cached','--name-only'})=='','Record left staged reverse changes')
local tracked=cmd(root,{'ls-tree','-r','--name-only','HEAD'})
assert(not tracked:find('build',1,true) and not tracked:find('backups',1,true) and not tracked:find('.pdf',1,true))
assert(not tracked:find('unknown.txt',1,true))
assert(cmd(root,{'check-ignore','build'})=='build')
rejects(function()g.save(g.plan(root,'record'),'No changes')end,'No saved source changes')

local main=fs.read(root..'/main.ly')
fs.write(root..'/main.ly',main..'\n% pitch correction\n')
fs.write(root..'/sections/new verse.ily','newMusic = { c4 d e f }\n')
local second=g.save(g.plan(root,'record',{'main.ly'}),'Correct pitch: measure 12')
assert(cmd(root,{'rev-parse','HEAD^'})==first)
assert(cmd(root,{'ls-tree','-r','--name-only','HEAD'}):find('new verse.ily',1,true)==nil)
assert(cmd(root,{'diff','--cached','--name-only'})=='')
-- Manually staged changes block workbench commits; milestone snapshots preserve
-- their exact index bytes and leave main and its working files untouched.
cmd(root,{'add','--','sections/new verse.ily'})
local staged=index(root)
rejects(function()g.save(g.plan(root,'record'),'Record')end,'Staged changes exist')
local working=g.snapshot(root)
local milestone=g.save(g.plan(root,'milestone'),'First print','v1.0')
assert(index(root)==staged and cmd(root,{'rev-parse','HEAD'})==second)
assert(cmd(root,{'rev-parse','backup'})==milestone and cmd(root,{'rev-parse','v1.0^{commit}'})==milestone)
assert(cmd(root,{'cat-file','-t','v1.0'})=='tag')
assert(not cmd(root,{'cat-file','-p',milestone}):find('\nparent ',1,true),'Initial milestone inherited disposable main history')
assert(vim.deep_equal(working,g.snapshot(root)))
fs.write(root..'/main.ly',main..'\n% another edit\n')
local old_backup=cmd(root,{'rev-parse','backup'})
rejects(function()g.save(g.plan(root,'milestone'),'Print','v1.0')end,'Tag already exists')
assert(cmd(root,{'rev-parse','backup'})==old_backup)
local milestone2=g.save(g.plan(root,'milestone'),'Section checked: refrain','v1.1')
assert(cmd(root,{'rev-parse','backup^'})==milestone)
assert(index(root)==staged and cmd(root,{'rev-parse','HEAD'})==second)
cmd(root,{'reset','--quiet','HEAD','--','sections/new verse.ily'})

local stale=g.plan(root,'record')
fs.write(root..'/main.ly',main..'\n% newer edit\n')
rejects(function()g.save(stale,'Old review')end,'Saved source changed')
local buf=vim.fn.bufadd(root..'/main.ly');vim.fn.bufload(buf)
vim.api.nvim_buf_set_lines(buf,0,0,false,{'% unsaved'})
rejects(function()g.save(g.plan(root,'record'),'Unsaved')end,'Save or discard')
vim.bo[buf].modified=false;vim.api.nvim_buf_delete(buf,{force=true})
-- Parent repositories are detected and never used without project-local init.
local child=root..'/nested';vim.fn.mkdir(child,'p');fs.write(child..'/main.ly','nested')
assert(not g.inspect(child).enabled and g.inspect(child).parent==root)
rejects(function()g.plan(child,'record')end,'parent repository')
g.enable(child);identity(child)
assert(g.inspect(child).enabled and cmd(root,{'rev-parse','HEAD'})==second)
-- Remove only the nested test fixture from source scanning by moving it outside.
assert(vim.uv.fs_rename(child,root..'-nested'))

-- Source deletions are recorded, and one-file restoration leaves staging alone.
assert(vim.uv.fs_unlink(root..'/sections/refrain.ily'))
local deleted=g.save(g.plan(root,'record'),'Enter notation: new verse')
assert(not cmd(root,{'ls-tree','-r','--name-only',deleted}):find('refrain.ily',1,true))
local restore=g.restore_plan(root,milestone,{'sections/refrain.ily'})
staged=index(root)
assert(g.restore(restore)==1 and vim.fn.filereadable(root..'/sections/refrain.ily')==1)
assert(index(root)==staged and cmd(root,{'rev-parse','HEAD'})==deleted)
local newer=g.restore_plan(root,first)
fs.write(root..'/main.ly',main..'\n% external edit\n')
rejects(function()g.restore(newer)end,'Saved source changed')
local restore2=g.restore_plan(root,first)
before=g.snapshot(root)
local atomic=fs.atomic
fs.atomic=function(path,...)
  if path==root..'/main.ly' then error('injected restore write failure') end
  return atomic(path,...)
end
rejects(function()g.restore(restore2)end,'Restore failed')
fs.atomic=atomic
assert(vim.deep_equal(before,g.snapshot(root)),'Restore rollback lost source')
-- A competing tag creation must abort the whole milestone ref transaction.
local system=vim.system
local raced=false
local previous_index=index(root)
vim.system=function(args,opts)
  if args[1]=='git' and args[4]=='update-ref' and not raced then
    raced=true
    local r=system({'git','-C',root,'update-ref','refs/tags/race',milestone2},{text=true}):wait()
    assert(r.code==0,r.stderr)
  end
  return system(args,opts)
end
local ok,err=pcall(g.save,g.plan(root,'milestone'),'Print ready','race')
vim.system=system
assert(not ok and raced,tostring(err))
assert(cmd(root,{'rev-parse','backup'})==milestone2 and index(root)==previous_index)
-- Staging appearing during record preparation is preserved, and HEAD is not moved.
raced=false
vim.system=function(args,opts)
  if args[1]=='git' and args[4]=='write-tree' and not raced then
    raced=true
    local r=system({'git','-C',root,'add','--','unknown.txt'},{text=true}):wait()
    assert(r.code==0,r.stderr)
  end
  return system(args,opts)
end
ok,err=pcall(g.save,g.plan(root,'record'),'Correct rhythm')
vim.system=system
assert(not ok and raced and tostring(err):find('Staging changed',1,true),tostring(err))
assert(cmd(root,{'rev-parse','HEAD'})==deleted and cmd(root,{'diff','--cached','--name-only'})=='unknown.txt')
cmd(root,{'reset','--quiet','HEAD','--','unknown.txt'})
-- A checked-out backup branch in any worktree cannot be rewritten.
local worktree=root..'-stable'
cmd(root,{'worktree','add','--quiet',worktree,'backup'})
rejects(function()g.save(g.plan(root,'milestone'),'Print ready')end,'checked out in a worktree')
assert(cmd(root,{'rev-parse','backup'})==milestone2)
assert(#g.history(root,'record')==3 and #g.history(root,'milestone')==2)
assert(vim.fn.isdirectory(root..'/backups')==1 and fs.read(root..'/backups/old.ly')=='old')
assert(vim.fn.filereadable(root..'/.lilypond-curator.lock')==0)
local unborn=fixture();g.enable(unborn);identity(unborn)
g.save(g.plan(unborn,'milestone'),'Initial stable score')
assert(g.inspect(unborn).head==nil and g.inspect(unborn).branch=='main')
local workbench=g.plan(unborn,'record');assert(workbench.base==nil and #workbench.changes>0)
g.save(workbench,'Enter notation')
assert(cmd(unborn,{'diff','--cached','--name-only'})=='')
print('PASS: project-local Git, source selection/deletions, independent tagged milestone history, staging preservation, stale/dirty guards, parent/worktree isolation, restore review and rollback')
