local root=vim.fn.fnamemodify(debug.getinfo(1,'S').source:sub(2),':p:h:h')
vim.opt.rtp:prepend(root)
local app=require('lilyp')
local report=require('lilyp.health')
local saved={health=vim.health,executable=vim.fn.executable,system=vim.system,runtime=vim.api.nvim_get_runtime_file}
local entries={}
local function capture(level)
  return function(message)entries[#entries+1]={level=level,message=message}end
end
vim.health={start=capture('start'),ok=capture('ok'),info=capture('info'),warn=capture('warn'),error=capture('error')}
local function find(level,needle)
  for _,entry in ipairs(entries)do if entry.level==level and entry.message:find(needle,1,true)then return true end end
  return false
end
local function reset(options)
  entries={};app.setup(options or {})
  vim.api.nvim_get_runtime_file=function()return {}end
end
reset()
vim.fn.executable=function()return 0 end
vim.system=function()error('Missing executables must not be launched')end
report.check()
assert(find('error','lilypond not found') and find('error','pdftoppm not found'))
assert(find('warn','fluidsynth not found') and find('info','No instrument inventory configured'))
assert(not find('error','SoundFont') and not find('error','Telescope'))
assert(find('ok','LilyPond built-in family: LilyPond Serif'))
assert(not find('warn','Preferred lyric font is unavailable'))
assert(find('info','SVG glyph cache requested'))
reset({svg_glyph_cache=false});report.check();assert(find('info','SVG glyph cache is disabled'))
local glyph_cache=require('lilyp.svg_glyph_cache')
local hook=glyph_cache.path;glyph_cache.path='/missing/svg-glyph-cache.ily'
reset();report.check();assert(find('warn','SVG glyph cache hook is missing'))
glyph_cache.path=hook
-- Configured executables are probed directly; optional modules are never required.
reset({lilypond='/custom/lilypond',python='/custom/python',defaults={style={lyric_font='DejaVu Serif'}}})
vim.fn.executable=function()return 1 end
vim.system=function(args)
  assert(args[1]=='/custom/lilypond' or args[1]=='fc-match',args[1])
  return {wait=function()
    return {code=0,stdout=args[1]=='/custom/lilypond' and 'GNU LilyPond 2.26.0\n' or args[1]=='fc-match' and 'DejaVu Serif' or '',stderr=''}
  end}
end
report.check()
assert(not find('error','') and find('ok','Preferred lyric font is installed'))
assert(not package.loaded.telescope and not package.loaded.nvls)
local before=app.options();report.check();assert(vim.deep_equal(before,app.options()))
-- Invalid versions, and explicitly missing resources are actionable.
reset({defaults={engraving_mode='embed',engraving_template='/missing/template.ily',instrument_inventory='/missing/inventory.json'}})
vim.system=function(args)
  return {wait=function()return {code=0,stdout=args[1]=='lilypond' and 'GNU LilyPond 2.24.3' or '',stderr=''}end}
end
report.check()
assert(find('error','LilyPond 2.26'))
assert(find('error','engraving template is missing') and find('error','instrument inventory is invalid'))
-- A configured but missing integration is an error; it is not implicitly loaded.
reset()
local saved_options=app.options
app.options=function()local value=saved_options();value.build_integration=true;return value end
report.check();assert(find('error','build_integration is enabled'))
assert(not package.loaded.nvls)
app.options=saved_options
-- A catalog without an installed SoundFont still supports selection.
reset({defaults={instrument_inventory='/configured/inventory.json'}})
local instruments=require('lilyp.instruments')
local saved_load=instruments.load
instruments.load=function()return {font='/missing/bank.sf2'}end
report.check();assert(find('ok','External instrument inventory') and find('warn','No readable audition SoundFont'))
instruments.load=saved_load
-- A subprocess timeout is reported instead of aborting checkhealth.
reset()
vim.system=function()return {wait=function()return {code=124,stdout='',stderr=''}end}end
report.check();assert(find('error','timed out after 3 seconds'))
vim.health=saved.health;vim.fn.executable=saved.executable;vim.system=saved.system;vim.api.nvim_get_runtime_file=saved.runtime
print('PASS: health diagnostics distinguish required tools, optional features, configured paths, missing assets, and process failures without loading integrations')
