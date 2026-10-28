local plugin=vim.fs.dirname(vim.fs.dirname(debug.getinfo(1,'S').source:sub(2)))
vim.opt.rtp:prepend(plugin)
local fs=require('lilyp.fs')
local sessions=require('lilyp.session')
local ui=require('lilyp.ui')
local jobs=require('lilyp.validation_job')
local viewed,errors=nil,{}
require('lilyp').setup({viewer=function(pdf)viewed=pdf end})
vim.notify=function(message,level)if level==vim.log.levels.ERROR then errors[#errors+1]=tostring(message) end end
vim.o.columns,vim.o.lines=140,44
local function fixture()
  local project=fs.stage(fs.snapshot(plugin..'/tests/fixtures'))
  local session=sessions.open(project)
  local _,yaml=session:render();session:close();fs.write(project..'/score.yaml',yaml)
  return project
end
local function wait_for(predicate,message)
  assert(vim.wait(15000,predicate,5),message or 'Asynchronous validation timed out')
end
local function press(state,key)
  for _,map in ipairs(vim.api.nvim_buf_get_keymap(state.buf,'n')) do
    if map.lhs==key then return map.callback() end
  end
  error('Missing mapping: '..key)
end

-- Preview returns control before compilation and leaves the real project alone.
local project=fixture()
local before=fs.snapshot(project)
local state=ui.open(project)
assert(state.set('staff_size',16))
press(state,'p')
local operation=assert(state.operation)
assert(state.busy and not operation:is_done() and not viewed)
wait_for(function()return operation.process~=nil end)
assert(not state.set('staff_size',17) and not state.reload(),'Busy drafts accepted edits/reload')
assert(state.session.draft.staff_size==16 and state.apply_async()==nil)
local responsive=false;vim.schedule(function()responsive=true end)
wait_for(function()return not state.busy end)
assert(responsive and operation:is_done() and #errors==0)
assert(viewed and vim.fn.filereadable(viewed)==1)
assert(vim.deep_equal(before,fs.snapshot(project)) and not vim.uv.fs_lstat(project..'/build'))
local retained=vim.deepcopy(state.session.temporary)

-- Ctrl+C stops an active compiler, removes only this attempt's temporary copies,
-- and keeps the draft plus the earlier viewer's PDF available.
press(state,'p');operation=assert(state.operation)
wait_for(function()return operation.process~=nil end)
local abandoned=vim.deepcopy(state.session.temporary)
press(state,'<C-C>')
wait_for(function()return not state.busy end)
assert(operation.lifecycle.outcome.tag=='cancelled' and operation:is_done() and #errors==0)
assert(state.status:find('cancelled',1,true) and state.session.draft.staff_size==16)
assert(vim.deep_equal(retained,state.session.temporary) and vim.fn.filereadable(viewed)==1)
for i=#retained+1,#abandoned do assert(not vim.uv.fs_lstat(abandoned[i]),'Cancelled temporary copy leaked') end
assert(vim.deep_equal(before,fs.snapshot(project)))

-- Cancellation before the worker starts must also leave sources untouched.
operation=state.apply_async();assert(state.cancel())
wait_for(function()return not state.busy end)
assert(operation.lifecycle.outcome.tag=='cancelled' and vim.deep_equal(before,fs.snapshot(project)))

-- Changes to the real source while an async compiler runs still block Apply.
operation=state.apply_async()
wait_for(function()return operation.process~=nil end)
fs.write(project..'/sections/refrain.ily',before['sections/refrain.ily']..'\n% newer source\n')
local external=fs.snapshot(project)
wait_for(function()return not state.busy end)
assert(#errors==1 and errors[1]:find('Project changed',1,true))
assert(vim.deep_equal(external,fs.snapshot(project)) and not vim.uv.fs_lstat(project..'/.lilypond-curator.lock'))
assert(state.session.draft.staff_size==16)
state.close()

-- Publication can yield for its real-path compile without releasing the lock or
-- accepting cancellation; after that compile, caught failure still rolls back.
project=fixture();local session=sessions.open(project);session:set('staff_size',16)
before=fs.snapshot(project)
local ok,result,done,publishing=false,nil,false,false
local old_system=vim.system
vim.system=function(args,opts,callback)
  if args[1]=='lilypond' and args[#args]==project..'/main.ly' then
    assert(vim.uv.fs_lstat(project..'/.lilypond-curator.lock'))
    assert(not operation:cancel(),'Publication accepted cancellation')
    -- A harmless source comment inserted during publication must be preserved,
    -- while the earlier style/spec writes are rolled back.
    fs.write(project..'/sections/refrain.ily',before['sections/refrain.ily']..'\n% edit during publication\n')
    publishing=true
  end
  return old_system(args,opts,callback)
end
operation=jobs.start(function(job)return session:apply(job)end,function(outcome)
  ok,result,done=outcome.tag=='succeeded',outcome.tag=='succeeded' and outcome.value or tostring(outcome),true
end)
wait_for(function()return done end)
vim.system=old_system
assert(publishing and not ok and tostring(result):find('Apply failed',1,true),tostring(result))
assert(fs.read(project..'/score.yaml')==before['score.yaml'] and fs.read(project..'/style.ily')==before['style.ily'])
assert(fs.read(project..'/sections/refrain.ily'):find('edit during publication',1,true))
assert(not vim.uv.fs_lstat(project..'/.lilypond-curator.lock'));session:close()

-- A complete keyboard-triggered Apply publishes the reviewed draft, reopens its
-- session, and protects MIDI through both staged and real-path compilation.
project=fixture();state=ui.open(project);assert(state.set('staff_size',16))
press(state,'a');operation=assert(state.operation)
wait_for(function()return not state.busy end)
assert(operation:is_done() and state.status=='Applied.' and state.session.values.staff_size==16)
assert(vim.fn.filereadable(require('lilyp.output').directory(project)..'/main.pdf')==1)
state.close()

-- Force-closing the float cancels validation and disposes its retained view when
-- the child exits, rather than leaving an invisible application and temp copies.
project=fixture();state=ui.open(project)
operation=state.preview_async()
wait_for(function()return operation.process~=nil end)
local temporary=vim.deepcopy(state.session.temporary)
vim.api.nvim_win_close(state.win,true)
wait_for(function()return operation:is_done() and state.closed end)
assert(operation.lifecycle.outcome.tag=='cancelled' and ui.current()==nil)
for _,path in ipairs(temporary) do assert(not vim.uv.fs_lstat(path)) end

-- Initial Save spec runs page parity asynchronously as well, and cancellation
-- at the raster stage must leave even the presentation metadata unpublished.
project=fs.stage(fs.snapshot(plugin..'/tests/fixtures'))
before=fs.snapshot(project);session=sessions.open(project)
local phases={};done=false
operation=jobs.start(function(job)return session:apply(job)end,function(outcome)
  ok,result,done=outcome.tag=='succeeded',outcome.tag=='succeeded' and outcome.value or tostring(outcome),true
end,function(message)
  phases[message]=true
  if message=='Comparing rendered pages…' then assert(operation:cancel()) end
end)
wait_for(function()return done end)
assert(not ok and operation.lifecycle.outcome.tag=='cancelled' and phases['Comparing rendered pages…'])
assert(vim.deep_equal(before,fs.snapshot(project)));session:close()
state=ui.open(project);operation=state.apply_async()
wait_for(function()return not state.busy end)
assert(operation:is_done() and state.session.specified and state.status=='Applied.')
state.close()

-- A process that ignores SIGTERM is killed after the cancellation grace period.
-- The ready file makes cancellation wait for the signal handler to be installed.
local ready=vim.fn.tempname();done=false
operation=jobs.start(function(job)
  return job:run({vim.v.progpath,'--headless','-u','NONE','-i','NONE','-l',plugin..'/tests/support/process-child.lua','ignore-term',ready},
    'Testing cancellation')
end,function(outcome)ok,result,done=outcome.tag=='succeeded',outcome.tag=='succeeded' and outcome.value or tostring(outcome),true end)
wait_for(function()return vim.uv.fs_lstat(ready)~=nil end)
assert(operation:cancel());wait_for(function()return done end)
assert(not ok and operation.lifecycle.outcome.tag=='cancelled' and not operation.process)
assert(vim.uv.fs_unlink(ready))

-- The asynchronous deadline must finish even if the child ignores its initial
-- SIGTERM. Exercise the same watchdog with a shorter test-only deadline.
ready=vim.fn.tempname();done=false
operation=jobs.start(function(job)
  job.timeout_ms=500
  return job:run({vim.v.progpath,'--headless','-u','NONE','-i','NONE','-l',plugin..'/tests/support/process-child.lua','ignore-term',ready},
    'Testing timeout')
end,function(outcome)ok,result,done=outcome.tag=='succeeded',outcome.tag=='succeeded' and outcome.value or tostring(outcome),true end)
wait_for(function()return vim.uv.fs_lstat(ready)~=nil end)
wait_for(function()return done end)
assert(ok and result.code==124 and result.signal==9 and not operation.process)
assert(require('lilyp.process').failure({vim.v.progpath},result,500):find('timed out',1,true))
assert(vim.uv.fs_unlink(ready))
print('PASS: responsive staged validation, progress, active/early cancellation, preview retention, stale-source guards, publication lock/rollback, keyboard Apply, and forced-close cleanup')

-- Reuse one validated plan to distinguish rollback and cleanup outcomes without
-- compiling repeatedly for failures before the real-path publication compiler.
project=fixture();session=sessions.open(project);session:set('staff_size',17)
local validated=session:preview();local plan=validated.plan
before=fs.snapshot(project)
local atomic,unlink=fs.atomic,vim.uv.fs_unlink
local completion
local function publish_attempt()
  completion=nil
  operation=jobs.start(function(job)return require('lilyp.transaction').publish(session,plan,validated,job)end,
    function(value)completion=value end)
  wait_for(function()return completion~=nil end)
  assert(operation:is_done() and not operation:cancel())
  return completion
end
fs.atomic=function(path,text)
  if path==project..'/score.yaml' then error('injected specification write failure') end
  return atomic(path,text)
end
-- Cleanup trouble must not hide the original failure or the successful rollback.
vim.uv.fs_unlink=function(path)
  if path==project..'/.lilypond-curator.lock' then return nil,'injected lock cleanup failure' end
  return unlink(path)
end
completion=publish_attempt()
fs.atomic=atomic;vim.uv.fs_unlink=unlink
assert(completion.tag=='failed' and completion.publication=='restored' and #completion.cleanup==1)
assert(completion.error:find('injected specification write failure',1,true))
assert(unlink(project..'/.lilypond-curator.lock'))
assert(vim.deep_equal(before,fs.snapshot(project)))
-- A failed restoration leaves an explicit partial publication outcome.
local style_writes=0
fs.atomic=function(path,text)
  if path==project..'/score.yaml' then error('injected specification write failure') end
  if path==project..'/style.ily' then
    style_writes=style_writes+1
    if style_writes==2 then error('injected restoration failure') end
  end
  return atomic(path,text)
end
completion=publish_attempt();fs.atomic=atomic
assert(completion.tag=='failed' and completion.publication=='partial')
assert(completion.error:find('manual correction',1,true))
fs.write(project..'/style.ily',before['style.ily'])
-- Successful publication with a leftover lock is still published success.
vim.uv.fs_unlink=function(path)
  if path==project..'/.lilypond-curator.lock' then return nil,'injected lock cleanup failure' end
  return unlink(path)
end
completion=publish_attempt();vim.uv.fs_unlink=unlink
assert(completion.tag=='succeeded' and completion.publication=='published' and #completion.cleanup==1)
assert(fs.read(project..'/style.ily')~=before['style.ily'])
assert(unlink(project..'/.lilypond-curator.lock'));session:close()

-- Closing the application during publication must finish the operation, then
-- dispose the view. Closing is not a second cancellation/publication state.
project=fixture();state=ui.open(project);assert(state.set('staff_size',16))
local closed_during_publication=false
vim.system=function(args,opts,callback)
  if args[1]=='lilypond' and args[#args]==project..'/main.ly' then
    closed_during_publication=true
    assert(not operation:cancel())
    vim.api.nvim_win_close(state.win,true)
  end
  return old_system(args,opts,callback)
end
operation=state.apply_async()
wait_for(function()return operation:is_done() and state.closed end)
vim.system=old_system
assert(closed_during_publication and operation.lifecycle.outcome.tag=='succeeded')
assert(operation.lifecycle.outcome.publication=='published' and ui.current()==nil)
assert(not vim.uv.fs_lstat(project..'/.lilypond-curator.lock'))
print('PASS: typed Apply restoration/partial/cleanup outcomes, preserved primary errors, and UI closure during non-cancellable publication')

-- Validation shutdown owns the entire compiler group as ordinary builds do.
ready=vim.fn.tempname();local shutdown_completions=0
operation=jobs.start(function(job)
  return job:run({vim.v.progpath,'--headless','-u','NONE','-i','NONE','-l',plugin..'/tests/support/process-child.lua','descendant',ready},
    'Testing validation shutdown')
end,function(value)completion=value;shutdown_completions=shutdown_completions+1 end)
wait_for(function()return vim.uv.fs_lstat(ready)~=nil end)
local parent,child=operation.process.pid,tonumber(fs.read(ready))
jobs.shutdown()
local function dead(pid)
  local exists,stat=pcall(fs.read,'/proc/'..pid..'/stat')
  return not exists or not stat or stat:match('^%d+ %b() Z')~=nil
end
wait_for(function()return dead(parent) and dead(child)end)
assert(operation:is_done() and completion.tag=='cancelled' and shutdown_completions==1)
assert(vim.uv.fs_unlink(ready))
print('PASS: validation shutdown terminates compiler descendants and completes cancellation once')
