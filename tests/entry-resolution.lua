local plugin=vim.fs.dirname(vim.fs.dirname(debug.getinfo(1,'S').source:sub(2)))
vim.opt.rtp:prepend(plugin)
local fs=require('lilyp.fs')
local project=require('lilyp.project')
local resolver=require('lilyp.integrations.diagnostics').resolve_entry
local root=vim.fn.tempname();vim.fn.mkdir(root..'/sections','p')
local function spec(main)fs.write(root..'/score.yaml','kind: lilypond-score\nsource:\n  main: '..main..'\n')end
spec('entry.ly')
fs.write(root..'/entry.ly','{ c1 }\n');fs.write(root..'/other.ly','{ d1 }\n')
fs.write(root..'/sections/part.ily','music = { c1 }\n')
local buf=vim.fn.bufadd(root..'/sections/part.ily');vim.fn.bufload(buf)
local before=fs.snapshot(root)
local yaml=require('lilyp.yaml');local parse=yaml.request;local processes=0
yaml.request=function(...)processes=processes+1;return parse(...)end
local system=vim.system
vim.system=function()error('YAML resolution must not spawn a process')end
require('lilyp.spec').call=function()error('Interactive resolver used synchronous YAML parsing')end
local function resolve()
  local finished,entry,err=false
  resolver(buf,function(value,failure)entry,err,finished=value,failure,true end)
  assert(vim.wait(5000,function()return finished end,5),'Resolution timed out')
  return entry,err
end
local completed=0
for _=1,3 do resolver(buf,function(value,err)
  assert(value==root..'/entry.ly' and not err);completed=completed+1
end) end
assert(completed==0,'Cold resolution blocked instead of returning asynchronously')
assert(vim.wait(5000,function()return completed==3 end,5))
assert(processes==1,'Concurrent requests launched duplicate parsers')
for _=1,20 do assert(resolve()==root..'/entry.ly') end
assert(project.resolve(root).main==root..'/entry.ly','Ordinary resolution did not share warmed metadata')
assert(processes==1,'Unchanged YAML ran the parser again')
assert(vim.deep_equal(before,fs.snapshot(root)) and not vim.uv.fs_lstat(root..'/build'),'Source resolution wrote build output')
assert(not package.loaded.nvls and not package.loaded.lilypond_diagnostics,'Resolver loaded optional plugins')
spec('other.ly');assert(resolve()==root..'/other.ly' and processes==2)
-- Path existence/symlinks are rechecked even when metadata is cached.
vim.fn.delete(root..'/other.ly')
local value,err=resolve();assert(not value and err:find('does not exist',1,true) and processes==2)
fs.write(root..'/other.ly','{ d1 }\n')
spec('../escape.ly');value,err=resolve();assert(not value and err:find('escapes',1,true))
fs.write(root..'/score.yaml','source: [broken\n')
value,err=resolve();assert(not value and err)
local bad_processes=processes
value,err=resolve();assert(not value and err and processes==bad_processes,'Invalid unchanged YAML was repeatedly parsed')
-- An edit during an outstanding parse must not return the old main entry.
spec('entry.ly')
local finished=false
resolver(buf,function(entry,failure)assert(entry==root..'/other.ly' and not failure);finished=true end)
spec('other.ly')
assert(vim.wait(5000,function()return finished end,5))
assert(resolve()==root..'/other.ly')
-- Independent consumers share a cold parse. A failing consumer must not strand
-- the other diagnostics/LSP callbacks waiting for that same project metadata.
spec('entry.ly')
local notified,delivered=false,false
local notify=vim.notify
vim.notify=function(message,level)
  if tostring(message):find('injected resolver consumer failure',1,true) then
    assert(level==vim.log.levels.ERROR);notified=true
  else notify(message,level) end
end
project.resolve_async(root,function()error('injected resolver consumer failure')end)
project.resolve_async(root,function(value,failure)
  assert(value.main==root..'/entry.ly' and not failure);delivered=true
end)
assert(vim.wait(5000,function()return delivered and notified end,5),'One failing consumer stranded shared resolution callbacks')
vim.notify=notify
-- Standalone files yield no override, leaving diagnostics' fallback intact.
local standalone=vim.fn.tempname();vim.fn.mkdir(standalone,'p')
local single=vim.fn.bufadd(standalone..'/score.ly');vim.fn.bufload(single)
resolver(single,function(entry,failure)assert(entry==nil and failure==nil)end)
vim.system=system;yaml.request=parse
vim.fn.delete(root,'rf');vim.fn.delete(standalone,'rf')
print('PASS: async source resolution, one cold parser, zero warm parsers, invalidation, stale parses, safe paths, optional dependencies, and no output writes')
