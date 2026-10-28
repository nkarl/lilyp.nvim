local plugin=vim.fn.fnamemodify(debug.getinfo(1,'S').source:sub(2),':p:h:h')
vim.opt.rtp:prepend(plugin)
for _,name in ipairs({'telescope.nvim','plenary.nvim'}) do vim.opt.rtp:append(vim.fn.stdpath('data')..'/lazy/'..name) end
vim.o.columns,vim.o.lines=160,44
local fs,ui=require('lilyp.fs'),require('lilyp.ui')
local telescope=require('telescope');telescope.setup({});telescope.load_extension('lilyp')
local exports=telescope.extensions.lilyp
local function fixture()return fs.stage(fs.snapshot(plugin..'/tests/fixtures'))end
local root=fixture()
local original=fs.snapshot(root)
local cwd=vim.fn.getcwd()
vim.cmd.cd(vim.fn.fnameescape(root))
vim.cmd.enew()
local input,select=vim.ui.input,vim.ui.select
vim.ui.input=function()error('Unexpected project path prompt')end
vim.ui.select=function()error('Unexpected project selection')end
local config=assert(exports.configure())
assert(config.mode=='project' and config.session.root==root)
local review=assert(exports.review())
assert(review.mode=='history' and review.root==root and review.win==config.win)
assert(exports.configure()==config)
review.close()
-- Nested includes resolve immediately to the same validated project.
vim.cmd.edit(vim.fn.fnameescape(root..'/sections/refrain.ily'))
assert(exports.review().root==root);ui.current().close()
assert(vim.deep_equal(original,fs.snapshot(root)) and not vim.uv.fs_lstat(root..'/build') and not vim.uv.fs_lstat(root..'/.git'))

local notify=vim.notify
local notices={}
vim.notify=function(message,level)assert(level==vim.log.levels.ERROR);notices[#notices+1]=message end
local function invalid(path,reason)
  local windows=#vim.api.nvim_list_wins()
  local buffers=#vim.api.nvim_list_bufs()
  for _,open in ipairs({exports.configure,exports.review}) do
    local result,message=open({cwd=path})
    assert(result==nil and message:find('Not a LilyPond project',1,true),tostring(message))
    assert(message:find(reason,1,true),message)
    assert(ui.current()==nil and #vim.api.nvim_list_wins()==windows and #vim.api.nvim_list_bufs()==buffers,'Invalid shape allocated a blank application')
  end
end
local empty=vim.fn.tempname();vim.fn.mkdir(empty,'p')
fs.write(empty..'/unrelated.txt','unrelated')
vim.cmd.edit(vim.fn.fnameescape(empty..'/unrelated.txt'))
assert(exports.configure().session.root==root,'A valid current directory required an extra project selection')
ui.current().close()
invalid(empty,'No score.yaml')
invalid(empty..'-missing','does not exist')
local malformed=fixture();fs.write(malformed..'/score.yaml','kind: wrong-kind\n')
invalid(malformed,'lilypond-score')
local missing=fixture();assert(vim.uv.fs_unlink(missing..'/main.ly'))
invalid(missing,'Main score does not exist')
missing=fixture();assert(vim.uv.fs_unlink(missing..'/style.ily'))
invalid(missing,'Style include')
missing=fixture();assert(vim.uv.fs_unlink(missing..'/sections/refrain.ily'))
invalid(missing,'Section source')
local malformed_section=fixture()
fs.write(malformed_section..'/score.yaml',fs.read(malformed_section..'/score.yaml'):gsub('id: refrain','name: Refrain'))
invalid(malformed_section,'Missing or duplicate section ID')
local escaping=fixture()
fs.write(escaping..'/score.yaml',fs.read(escaping..'/score.yaml'):gsub('main: main.ly','main: ../outside.ly'))
invalid(escaping,'escapes')
local linked=fixture();assert(vim.uv.fs_unlink(linked..'/style.ily'))
assert(vim.uv.fs_symlink(root..'/style.ily',linked..'/style.ily'))
invalid(linked,'Symlink')
-- CWD selection must not silently fall back to a previous active project.
config=assert(exports.configure({cwd=root}))
local selected=ui.current()
local result,message=exports.review({cwd=empty})
assert(result==nil and message:find('Not a LilyPond project',1,true) and ui.current()==selected)
-- Recheck the shape even when a view for the project is already cached.
assert(vim.uv.fs_rename(root..'/style.ily',root..'/style.saved'))
result,message=exports.configure({cwd=root})
assert(result==nil and message:find('Style include',1,true) and ui.current()==selected)
assert(vim.uv.fs_rename(root..'/style.saved',root..'/style.ily'));config.close()
assert(#notices>=18)
vim.notify=notify
-- Honor custom declared source names; neither build/ nor Git is required.
local custom=fixture();vim.fn.mkdir(custom..'/sources','p')
assert(vim.uv.fs_rename(custom..'/main.ly',custom..'/sources/score.ly'))
assert(vim.uv.fs_rename(custom..'/style.ily',custom..'/sources/look.ily'))
fs.write(custom..'/score.yaml',fs.read(custom..'/score.yaml'):gsub('main: main.ly','main: sources/score.ly'):gsub('style: style.ily','style: sources/look.ily'))
assert(exports.configure({path=custom}).session.main_path=='sources/score.ly');ui.current().close()
assert(exports.review({cwd=custom}).root==custom);ui.current().close()
vim.ui.input,vim.ui.select=input,select
vim.cmd.cd(vim.fn.fnameescape(cwd))
assert(vim.deep_equal(original,fs.snapshot(root)))
print('PASS: immediate configure/review from project CWD, source includes and custom entry paths, read-only shape validation, explicit errors, preserved active views, and no empty screens/pickers')
