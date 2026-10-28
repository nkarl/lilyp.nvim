-- Real suite, native Lua server, actual compiler; intercept only browser launch.
local root=vim.fn.fnamemodify(debug.getinfo(1,'S').source:sub(2),':p:h:h')
vim.opt.rtp:prepend(root)
vim.opt.rtp:append(vim.fn.stdpath('data')..'/lazy/nvim-lilypond-suite')
local http=dofile(root..'/tests/support/http.lua')
local fs=require('lilyp.fs')
local project=fs.stage(fs.snapshot(root..'/tests/fixtures'))
local source=project..'/sections/refrain.ily'
fs.write(source,fs.read(source):gsub('{ g4','{ %%{ Việt %%} g4'))
local suite=require('nvls');suite.setup({})
local app=require('lilyp')
app.setup({build_integration=true,build_location='project',navigation={enabled=true},score_viewer={browser={'/test/browser'}}})
vim.cmd.edit(vim.fn.fnameescape(source))
vim.bo.filetype='lilypond';vim.cmd('runtime ftplugin/lilypond.lua')
local buf=vim.api.nvim_get_current_buf()
local original=fs.read(source)
local function compile(format)
  local artifact,failed
  app.compile({format=format,on_done=function(result)artifact=result end,on_error=function(err)failed=err end})
  assert(vim.wait(15000,function()return artifact or failed end,10))
  assert(not failed,failed);return artifact
end
local artifact=compile()
assert(artifact.format=='svg' and #artifact.pages==1 and vim.fn.filereadable(project..'/build/main.midi')==1)
assert(vim.fn.filereadable(project..'/build/main.pdf')==0)
local jobstart=vim.fn.jobstart
local launches={}
vim.fn.jobstart=function(args,opts)
  assert(args[1]=='/test/browser','SVG viewing spawned an unexpected helper: '..args[1])
  launches[#launches+1]=args;return 123
end
local session=app.view()
local url=session.server.url
assert(#launches==1 and launches[1][2]=='--app='..url)
local state=http.json(url,'state?revision=')
assert(#state.pages==1)
local line=vim.api.nvim_buf_get_lines(buf,1,2,false)[1]
local column=assert(line:find('g4',1,true))-1
vim.api.nvim_win_set_cursor(0,{2,column})
local selected
app.forward_search({on_done=function()selected=true end})
assert(vim.wait(1000,function()return selected end,10))
state=http.json(url,'state?revision=')
assert(state.selected~=vim.NIL)
assert(state.reveal.key==state.selected and state.reveal.revision==state.revision and state.reveal.sequence==1)
local cursor_before=vim.api.nvim_win_get_cursor(0)
local tick_before=vim.api.nvim_buf_get_changedtick(buf)
local inspected=http.json(url,'inspect',{key=state.selected,revision=state.revision})
assert(inspected.read_only and inspected.origin.kind=='token' and inspected.origin.focus=='g4')
assert(inspected.origin.path=='sections/refrain.ily' and not inspected.stale and not inspected.dirty)
assert(inspected.origin.inspection.tag=='supported' and inspected.origin.inspection.symbol.pitch=='G3' and inspected.origin.inspection.symbol.duration.notation=='4')
assert(vim.deep_equal(cursor_before,vim.api.nvim_win_get_cursor(0)) and tick_before==vim.api.nvim_buf_get_changedtick(buf))
assert(http.request(url,'inspect',{key=999999,revision=state.revision})==400)
assert(http.request(url,'inspect',{key=state.selected,revision='old-build'})==400)
vim.api.nvim_win_set_cursor(0,{1,0})
http.json(url,'click',{key=state.selected,revision=state.revision})
assert(session.selected==state.selected and session.selection.occurrence==1)
assert(vim.deep_equal(http.json(url,'state?revision=').reveal,state.reveal),'A viewer click emitted an F7 reveal event')
assert(http.request(url,'inspector.js')==200,'Inspector module was not served')
assert(http.request(url,'../inspector.js')==404,'Viewer assets permit arbitrary paths')
local revealed_again
app.forward_search({on_done=function()revealed_again=true end})
assert(vim.wait(1000,function()return revealed_again end,10))
local repeated_reveal=http.json(url,'state?revision=').reveal
assert(repeated_reveal.key==state.selected and repeated_reveal.sequence==state.reveal.sequence+1,'Repeated F7 lost its reveal event')
assert(vim.api.nvim_win_get_cursor(0)[1]==2 and vim.api.nvim_win_get_cursor(0)[2]==column)
assert(#launches==1,'Forward navigation launched another app')
vim.api.nvim_buf_set_lines(buf,0,0,false,{'% unsaved'})
assert(not pcall(app.forward_search))
local dirty_inspection=http.json(url,'inspect',{key=state.selected,revision=state.revision})
assert(dirty_inspection.dirty and dirty_inspection.origin.focus=='g4' and vim.bo[buf].modified)
assert(dirty_inspection.origin.inspection.symbol.pitch=='G3','Unsaved edits replaced compiled musical context')
assert(http.request(url,'click',{key=state.selected,revision=state.revision})==400,'Browser reported success for a rejected editor jump')
vim.cmd('silent edit!')
vim.api.nvim_win_set_cursor(0,{2,column})
local invalidated
app.forward_search({on_error=function(message)invalidated=message end})
vim.api.nvim_buf_set_lines(buf,0,0,false,{'% changed during lookup'})
assert(vim.wait(1000,function()return invalidated end,10) and invalidated:find('Source changed',1,true))
vim.cmd('silent edit!')
-- Idle HTTP polls use cached pages, selection, and freshness without disk reads.
vim.wait(150,function()return false end,10)
local read=fs.read
local reads=0
fs.read=function(path)reads=reads+1;return read(path)end
for _=1,8 do http.json(url,'state?revision='..state.revision) end
fs.read=read
assert(reads==0,'Idle viewer polls read files: '..reads)
fs.write(source,original..'% external change\n')
assert(vim.wait(3000,function()return http.json(url,'state?revision=').stale end,20),'Source watcher did not invalidate freshness')
local stale_inspection=http.json(url,'inspect',{key=state.selected,revision=state.revision})
assert(stale_inspection.stale and stale_inspection.origin.focus=='g4')
assert(stale_inspection.origin.inspection.symbol.pitch=='G3','Saved edits replaced compiled musical context')
fs.write(source,original)
assert(vim.wait(3000,function()return not http.json(url,'state?revision=').stale end,20))
-- Legacy manifests can be enriched in memory only when their saved source still
-- matches. Loading stale legacy output must not preview the current source.
local context=require('lilyp.score_context').resolve()
local legacy=vim.deepcopy(session.manifest);legacy.origins=nil;legacy.revision='legacy-fresh'
local legacy_path=project..'/build/legacy.json'
local legacy_raw=vim.json.encode(legacy);fs.write(legacy_path,legacy_raw)
fs.atomic(context.manifest,vim.json.encode({manifest=legacy_path}));session.reload()
local legacy_inspection=http.json(url,'inspect',{key=state.selected,revision='legacy-fresh'})
assert(legacy_inspection.origin.focus=='g4' and fs.read(legacy_path)==legacy_raw)
fs.write(source,original..'% source changed before opening legacy output\n')
legacy.revision='legacy-stale';fs.write(legacy_path,vim.json.encode(legacy))
fs.atomic(context.manifest,vim.json.encode({manifest=legacy_path}));session.reload()
local unavailable=http.json(url,'inspect',{key=state.selected,revision='legacy-stale'})
assert(unavailable.stale and not unavailable.origin.available and unavailable.origin.kind=='unknown')
fs.write(source,original)
compile()
assert(http.json(url,'state?revision=').revision~=state.revision and #launches==1)
local midi=fs.read(project..'/build/main.midi')
compile('pdf');assert(fs.read(project..'/build/main.midi')==midi)
local function apply_and_wait(draft)
  local revision=http.json(url,'state?revision=').revision
  assert(draft:apply());draft:close()
  assert(vim.wait(15000,function()
    return http.json(url,'state?revision=').revision~=revision and not require('lilyp.compiler').running(project..'/main.ly')
  end,20))
  assert(not vim.bo[buf].modified and fs.read(source)==original and #launches==1)
end
apply_and_wait(require('lilyp.session').open(project))
local draft=require('lilyp.session').open(project);draft:set('staff_size',16);apply_and_wait(draft)
assert(vim.fn.maparg('<F8>','n')=='<Cmd>LylipPublishPDF<CR>')
vim.keymap.set('n','<F8>',':echo "existing"<CR>',{buffer=buf})
require('lilyp.integrations.nvls').attach(buf);assert(vim.fn.maparg('<F8>','n')==':echo "existing"<CR>')
vim.fn.jobstart=jobstart
require('lilyp.svg_navigation').close_all()
print('PASS: native Lua suite/viewer integration, UTF-8 round trip, acknowledgements, async invalidation, zero idle file reads, filesystem freshness, PDF publishing, Apply refresh, and unbound keys')
