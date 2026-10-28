-- Coroutine validation owns compiler groups; publication/recovery cannot cancel.
local life=require('lilyp.operation_lifecycle')
local out=require('lilyp.operation_outcome')
local resources=require('lilyp.operation_resources')
local M={}
local active={}
local stopping=false
local Job={};Job.__index=Job
function Job:is_done()return self.lifecycle.phase=='completed'end
function Job:cancellable()return life.cancellable(self.lifecycle)end
function Job:check()
  if self.lifecycle.phase=='cancelling' then error(out.cancelled(),0) end
end
function Job:defer(label,fn)
  assert(not self:is_done() and self.lifecycle.phase~='cleaning','Cannot register cleanup after settlement')
  self.tasks[#self.tasks+1]={label=label,run=fn}
end
function Job:issue(message)self.issues[#self.issues+1]=tostring(message)end
function Job:publication(result)
  out.assert_valid(result)
  assert(result.tag~='cancelled' and (self.lifecycle.phase=='publishing' or self.lifecycle.phase=='recovering'),'Publication facts require publication/recovery')
  self.publication_result=result
end
function Job:recovering()
  life.move(self.lifecycle,'recovering')
  if self.progress then local ok,err=pcall(self.progress,'Recovering original files…',false);if not ok then self:issue(err) end end
end
function Job:phase(message,publishing)
  self:check()
  if self.lifecycle.phase=='queued' then life.move(self.lifecycle,'validating') end
  if publishing and self.lifecycle.phase~='publishing' then life.move(self.lifecycle,'publishing') end
  if self.progress then self.progress(message,self:cancellable()) end
  self:check()
end
function Job:run(args,message)
  self:phase(message)
  local timeout=self.timeout_ms or 30000
  local request={state='waiting'}
  self.request=request
  self:defer('Compiler watchdog',function()resources.timer(request.watchdog)end)
  self:defer('Cancellation timer',function()resources.timer(request.escalation)end)
  self:defer('Compiler process',function()
    if request.state=='waiting' and request.process then
      resources.signal(request.process,9)
      request.process:wait(1000)
      request.state='abandoned';self.process=nil;self.request=nil
    end
  end)
  request.process=vim.system(args,{text=true,timeout=timeout,detach=true},function(result)
    vim.schedule(function()
      if request.state~='waiting' or self:is_done() or self.request~=request then return end
      request.state='delivered'
      -- Stop each timer independently; cleanup trouble must not strand a job.
      for _,name in ipairs({'watchdog','escalation'}) do
        local ok,err=pcall(resources.timer,request[name]);if not ok then self:issue(err) end
      end
      self.process=nil;self.request=nil
      if request.reason=='timeout' then result.code=124 end
      self.resume(result)
    end)
  end)
  self.process=request.process
  request.watchdog=assert(vim.uv.new_timer())
  request.watchdog:start(timeout+500,0,function()
    if request.state=='waiting' then request.reason='timeout';resources.signal(request.process,9) end
  end)
  local result=coroutine.yield()
  self:check()
  return result
end
function Job:cancel()
  if not self:cancellable() then return false end
  life.move(self.lifecycle,'cancelling')
  local request=self.request
  if request then
    resources.signal(request.process,15)
    local ok,err=pcall(function()
      request.escalation=assert(vim.uv.new_timer())
      request.escalation:start(500,0,function()
        if request.state=='waiting' then resources.signal(request.process,9) end
      end)
    end)
    if not ok then self:issue('Cancellation timer: '..tostring(err));resources.signal(request.process,9) end
  end
  return true
end
function M.start(work,done,progress)
  assert(not stopping,'Validation is shutting down')
  local job=setmetatable({lifecycle=life.new('validation'),progress=progress,tasks={},issues={}},Job)
  active[job]=true
  local thread=coroutine.create(function()job:check();return work(job)end)
  job.resume=function(...)
    if job:is_done() or job.lifecycle.phase=='cleaning' then return end
    local ok,value=coroutine.resume(thread,...)
    if ok and coroutine.status(thread)~='dead' then return end
    local result
    if job.lifecycle.phase=='cancelling' then result=out.cancelled()
    elseif ok then result=out.succeeded(value,job.publication_result and job.publication_result.publication)
    else result=out.from_error(value) end
    -- Errors in post-publication UI work cannot erase publication facts.
    if job.publication_result and result~=job.publication_result then
      result.publication=job.publication_result.publication
      for _,issue in ipairs(job.publication_result.cleanup) do result.cleanup[#result.cleanup+1]=issue end
    end
    for _,issue in ipairs(job.issues) do result.cleanup[#result.cleanup+1]=issue end
    life.move(job.lifecycle,'cleaning')
    resources.clean(job.tasks,result)
    active[job]=nil
    life.complete(job.lifecycle,result)
    done(result)
  end
  vim.schedule(function()job.resume()end)
  return job
end
function M.shutdown()
  stopping=true
  local jobs={};for job in pairs(active) do jobs[#jobs+1]=job end
  for _,job in ipairs(jobs) do
    if job:cancellable() then job:cancel() end
    if job.lifecycle.phase=='cancelling' then resources.signal(job.process,9) end
  end
  -- Publication may be waiting for its real-path compiler. Finish or recover
  -- before view disposal/editor exit; the process watchdog bounds that wait.
  for _,job in ipairs(jobs) do
    if not job:is_done() then assert(vim.wait(95000,function()return job:is_done()end,10),'Validation did not settle during shutdown') end
  end
end
vim.api.nvim_create_autocmd('VimLeavePre',{callback=M.shutdown})
return M
