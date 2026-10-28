-- Exercise the real viewer loading/HTTP boundary without a compiler or suite.
local root=vim.fn.fnamemodify(debug.getinfo(1,'S').source:sub(2),':p:h:h')
vim.opt.rtp:prepend(root)
local fs=require('lilyp.fs');local http=dofile(root..'/tests/support/http.lua')
local contract=require('lilyp.inspection')
local folder=vim.fn.tempname();vim.fn.mkdir(folder..'/build','p')
local source=folder..'/main.ly';local raw="music = { c'4 }\n";fs.write(source,raw)
vim.cmd.edit(vim.fn.fnameescape(source))
local context={root=folder,main=source,source=source,buf=vim.api.nvim_get_current_buf(),directory=folder..'/build',manifest=folder..'/build/current.json'}
local entry={source=source,line=1,char=10,key=0,page=0}
local sources={[source]=vim.fn.sha256(raw)}
local origin=require('lilyp.source_origin').capture({entry},sources,folder)[1]
assert(origin.inspection.symbol.kind=='note')
local manifest={revision='typed',pages={'<svg/>'},entries={entry},sources=sources,origins={origin}}
local file=folder..'/build/manifest.json'
local function publish(value)
  fs.write(file,vim.json.encode(value));fs.atomic(context.manifest,vim.json.encode({manifest=file}))
end
require('lilyp').setup({python='/not-used/python'})
publish(manifest)
local session=require('lilyp.svg_navigation').open({context=context,launch=false})
local function inspect()
  session.reload()
  local result=http.json(session.server.url,'inspect',{key=0,revision=manifest.revision})
  assert(contract.valid(result.origin.inspection) and result.read_only)
  assert(result.origin.music==nil and result.origin.symbol==nil)
  return result
end
assert(inspect().origin.inspection.symbol.pitch=='C4')
local function set(origin_value,revision,expected)
  manifest.origins={origin_value};manifest.revision=revision;publish(manifest)
  local before=fs.read(file);local actual=inspect()
  assert(actual.origin.inspection.tag==expected)
  assert(fs.read(file)==before,'Viewer normalization rewrote a saved manifest')
  assert(actual.origin.focus==origin.focus,'Normalization changed the compiled excerpt')
  return actual
end
local old=vim.deepcopy(origin);old.inspection=nil
old.music=vim.tbl_extend('force',origin.inspection.symbol,{status='resolved',read_only=true,event_type='note'});old.music.kind=nil
assert(set(old,'old-note','supported').origin.inspection.symbol.pitch=='C4')
old.music=nil;old.symbol={status='resolved',kind='dynamic',label='Dynamic marking',fields={{label='Marking',value='\\p'},{label='Meaning',value='Piano'}}}
assert(set(old,'old-symbol','supported').origin.inspection.symbol.kind=='dynamic')
old.symbol=nil;set(old,'excerpt-only','unsupported')
local future=vim.deepcopy(origin);future.inspection={tag='supported',symbol={kind='future'}}
set(future,'future','unsupported')
future.inspection={tag='supported',symbol={kind='note',pitch='C4'}};set(future,'partial','unsupported')
manifest.origins={false};manifest.revision='malformed-origin';publish(manifest)
assert(not inspect().origin.available)
-- Existing compiled details stay frozen when saved sources change.
fs.write(source,raw..'% later saved edit\n')
local stale=set(old,'stale-excerpt','unsupported');assert(stale.stale and stale.origin.focus==origin.focus)
-- No-origin legacy builds may only capture source while hashes match.
manifest.origins=nil;manifest.revision='stale-no-origins';publish(manifest)
assert(not inspect().origin.available)
fs.write(source,raw);manifest.revision='fresh-no-origins';publish(manifest)
assert(inspect().origin.inspection.symbol.pitch=='C4')
assert(fs.read(source)==raw)
require('lilyp.svg_navigation').close_all()
print('PASS: real viewer normalizes typed/legacy/excerpt/future/malformed results in memory; frozen stale excerpts and fresh-only legacy capture')
