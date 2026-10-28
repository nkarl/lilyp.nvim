local root=vim.fs.dirname(vim.fs.dirname(debug.getinfo(1,'S').source:sub(2)))
vim.opt.rtp:prepend(root)
for _,name in ipairs({'telescope.nvim','plenary.nvim'}) do
  vim.opt.rtp:append(vim.fn.stdpath('data')..'/lazy/'..name)
end
vim.o.columns,vim.o.lines=120,40
local plugin=require('lilyp')
plugin.setup({defaults={title='Untitled',composer='',preset='treble',key='c',mode='major',meter='4/4',
  tempo=100,paper='a4',lyrics=true,midi=true,engraving_mode='default',engraving_template=''}})
local scaffold=require('lilyp.scaffold')
-- Rendering/validation is covered with real inventories in generator-parity.lua.
scaffold.validate=function()return nil end
assert(require('lilyp.generator')==scaffold)
assert(require('lilypond_curator')==plugin)
assert(require('lilypond_curator.ui')==require('lilyp.ui'))
for name,kind in vim.fs.dir(root..'/lua/lilypond_curator') do
  if kind=='file' and name:match('%.lua$') and name~='init.lua' then
    local module=name:gsub('%.lua$','')
    assert(require('lilypond_curator.'..module)==require('lilyp.'..module),module)
  end
end
local telescope=require('telescope')
telescope.setup({defaults={sorting_strategy='ascending'}})
vim.cmd('runtime plugin/telescope.lua')
local actions=require('telescope.actions')
local action_state=require('telescope.actions.state')
local ui=require('lilyp.ui')
-- Only canonical workflows are listed; legacy aliases remain callable.
telescope.load_extension('lilyp')
telescope.load_extension('lilypond')
telescope.load_extension('lilypond_curator')
local visible={}
for name,exports in pairs(telescope.extensions) do
  if name=='lilyp' or name=='lilypond' or name=='lilypond_curator' then
    for key,fn in pairs(exports) do if type(fn)=='function' then visible[#visible+1]=name..'.'..key end end
  end
end
table.sort(visible)
assert(vim.deep_equal(visible,{'lilyp.configure','lilyp.new_score','lilyp.review','lilyp.transpose'}),vim.inspect(visible))
assert(type(telescope.extensions.lilyp.lilyp)=='function','Legacy home alias disappeared')
assert(type(telescope.extensions.lilypond.new_score)=='function')
assert(type(telescope.extensions.lilyp.curate)=='function')

local fs=require('lilyp.fs')
local function picker()
  local buf=vim.api.nvim_get_current_buf()
  local value=action_state.get_current_picker(buf)
  assert(vim.wait(3000,function()return value.manager and value.manager:num_results()>0 end,10),'Empty picker')
  return value,buf
end
local function select(label)
  local value,buf=picker()
  for i=1,value.manager:num_results() do
    local entry=value.manager:get_entry(i)
    if entry.display:find(label,1,true) then
      value:set_selection(value:get_row(i))
      actions.select_default(buf)
      vim.wait(100,function()return false end,10)
      return
    end
  end
  error('Missing entry: '..label)
end
local project=fs.stage(fs.snapshot(root..'/tests/fixtures'))
local session=require('lilyp.session').open(project..'/main.ly')
local _,yaml=session:render();session:close();fs.write(project..'/score.yaml',yaml)
local before=fs.snapshot(project)
vim.cmd.edit(vim.fn.fnameescape(project..'/main.ly'))
local origin=vim.api.nvim_get_current_win()
-- Both extension names now open the same actual Telescope home picker.
vim.cmd('Telescope lilyp')
assert(picker().prompt_title=='Lylip')
select('New score')
local creation=assert(ui.current());assert(creation.mode=='new')
assert(creation.set('title','Retained draft'))
creation.search();select('Score · Tempo (quarter BPM)')
assert(ui.current()==creation and creation.tab==1 and creation.selections[1]==8 and creation.options.title=='Retained draft')
vim.cmd('Telescope lilyp new_score')
assert(ui.current()==creation and creation.options.title=='Retained draft','New-score function discarded the creation draft')
vim.cmd('Telescope lilypond new_score')
assert(ui.current()==creation)
vim.cmd('Telescope lilypond_curator new_score')
assert(ui.current()==creation)
local win=creation.win
vim.cmd('Lylip');select('Current project')
local presentation=assert(ui.current())
assert(presentation.mode=='project' and presentation.win==win and presentation.session.root==project)
assert(presentation.set('staff_size',18))
presentation.search();select('Lyrics · Lyric font size')
assert(ui.current()==presentation and presentation.tab==3 and presentation.selection==2 and presentation.session.draft.staff_size==18)
-- Separate public entry points retain the same application and independent drafts.
vim.cmd('Telescope lilyp review')
local review=assert(ui.current())
assert(review.mode=='history' and review.root==project and review.win==win)
assert(not vim.uv.fs_lstat(project..'/.git'),'Opening review initialized Git')
vim.cmd('Telescope lilyp configure')
assert(ui.current()==presentation and presentation.session.draft.staff_size==18,'Configure required an extra picker')
telescope.extensions.lilyp.review({cwd=project})
assert(ui.current()==review,'Review required an extra project selection')
local notify=vim.notify
local error_message
vim.notify=function(message,level)assert(level==vim.log.levels.ERROR);error_message=message end
local invalid,message=telescope.extensions.lilyp.review({path=project..'-missing'})
vim.notify=notify
assert(invalid==nil and message:find('Not a LilyPond project',1,true) and error_message==message)
assert(ui.current()==review,'An invalid project replaced the active view')
telescope.extensions.lilyp.configure({path=project})
assert(ui.current()==presentation)
assert(vim.deep_equal(before,fs.snapshot(project)),'Entry-point routing wrote sources')
presentation.changes()
assert(presentation.center_tab=='Changes' and not presentation.preview_win,'Changes must stay in the workspace panels')
presentation.source()
local source_dialog=assert(presentation.preview_win)
telescope.extensions.lilypond_curator.lilypond_curator()
select('Resume new score')
assert(ui.current()==creation and creation.options.title=='Retained draft')
assert(not vim.api.nvim_win_is_valid(source_dialog),'Switching left a detached source dialog')
plugin.home();select('Resume project')
assert(ui.current()==presentation and presentation.session.draft.staff_size==18)
local ok=pcall(plugin.open,vim.fn.tempname()..'/main.ly')
-- Explicit invalid projects cannot replace the active draft.
assert(not ok and ui.current()==presentation)
plugin.home()
local _,prompt=picker();actions.close(prompt)
assert(ui.current()==presentation and vim.deep_equal(before,fs.snapshot(project)))
-- Discover an existing project from a supplied root using the real async finder.
ui.browse({cwd=project});select('.')
assert(ui.current()==presentation)
-- Creation from a source preview transfers directly into the project view.
plugin.new()
assert(creation.set('title','Created by curator'))
local destination=vim.fn.tempname()
assert(creation.set('project_directory',destination))
local preview=creation.preview();assert(vim.api.nvim_buf_is_valid(preview))
local created=assert(creation.create())
local next_view=assert(ui.current())
assert(next_view.mode=='project' and next_view.win==win and next_view.session.root==destination)
assert(not next_view.session.specified,'Creation must not silently initialize the specification')
assert(vim.api.nvim_buf_get_name(created)==destination..'/main.ly')
assert(vim.api.nvim_win_get_buf(origin)==created)
assert(not vim.api.nvim_buf_is_valid(preview) and not vim.api.nvim_buf_is_valid(creation.buf))
assert(vim.deep_equal(before,fs.snapshot(project)),'Switching/creating wrote the existing project')
local creation_view=require('lilyp.creation')
local original_mount=creation_view.mount
creation_view.mount=function()error('Failed view initialization')end
assert(not pcall(plugin.new))
assert(ui.current()==next_view and vim.api.nvim_buf_is_valid(presentation.buf),'Failed view initialization lost retained drafts')
creation_view.mount=original_mount
-- Older entry points all resume the curator's one creation draft.
local another=plugin.new()
assert(require('lilyp.generator_form').open()==another)
assert(scaffold.run()==another and plugin.generate()==another)
assert(another.win==win)
assert(another.set('project_directory',destination))
assert(another.create()==nil and ui.current()==another and not another.closed,'Collision lost draft')
assert(another.set('project_mode','standalone'))
local standalone=assert(another.create())
assert(ui.current()==nil and vim.api.nvim_buf_get_name(standalone)=='')
assert(not vim.api.nvim_win_is_valid(win))
assert(vim.deep_equal(before,fs.snapshot(project)))
-- Closing the window externally disposes every retained draft.
local final=plugin.open(project..'/main.ly')
local other=plugin.new()
vim.api.nvim_win_close(other.win,true)
assert(ui.current()==nil and final.closed and other.closed)
assert(not vim.api.nvim_buf_is_valid(final.buf) and not vim.api.nvim_buf_is_valid(other.buf))
vim.o.columns,vim.o.lines=72,27
plugin.home()
local small,small_prompt=picker()
assert(small.prompt_title=='Lylip')
actions.close(small_prompt)
-- Direct command users retain a unified home even without Telescope installed.
local saved_picker=package.loaded['telescope.pickers']
local saved_loader=package.preload['telescope.pickers']
local saved_select=vim.ui.select
package.loaded['telescope.pickers']=nil
package.preload['telescope.pickers']=function()error('Telescope unavailable')end
local fallback
vim.ui.select=function(entries,opts,callback)fallback={entries=entries,opts=opts};callback(nil)end
plugin.home()
assert(fallback and fallback.opts.prompt=='Lylip' and ui.current()==nil)
fallback=nil
local saved_input=vim.ui.input
vim.ui.input=function()error('Direct project entry must not prompt for a path')end
plugin.configure({cwd=project})
assert(ui.current().mode=='project' and fallback==nil)
require('lilyp.ui').review_picker({cwd=project})
assert(ui.current().mode=='history' and fallback==nil)
ui.current().close()
vim.ui.input=saved_input
vim.ui.select=saved_select
package.loaded['telescope.pickers']=saved_picker
package.preload['telescope.pickers']=saved_loader
print('PASS: separate Telescope new_score/configure/review entry points, direct project opening/native fallbacks, retained drafts, shared window, legacy aliases, standalone, and read-only routing')
