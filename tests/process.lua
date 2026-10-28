local plugin=vim.fs.dirname(vim.fs.dirname(debug.getinfo(1,'S').source:sub(2)))
vim.opt.rtp:prepend(plugin)
local process=require('lilyp.process')
local function run(source,timeout)
  local args={vim.v.progpath,'--headless','-u','NONE','-i','NONE','-l',plugin..'/tests/support/process-child.lua',source}
  local result=vim.system(args,{text=true}):wait(timeout or 3000)
  return result,process.failure(args,result,timeout or 3000)
end
local result,failure=run('success')
assert(result.stdout=='success\n' and failure==nil)
result,failure=run('exit')
assert(failure:find('exited with status 7',1,true),'Silent failure lost its exit status')
result,failure=run('signal')
assert(result.signal~=0 and failure:find('terminated by signal',1,true),'Signalled exit was accepted')
result,failure=run('sleep',50)
assert(result.code==124 and failure:find('timed out after 0.05 seconds',1,true))
result,failure=run('logs')
assert(failure:find('output detail',1,true) and failure:find('error detail',1,true))

-- YAML is in process, so partial subprocess output cannot affect its reads.
local spec=require('lilyp.spec')
local system=vim.system
vim.system=function()error('YAML must not launch a helper')end
assert(spec.read('kind: lilypond-score\n').source.main=='main.ly')
local delivered=false
spec.read_async('kind: lilypond-score\n',function(value,err)assert(value and not err);delivered=true end)
assert(not delivered and vim.wait(1000,function()return delivered end,5))
vim.system=system
-- Even apparently complete artifacts cannot make a signalled compiler valid.
-- Keep this check portable by simulating the compiler response in a staged copy.
local fs=require('lilyp.fs')
local project=fs.stage(fs.snapshot(plugin..'/tests/fixtures'))
local session=require('lilyp.session').open(project)
local _,yaml=session:render();session:close();fs.write(project..'/score.yaml',yaml)
session=require('lilyp.session').open(project);session:set('staff_size',16)
local before=fs.snapshot(project)
local job={check=function()end,run=function(_,args)
  fs.write(args[5]..'.pdf','partial PDF')
  return {code=0,signal=15,stdout='',stderr=''}
end}
local ok,err=pcall(session.preview,session,job)
assert(not ok and tostring(err):find('terminated by signal 15',1,true),'A signalled compiler was accepted')
assert(vim.deep_equal(before,fs.snapshot(project)));session:close()
print('PASS: silent nonzero exits, termination signals, deadlines, preserved logs, and in-process synchronous/asynchronous YAML reads')
