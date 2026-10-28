-- Optional real Telescope integration, using the same isolated dependency layout
-- as entrypoints.lua/workspace.lua. No personal init or mappings are loaded.
local root=vim.fn.fnamemodify(debug.getinfo(1,'S').source:sub(2),':p:h:h')
vim.opt.rtp:prepend(root)
for _,name in ipairs({'telescope.nvim','plenary.nvim'}) do vim.opt.rtp:append(vim.fn.stdpath('data')..'/lazy/'..name) end
vim.o.columns,vim.o.lines=120,40
local telescope=require('telescope');telescope.setup({});telescope.load_extension('lilyp')
local actions=require('telescope.actions')
local state=require('telescope.actions.state')
local notices={}
vim.notify=function(message,level)notices[#notices+1]={message=tostring(message),level=level}end
local buf=vim.api.nvim_create_buf(true,false);vim.api.nvim_set_current_buf(buf)
local original="music = \\relative c' { c4 d e f }"
local saved=vim.fn.tempname()..'.ily';vim.fn.writefile({original},saved)
vim.api.nvim_buf_set_name(buf,saved)
local function text()return table.concat(vim.api.nvim_buf_get_lines(buf,0,-1,false),'\n')end
local function escape()vim.cmd('normal! '..vim.api.nvim_replace_termcodes('<Esc>',true,false,true))end
local function select_passage()
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf,0,-1,false,{original})
  vim.cmd('let &undolevels = &undolevels')
  local a=assert(original:find('d e',1,true))
  vim.api.nvim_win_set_cursor(0,{1,a-1});vim.cmd('normal! v2l')
end
local function open(opts)
  local picker=assert(telescope.extensions.lilyp.transpose(opts))
  assert(vim.wait(3000,function()return picker.manager and picker.manager:num_results()>0 end,10),'Empty pitch picker')
  assert(text()==original,'Opening changed the score')
  return picker
end
local function query(picker,value)
  picker:set_prompt(value)
  assert(vim.wait(3000,function()return state.get_current_line()==value end,10))
  assert(vim.wait(3000,function()
    local entry=state.get_selected_entry()
    return (entry and entry.value==value) or (picker.manager and picker.manager:num_results()==0)
  end,10),'Destination search did not settle')
end
select_passage()
local picker=open({buf=0})
query(picker,"b''")
-- Changing marks while the picker is open must not change the captured passage.
vim.api.nvim_buf_set_mark(buf,'<',1,0,{})
vim.api.nvim_buf_set_mark(buf,'>',1,1,{})
actions.select_default(picker.prompt_bufnr)
assert(vim.api.nvim_get_current_buf()==buf)
assert(text()=="music = \\relative c' { c4 b'' cis f,, }")
assert(table.concat(vim.fn.readfile(saved),'\n')==original,'Picker saved the score')
vim.cmd('undo');assert(text()==original,'Transposition was not one undoable edit')

select_passage();escape() -- command-line invocation uses the previous selection
picker=open();actions.close(picker.prompt_bufnr)
assert(text()==original and vim.api.nvim_get_current_buf()==buf,'Cancellation changed source or lost the source buffer')

select_passage();picker=open();query(picker,"fis'")
vim.api.nvim_buf_set_lines(buf,0,-1,false,{original..' % intervening edit'})
local edited=text()
actions.select_default(picker.prompt_bufnr)
assert(text()==edited and vim.api.nvim_buf_is_valid(picker.prompt_bufnr))
assert(notices[#notices].message:find('Source changed',1,true),'Stale source was accepted')
actions.close(picker.prompt_bufnr)

select_passage();picker=open();query(picker,'not-a-pitch')
assert(vim.wait(3000,function()return picker.manager:num_results()==0 end,10))
actions.select_default(picker.prompt_bufnr)
assert(text()==original and vim.api.nvim_buf_is_valid(picker.prompt_bufnr),'Invalid destination changed source')
assert(notices[#notices].level==vim.log.levels.ERROR)
actions.close(picker.prompt_bufnr)

select_passage();picker=open();query(picker,"cisis'")
actions.select_default(picker.prompt_bufnr)
assert(text()=="music = \\relative c' { c4 d e f }") -- d' and cisis' are the same pitch
assert(vim.api.nvim_get_current_buf()==buf)

-- Parsing failures remain in the picker and leave the entire source untouched.
select_passage()
vim.api.nvim_buf_set_lines(buf,0,-1,false,{(original:gsub('c4','\\unsupported c4'))})
local unsupported=text()
local sa,sb=unsupported:find('d e',1,true)
picker=assert(telescope.extensions.lilyp.transpose({buf=buf,start={0,sa-1},finish={0,sb}}))
query(picker,"e'")
actions.select_default(picker.prompt_bufnr)
assert(text()==unsupported and vim.api.nvim_buf_is_valid(picker.prompt_bufnr))
assert(notices[#notices].message:find('Unsupported',1,true))
actions.close(picker.prompt_bufnr)

-- Navigation after typing chooses the highlighted octave, not the raw query.
select_passage();picker=open();query(picker,'c')
local chosen=false
for index=1,picker.manager:num_results() do
  if picker.manager:get_entry(index).value=="c''" then picker:set_selection(picker:get_row(index));chosen=true;break end
end
assert(chosen,'Missing octave variant')
assert(state.get_selected_entry().value=="c''")
actions.select_default(picker.prompt_bufnr)
assert(text()=="music = \\relative c' { c4 c' d f, }")

select_passage();escape()

-- The ordinary Telescope menu must preserve the original Visual selection.
select_passage()
telescope.setup({pickers={builtin={include_extensions=true}}})
vim.cmd('runtime plugin/telescope.lua')
vim.keymap.set('x','<Space><Space>','<Esc><Cmd>Telescope<CR>')
assert(vim.fn.maparg('<Space><Space>','x')=='<Esc><Cmd>Telescope<CR>')
escape();vim.cmd.Telescope()
local menu
assert(vim.wait(3000,function()
  menu=state.get_current_picker(vim.api.nvim_get_current_buf())
  return menu and menu.manager and menu.manager:num_results()>0
end,10),'Space Space did not open Telescope')
local found=false
for index=1,menu.manager:num_results() do
  if menu.manager:get_entry(index).value.text=='lilyp : transpose' then
    menu:set_selection(menu:get_row(index));found=true;break
  end
end
assert(found,'Transpose is absent from the Space Space Telescope menu')
actions.select_default(menu.prompt_bufnr)
assert(vim.wait(3000,function()
  local current=vim.api.nvim_get_current_buf()
  if current==buf then return false end
  local ok,value=pcall(state.get_current_picker,current)
  if ok and value and value.prompt_title=='New first pitch (absolute LilyPond)' then picker=value;return true end
  return false
end,10),'Telescope menu did not open the destination picker')
query(picker,"e'")
actions.select_default(picker.prompt_bufnr)
assert(text()=="music = \\relative c' { c4 e fis f }")

-- A noncurrent source buffer with explicit coordinates is also supported.
select_passage();escape()
local a,b=original:find('d e',1,true)
vim.cmd.enew()
picker=assert(telescope.extensions.lilyp.transpose({buf=buf,start={0,a-1},finish={0,b}}))
query(picker,"a'")
actions.select_default(picker.prompt_bufnr)
assert(text()=="music = \\relative c' { c4 a' b f }")
assert(not vim.bo[vim.api.nvim_get_current_buf()].modified,'The picker edited the wrong buffer')
print('PASS: real Telescope selection capture, exact destinations, cancellation, one-step undo, stale-source rejection, errors, and explicit source ranges')
