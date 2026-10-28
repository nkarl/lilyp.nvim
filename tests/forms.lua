local root=vim.fs.dirname(vim.fs.dirname(debug.getinfo(1,'S').source:sub(2)))
vim.opt.rtp:prepend(root)
local fs=require('lilyp.fs')
local templates=require('lilyp.generator')
templates.setup({title='Người Đã Cất Bước',composer='',preset='piano',key='c',mode='major',meter='4/4',
  tempo=100,paper='a4',lyrics=true,midi=true,engraving_mode='default',engraving_template=''})
local function press(state,mode,key)
  for _,map in ipairs(vim.api.nvim_buf_get_keymap(state.buf,mode)) do
    if map.lhs==key then return map.callback() end
  end
  error('Missing mapping: '..key)
end
local function check(state)
  local lines=vim.api.nvim_buf_get_lines(state.buf,0,-1,false)
  assert(#lines==vim.api.nvim_win_get_height(state.win),'Footer overflow')
  local width=vim.api.nvim_win_get_width(state.win)
  for _,line in ipairs(lines) do assert(vim.fn.strdisplaywidth(line)<=width-2,'Clipped line: '..line) end
  assert(lines[state.layout.actions_row]:find('q ',1,true),'Close action must stay visible')
  assert(lines[#lines-1]:find('Enter',1,true),'Edit hint must stay visible')
  assert(not vim.bo[state.buf].modifiable)
  local view=vim.api.nvim_win_call(state.win,vim.fn.winsaveview)
  assert(view.topline==1 and view.leftcol==0,'Unexpected scrolling')
end
local function replace_edit(state,value)
  local edit=assert(state.editing,'Expected inline editor')
  vim.api.nvim_buf_set_lines(state.buf,edit.row-1,edit.row,false,{edit.prefix..value})
end
for _,size in ipairs({{72,27},{120,40}}) do
  vim.o.columns,vim.o.lines=unpack(size)
  local generator=assert(require('lilyp.generator_form').open())
  local geometry=vim.api.nvim_win_get_config(generator.win)
  for _,preset in ipairs(templates.presets()) do
    assert(generator.set('preset',preset.value))
    if #preset.staves>1 then assert(generator.set('assignment_mode','separate')) end
    for tab=1,5 do generator.switch_tab(tab);check(generator) end
  end
  assert(generator.set('title',generator.options.title))
  press(generator,'n','<CR>');replace_edit(generator,'New title');press(generator,'i','<CR>')
  assert(generator.options.title=='New title');check(generator)
  press(generator,'n','<CR>');replace_edit(generator,'Discard');press(generator,'i','<Esc>')
  assert(generator.options.title=='New title');check(generator)
  assert(not generator.set('tempo','invalid'));check(generator)
  assert(vim.api.nvim_win_get_cursor(generator.win)[1]==require('lilyp.form').row(generator,8),'Tempo error focus is wrong')
  assert(generator.set('tempo',120))
  assert(generator.set('title',string.rep('Người ',40)));check(generator)
  -- A field beyond the compact viewport must edit its logical value, not a visible neighbor.
  assert(generator.set('tempo',121))
  press(generator,'n','L');check(generator)
  assert(generator.expanded)
  press(generator,'n','<CR>');replace_edit(generator,'122');press(generator,'i','<CR>')
  assert(generator.options.tempo==122)
  assert(generator.set('title','Learning draft'))
  press(generator,'n','<CR>');replace_edit(generator,'Resized draft')
  vim.o.columns=100;vim.o.lines=32
  vim.api.nvim_exec_autocmds('VimResized',{})
  assert(not generator.editing and generator.options.title=='Resized draft')
  check(generator)
  -- Sidebar focus must never adjust the selected setting accidentally.
  press(generator,'n','<Tab>');assert(generator.focus=='navigation')
  local prior=vim.deepcopy(generator.options)
  press(generator,'n','l');assert(vim.deep_equal(prior,generator.options))
  generator.nav_selection=2;generator.redraw();press(generator,'n','<CR>')
  assert(generator.tab==3 and generator.outline_section=='section_a' and generator.focus=='settings')
  press(generator,'n','?');assert(generator.preview_win)
  generator.close_preview()
  -- Search works without Telescope and preserves the creation draft.
  local saved_select=vim.ui.select
  vim.ui.select=function(items,_,callback)
    for _,item in ipairs(items) do if item.label=='Score · Tempo (quarter BPM)' then callback(item);return end end
    error('Missing search result')
  end
  generator.search();vim.ui.select=saved_select
  assert(generator.tab==1 and generator.selections[1]==8 and generator.options.tempo==122)
  vim.o.columns,vim.o.lines=unpack(size)
  vim.api.nvim_exec_autocmds('VimResized',{})
  generator.close()

  local project=fs.stage(fs.snapshot(root..'/tests/fixtures'))
  local before=fs.snapshot(project)
  local curator=assert(require('lilyp.ui').open(project..'/main.ly'))
  local config=vim.api.nvim_win_get_config(curator.win)
  assert(config.width==geometry.width and config.height==geometry.height)
  assert(config.row==geometry.row and config.col==geometry.col)
  for tab=1,5 do curator.switch_tab(tab);check(curator) end
  curator.switch_tab(1);press(curator,'n','<CR>')
  assert(not curator.editing,'Unspecified settings must not become editable')
  curator.close()
  assert(vim.deep_equal(before,fs.snapshot(project)),'Opening/cancelling changed sources')

  -- Prepare an specified temporary fixture without running specification import's compiler checks.
  local session=require('lilyp.session').open(project..'/main.ly')
  local _,yaml=session:render();session:close();fs.write(project..'/score.yaml',yaml)
  before=fs.snapshot(project)
  curator=assert(require('lilyp.ui').open(project..'/main.ly'))
  press(curator,'n','<CR>');replace_edit(curator,'18');press(curator,'i','<CR>')
  assert(curator.session.draft.staff_size==18);check(curator)
  press(curator,'n','L');check(curator)
  local learning=table.concat(require('lilyp.learning').presentation(curator.session,nil,require('lilyp.fields').by_id.staff_size),'\n')
  assert(learning:find('set-global-staff-size',1,true) and learning:find('style.ily:',1,true))
  local source=curator.source()
  assert(vim.bo[source].filetype=='lilypond' and not vim.bo[source].modifiable)
  assert(curator.session.draft.staff_size==18)
  curator.close_preview()
  local changes=table.concat(curator.changes(),'\n')
  assert(changes:find('@@',1,true) and changes:find('+',1,true) and changes:find('set-global-staff-size 18',1,true))
  curator.close_preview()
  assert(curator.set('top_margin',12))
  curator.selection=1;curator.redraw();press(curator,'n','U')
  assert(curator.session.draft.staff_size==curator.session.values.staff_size and curator.session.draft.top_margin==12)
  assert(curator.set('staff_size',18))
  -- Boolean controls toggle typed booleans, including explicit false values.
  curator.focus='settings';curator.selection=8;curator.redraw();press(curator,'n','<CR>')
  assert(type(curator.session.draft.ragged_last_bottom)=='boolean')
  press(curator,'n','<CR>');assert(curator.session.draft.ragged_last_bottom==false)
  curator.selection=1;curator.redraw()
  press(curator,'n','<CR>')
  local edit=assert(curator.editing)
  vim.api.nvim_win_set_cursor(curator.win,{edit.row,#edit.prefix})
  assert(press(curator,'i','<BS>')=='','Backspace crossed the field prefix')
  press(curator,'i','<C-U>')
  assert(vim.api.nvim_buf_get_lines(curator.buf,edit.row-1,edit.row,false)[1]==edit.prefix)
  replace_edit(curator,'19');press(curator,'i','<Tab>')
  assert(curator.session.draft.staff_size==19 and not curator.editing)
  curator.switch_tab(1);curator.selection=1;curator.redraw()
  assert(curator.set('staff_size',18))

  local setting_row=require('lilyp.form').row(curator,1)
  assert(vim.api.nvim_buf_get_lines(curator.buf,setting_row-1,setting_row,false)[1]:find('• draft',1,true))
  press(curator,'n','<CR>');replace_edit(curator,'20');press(curator,'i','<Esc>')
  assert(curator.session.draft.staff_size==18)
  press(curator,'n','<CR>');replace_edit(curator,'invalid');press(curator,'i','<CR>')
  assert(curator.session.draft.staff_size==18);check(curator)
  vim.o.columns=90
  vim.api.nvim_exec_autocmds('VimResized',{})
  assert(vim.api.nvim_win_get_width(curator.win)==86);check(curator)
  press(curator,'n','r');assert(#curator.session:changes()==0)
  curator.close()
  assert(vim.deep_equal(before,fs.snapshot(project)),'Draft/cancel changed sources')
end
-- An unfinished musical score must not prevent read-only inspection of an
-- otherwise valid project. Ambiguous section bindings stay unavailable.
local unfinished=fs.stage(fs.snapshot(root..'/tests/fixtures'))
fs.write(unfinished..'/main.ly',fs.read(unfinished..'/main.ly')..'\n\\score {\n')
local untouched=fs.snapshot(unfinished)
local inspecting=assert(require('lilyp.ui').open(unfinished))
assert(inspecting.session.inspected.staff_size.tag=='recognized')
assert(inspecting.session.section_styles.refrain.tag=='unavailable')
assert(require('lilyp.source_binding').reason(inspecting.session.section_styles.refrain):find('main.ly',1,true))
assert(#inspecting.session:changes()==0)
assert(vim.deep_equal(untouched,fs.snapshot(unfinished)),'Inspecting incomplete source wrote project files')
fs.write(unfinished..'/main.ly',untouched['main.ly']:gsub('\n\\score {\n$',''))
local completed=fs.snapshot(unfinished)
assert(inspecting.reload() and require('lilyp.source_binding').available(inspecting.session.section_styles.refrain))
inspecting.close()
assert(vim.deep_equal(completed,fs.snapshot(unfinished)),'Reloading repaired source wrote project files')
print('PASS: adaptive workspace, sidebar/search, source learning/diff, scrolling edits, booleans, undo, resizing, all presets/tabs, and read-only drafts')
