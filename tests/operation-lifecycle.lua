local root=vim.fs.dirname(vim.fs.dirname(debug.getinfo(1,'S').source:sub(2)))
vim.opt.rtp:prepend(root)
local life=require('lilyp.operation_lifecycle')
local out=require('lilyp.operation_outcome')
local resources=require('lilyp.operation_resources')
local function rejects(fn)assert(not pcall(fn),'Invalid lifecycle accepted')end
for _,kind in ipairs({'validation','build'}) do
  local s=life.new(kind)
  assert(life.cancellable(s))
  rejects(function()life.move(s,'completed')end)
  life.move(s,kind=='validation' and 'validating' or 'running')
  life.move(s,'publishing');assert(not life.cancellable(s))
  rejects(function()life.move(s,'cancelling')end)
  life.move(s,'recovering');assert(not life.cancellable(s))
  life.move(s,'cleaning')
  rejects(function()life.move(s,'completed')end)
  local result=out.failed('write failed','partial')
  life.complete(s,result);assert(s.outcome==result)
  rejects(function()life.complete(s,result)end)
  s=life.new(kind);life.move(s,'cancelling');life.move(s,'cleaning');life.complete(s,out.cancelled())
end
rejects(function()out.assert_valid({tag='cancelled',publication='published',cleanup={}})end)
rejects(function()out.succeeded(true,'partial')end)
rejects(function()out.assert_valid({tag='failed',cleanup={},publication='unchanged'})end)
local released={}
local result=resources.clean({
  {label='first',run=function()released.first=true end},
  {label='broken',run=function()error('injected cleanup failure')end},
  {label='last',run=function()released.last=true end},
},out.succeeded(true,'published'))
assert(released.first and released.last and #result.cleanup==1 and result.publication=='published' and result.tag=='succeeded')
assert(out.from_error(result)==result and tostring(result):find('Cleanup needs attention',1,true))
print('PASS: distinct lifecycle graphs, illegal transitions, publication/recovery cancellation boundary, completion contracts, and exhaustive cleanup')

-- Process completion tokens reject duplicate/late callbacks, including a prior
-- process callback arriving while the next process owns the coroutine.
local jobs=require('lilyp.validation_job')
local old_system=vim.system
local requests={}
vim.system=function(_,_,callback)
  local process={pid=1073741824,kill=function()end,wait=function()return {code=0}end}
  requests[#requests+1]={callback=callback,process=process}
  return process
end
local function wait_for(fn)assert(vim.wait(3000,fn,5),'Lifecycle did not settle')end
local count,result=0
local job=jobs.start(function(worker)
  worker:run({'fake'},'First')
  worker:run({'fake'},'Second')
  return 'validated'
end,function(value)count=count+1;result=value end)
wait_for(function()return #requests==1 end)
local first=job.request
requests[1].callback({code=0});requests[1].callback({code=0})
wait_for(function()return #requests==2 end)
assert(not job:is_done() and job.request~=first)
requests[2].callback({code=0});requests[1].callback({code=0});requests[2].callback({code=0})
wait_for(function()return job:is_done()end)
job.resume();assert(count==1 and result.tag=='succeeded' and result.value=='validated' and result.publication=='unchanged')
assert(first.watchdog:is_closing() and not job.process and not job:cancel())
-- All cleanup attempts precede the single completion, even on early cancel.
local cleaned={}
job=jobs.start(function()error('Cancelled worker ran')end,function(value)
  assert(cleaned[1] and cleaned[2]);result=value;count=count+1
end)
job:defer('first cleanup',function()cleaned[1]=true end)
job:defer('failing cleanup',function()error('cannot clean')end)
job:defer('last cleanup',function()cleaned[2]=true end)
assert(job:cancel() and not job:cancel())
wait_for(function()return job:is_done()end)
assert(result.tag=='cancelled' and #result.cleanup==1)
-- Recovery rejects cancellation and preserves incomplete rollback facts.
job=jobs.start(function(worker)
  worker:phase('Publishing',true);worker:recovering()
  assert(not worker:cancel())
  error(out.failed('recover manually','partial'),0)
end,function(value)result=value end)
wait_for(function()return job:is_done()end)
assert(result.tag=='failed' and result.publication=='partial')
vim.system=old_system
print('PASS: validation callback ownership, one completion, cleanup before completion, early cancellation, and non-cancellable publication/recovery/shutdown')
-- A timer failure must still attempt closure, and setup failure after spawn
-- must terminate its owned process before reporting completion.
local closed=false
local timer={is_closing=function()return false end,stop=function()error('stop failed')end,close=function()closed=true end}
local cleanup=resources.clean({{label='timer',run=function()resources.timer(timer)end}},out.failed('setup failed'))
assert(closed and #cleanup.cleanup==1)
vim.system=function(_,_,callback)
  return {pid=1073741824,kill=function()end,wait=function()return {code=0}end}
end
local new_timer=vim.uv.new_timer
vim.uv.new_timer=function()return nil end
job=jobs.start(function(worker)return worker:run({'fake'},'No timer')end,function(value)result=value end)
wait_for(function()return job:is_done()end)
vim.uv.new_timer=new_timer;vim.system=old_system
assert(result.tag=='failed' and result.publication=='unchanged' and not job.process)
print('PASS: timer closure after stop failure and process cleanup after post-spawn setup failure')

-- Closing admission precedes draining jobs, so completion observers cannot
-- enqueue another process while the editor is shutting down.
vim.system=function(_,_,callback)
  local process={pid=1073741824,kill=function()end,wait=function()return {code=0}end}
  requests[#requests+1]={callback=callback,process=process}
  return process
end
-- Publication can yield and survive shutdown; it must not turn into cancellation.
job=jobs.start(function(worker)
  worker:phase('Publishing',true)
  assert(not worker:cancel())
  worker:run({'fake'},'Published compiler')
  worker:publication(out.succeeded(true,'published',{'lock cleanup failed'}))
  return 'Applied.'
end,function(value)result=value end)
wait_for(function()return job.process~=nil end)
vim.schedule(function()requests[#requests].callback({code=0})end)
jobs.shutdown()
assert(job:is_done() and result.tag=='succeeded' and result.publication=='published' and #result.cleanup==1)
vim.system=old_system
rejects(function()jobs.start(function()end,function()end)end)
print('PASS: shutdown drains non-cancellable publication and rejects new jobs')
