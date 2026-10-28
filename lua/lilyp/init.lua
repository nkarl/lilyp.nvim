local M={}
local settings=require('lilyp.config').resolve()
function M.options() return vim.deepcopy(settings) end
function M.project_root(path)
  return require('lilyp.project').root(path)
end
function M.open(path) return require('lilyp.ui').open(path) end
function M.review(path) return require('lilyp.ui').review(path) end
function M.configure(opts) return require('lilyp.ui').configure(opts) end
function M.new() return require('lilyp.ui').new() end
function M.home(opts) return require('lilyp.ui').home(opts) end
function M.generate() return M.new() end
function M.compile(opts) return require('lilyp.compiler').compile(opts) end
function M.view(opts) return require('lilyp.navigation').open(opts) end
function M.forward_search(opts) return require('lilyp.navigation').forward(opts) end
function M.transpose(destination,opts)
  return require('lilyp.transpose').selection(destination,opts)
end
function M.setup(options)
  local resolved=require('lilyp.config').resolve(options)
  require('lilyp.scaffold').setup(resolved.defaults)
  settings=resolved
  local function open_command(args)
    local ok,err=pcall(M.open,args.args~='' and args.args or nil)
    if not ok then vim.notify(tostring(err),vim.log.levels.ERROR) end
  end
  for _,name in ipairs({'Lylip','LilyCurator'}) do
    vim.api.nvim_create_user_command(name,open_command,{nargs='?',complete='file',force=true,
      desc='Open Lylip: create or edit a LilyPond score project'})
  end
  vim.api.nvim_create_user_command('LylipReview',function(args)
    local ok,err=pcall(M.review,args.args~='' and args.args or nil)
    if not ok then vim.notify(tostring(err),vim.log.levels.ERROR) end
  end,{nargs='?',complete='file',force=true,desc='Review notation, workbench records, and stable milestones'})
  vim.api.nvim_create_user_command('LylipForwardSearch',function(args)
    local ok,err=pcall(M.forward_search,{occurrence=args.count>0 and args.count or 1})
    if not ok then vim.notify(tostring(err),vim.log.levels.ERROR) end
  end,{count=1,force=true,desc='Locate the source note in the score'})
  for name,format in pairs({LylipBuild='working',LylipPublishPDF='pdf'}) do
    vim.api.nvim_create_user_command(name,function()
      local ok,err=pcall(M.compile,{format=format~='working' and format or nil})
      if not ok then vim.notify(tostring(err),vim.log.levels.ERROR) end
    end,{force=true,desc=format=='pdf' and 'Build a publication PDF' or 'Build the working score'})
  end
  vim.api.nvim_create_user_command('LylipViewPDF',function()
    local ok,err=pcall(require('lilyp.navigation').open_pdf)
    if not ok then vim.notify(tostring(err),vim.log.levels.ERROR) end
  end,{force=true,desc='Open the compiled PDF'})
  vim.api.nvim_create_user_command('LylipView',function()
    local ok,err=pcall(M.view)
    if not ok then vim.notify(tostring(err),vim.log.levels.ERROR) end
  end,{force=true,desc='Open the working score viewer'})
  if settings.build_integration then require('lilyp.build').setup() end
end
return M
