-- nvim --headless -u NONE -i NONE -l scripts/test.lua [suite] [options]
-- Each suite gets an empty config/data/state/cache and an independent editor.
local root=vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1,'S').source:sub(2),':p')))
local groups={
  core={'setup','health','spec','yaml','audio-probe','process','fs','lsp','entry-resolution','build-adapter','git','forms','three-pane','transpose','navigation','svg','svg-server','file-lock','source-origin','music-context','symbol-context','inspection','inspection-loading','source-observations','section-drafts','operation-lifecycle','project-document'},
  compiler={'portable','presentation','history','sections','reconciliation','validation','output','transpose-compiler','music-context-compiler','symbol-context-compiler','svg-glyph-cache','svg-selection','compiler'},
  extended={'presentation-infrastructure','section-presentation','creation-presentation','readability','generated-style','mixed-staves','template-compactness','generator-parity'},
}
groups.all={};for _,group in ipairs({'core','compiler','extended'}) do vim.list_extend(groups.all,groups[group]) end
local options={suite='all',nvim=vim.v.progpath,tests={}}
local allowed={playback=true};for _,name in ipairs(groups.all) do allowed[name]=true end
local function usage()
  print('Usage: nvim --headless -u NONE -i NONE -l scripts/test.lua [core|compiler|extended|all] [--nvim PATH] [--test NAME ...] [--nvls-path PATH --soundfont PATH]')
end
local index=1
while index<=#arg do
  local item=arg[index]
  if item=='--help' or item=='-h' then usage();return
  elseif item=='--test' or item=='--nvim' or item=='--nvls-path' or item=='--soundfont' then
    index=index+1;local value=assert(arg[index],'Missing value for '..item)
    if item=='--test' then assert(allowed[value],'Unknown test: '..value);options.tests[#options.tests+1]=value
    else options[item:sub(3):gsub('%-','_')]=value end
  else assert(groups[item],'Unknown argument: '..item);options.suite=item end
  index=index+1
end
assert(vim.fn.executable(options.nvim)==1,'Neovim executable not found: '..options.nvim)
local tests,seen={},{}
for _,name in ipairs(#options.tests>0 and options.tests or groups[options.suite]) do
  if not seen[name] then tests[#tests+1]=name;seen[name]=true end
end
if seen.playback then
  assert(options.nvls_path and options.soundfont,'--test playback requires --nvls-path and --soundfont')
  options.nvls_path=vim.fn.fnamemodify(vim.fn.expand(options.nvls_path),':p'):gsub('/$','')
  options.soundfont=vim.fn.fnamemodify(vim.fn.expand(options.soundfont),':p')
  assert(vim.fn.filereadable(options.nvls_path..'/lua/nvls.lua')==1,'Invalid --nvls-path')
  assert(vim.fn.filereadable(options.soundfont)==1,'Missing --soundfont')
end
local temporary=vim.fn.tempname();vim.fn.mkdir(temporary,'p')
local ok,err=xpcall(function()
  for _,name in ipairs(tests) do
    local isolated=temporary..'/'..name;vim.fn.mkdir(isolated,'p')
    local env=vim.fn.environ()
    for key in pairs(env) do if key:match('^LILYP') then env[key]=nil end end
    for _,key in ipairs({'NVIM_APPNAME','VIMINIT','EXINIT','NVIM_LISTEN_ADDRESS'}) do env[key]=nil end
    for _,kind in ipairs({'CONFIG','DATA','STATE','CACHE'}) do
      local path=isolated..'/'..kind:lower();vim.fn.mkdir(path,'p');env['XDG_'..kind..'_HOME']=path
    end
    env.GIT_CONFIG_NOSYSTEM='1';env.GIT_CONFIG_GLOBAL='/dev/null';env.NVIM_LOG_FILE=isolated..'/nvim.log'
    if name=='playback' then env.LILYP_TEST_NVLS=options.nvls_path;env.LILYP_TEST_SOUNDFONT=options.soundfont end
    io.stdout:write('Running '..name..' with empty Neovim config/data directories\n');io.stdout:flush()
    local result=vim.system({options.nvim,'--headless','-u','NONE','-i','NONE','--cmd',"lua vim.opt.runtimepath = { vim.env.VIMRUNTIME }; vim.opt.packpath = ''",'-l',root..'/tests/'..name..'.lua'},
      {cwd=isolated,env=env,clear_env=true,text=true,timeout=180000}):wait()
    io.stdout:write(result.stdout or '');io.stdout:flush()
    io.stderr:write(result.stderr or '');io.stderr:flush()
    assert(result.code==0 and result.signal==0,'Test failed: '..name..' (code '..tostring(result.code)..', signal '..tostring(result.signal)..')')
  end
end,debug.traceback)
local cleaned=vim.fn.delete(temporary,'rf')==0
assert(ok,err);assert(cleaned,'Could not clean test directory: '..temporary)
print('PASS: '..#tests..' isolated tests')
