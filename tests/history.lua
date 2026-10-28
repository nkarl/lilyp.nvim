local plugin=vim.fs.dirname(vim.fs.dirname(debug.getinfo(1,'S').source:sub(2)))
vim.opt.rtp:prepend(plugin)
local fs,ui,g=require('lilyp.fs'),require('lilyp.ui'),require('lilyp.git')
local function diff(before,after)
  return require('lilyp.review_diff').content({{path='notes.ily',before={text=before},after={text=after}}},'test')
end
assert(next(diff('\n','c4\n').highlights))
assert(next(diff('c4\n','\n').highlights))
assert(next(diff('lời c4\n','lời d8\n').highlights))
local function press(state,key)
  for _,map in ipairs(vim.api.nvim_buf_get_keymap(state.buf,'n')) do if map.lhs==key then return map.callback() end end
  error('Missing key '..key)
end
local function screen(state)
  local lines=vim.api.nvim_buf_get_lines(state.buf,0,-1,false)
  assert(#lines==vim.api.nvim_win_get_height(state.win))
  for _,line in ipairs(lines) do assert(vim.fn.strdisplaywidth(line)<=vim.api.nvim_win_get_width(state.win)-2,'Overflow: '..line) end
  assert(not vim.bo[state.buf].modifiable)
end
local function command(root,args)
  local a={'git','-C',root};vim.list_extend(a,args)
  local r=vim.system(a,{text=true}):wait();assert(r.code==0,r.stderr);return vim.trim(r.stdout)
end
vim.o.columns,vim.o.lines=180,48
local root=fs.stage(fs.snapshot(plugin..'/tests/fixtures'))
local original=fs.snapshot(root)
local state=ui.review(root)
assert(state.mode=='history' and state.layout.three)
assert(state.workspace_view.outline_title=='SOURCE FILES')
assert(state.workspace_view.inspector_title=='RECORDS & MILESTONES')
assert(not state.repo.enabled and not vim.uv.fs_lstat(root..'/.git'))
state.select_source('sections/refrain.ily')
assert(state.messages.record=='Enter notation: refrain')
state.set('preset','Correct pitch');assert(state.messages.record=='Correct pitch: refrain')
assert(require('lilyp.commit_messages').last('record')=='Correct pitch')
state.set('message','Correct pitch: refrain, measure 12')
press(state,'S');assert(state.center_content_view.source)
assert(vim.deep_equal(original,fs.snapshot(root)),'Browsing/presets changed source')
assert(state.enable());command(root,{'config','user.name','Lylip UI test'});command(root,{'config','user.email','ui@example.invalid'})
assert(state.review_changes());assert(state.reviewed and #state.reviewed.changes>0)
assert(not state.repo.head,'Review created a commit')
assert(state.save());local first=state.repo.head
assert(first and #state.entries==1)
local path=root..'/sections/refrain.ily'
local old=fs.read(path)
fs.write(path,old:gsub("c'", "d'",1)..'\n% transcription correction\n')
state.refresh();state.select_source('sections/refrain.ily');press(state,'D')
assert(state.center_content_view.diff)
local diff=table.concat(state.center_content_view.lines,'\n')
assert(diff:find('transcription correction',1,true))
local spans=state.center_content_view.highlights
assert(next(spans),'No intraline notation highlights')
local ns=vim.api.nvim_get_namespaces().LilyPondForm
local diff_text=vim.api.nvim_get_hl_id_by_name('DiffText')
local found=false
for _,mark in ipairs(vim.api.nvim_buf_get_extmarks(state.buf,ns,0,-1,{details=true})) do
  if mark[4].hl_group=='DiffText' or mark[4].hl_group==diff_text then found=true end
end
assert(found,'Intraline highlights were not rendered')
state.focus='center';state.center_cursor=1;press(state,'<CR>')
assert(vim.api.nvim_get_current_win()==state.origin_win and vim.api.nvim_buf_get_name(0)==path)
vim.api.nvim_set_current_win(state.win)
state.set('scope','file');assert(state.review_changes());assert(#state.reviewed.changes==1)
state.set('message','Correct pitch: refrain, measure 12');assert(state.save())
assert(command(root,{'diff','--cached','--name-only'})=='')
state.switch_tab(2);state.set('preset','Print ready');state.set('tag','v1.0')
assert(state.messages.milestone=='Print ready: refrain')
assert(state.review_changes());assert(state.save())
local stable=state.repo.milestone
assert(stable and command(root,{'rev-parse','v1.0^{commit}'})==stable)
assert(command(root,{'symbolic-ref','--short','HEAD'})=='main')
state.switch_tab(1)
state.select_history(state.entries[#state.entries]);assert(state.selected_oid==first)
assert(state.review_restore('file'));assert(#state.restore_review.changes==1)
local select=vim.ui.select
vim.ui.select=function(items,_,callback)callback(items[2])end
state.restore_confirm();assert(fs.read(path)~=old,'Cancel restored files')
vim.ui.select=function(items,_,callback)callback(items[1])end
state.restore_confirm();vim.ui.select=select
assert(fs.read(path)==old and not state.restore_review)
assert(command(root,{'rev-parse','backup'})==stable)
-- Inline message editing and compact layouts use the same form editor as styling.
state.selection=2;state.focus='settings';state.redraw();press(state,'<CR>')
local edit=assert(state.editing)
vim.api.nvim_buf_set_lines(state.buf,edit.row-1,edit.row,false,{edit.prefix..'Custom review message'})
assert(state.finish_edit(false) and state.messages.record=='Custom review message')
for _,size in ipairs({{72,27},{100,32},{120,40},{180,48}}) do
  vim.o.columns,vim.o.lines=unpack(size);vim.api.nvim_exec_autocmds('VimResized',{})
  state.focus='settings';state.redraw();screen(state)
  press(state,'D');screen(state)
  press(state,'I');screen(state);press(state,'I');screen(state)
end
-- Presentation drafts survive a trip through notation review in the same window.
local presentation=ui.open(root)
local window=presentation.win
assert(presentation.apply());assert(presentation.set('staff_size',18))
assert(command(root,{'rev-parse','backup'})==stable and #g.history(root,'record')==2,'Apply created Git history')
state=ui.review(root);assert(state.win==window)
assert(ui.open(root)==presentation and presentation.session.draft.staff_size==18)
state=ui.review(root);state.close();assert(ui.current()==nil)
assert(vim.fn.filereadable(root..'/.lilypond-curator.lock')==0)
assert(vim.fn.isdirectory(root..'/backups')==0)
print('PASS: three-panel source/history/diff review, optional presets, inline messages, explicit records/tagged milestones, restore review/cancel, source navigation, compact layouts, and retained presentation drafts')
