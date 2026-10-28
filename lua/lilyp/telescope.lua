local M={}
function M.extension(name)
  local function home(opts)return require('lilyp').home(opts)end
  local function open(fn,opts)
    local ok,result=pcall(fn,opts)
    if not ok then vim.notify(tostring(result),vim.log.levels.ERROR);return nil,tostring(result) end
    return result
  end
  local function configure(opts)return open(require('lilyp').configure,opts)end
  local function review(opts)return open(require('lilyp.ui').review_picker,opts)end
  local function new_score()return require('lilyp').new()end
  local function transpose(opts)return open(require('lilyp.transpose_picker').open,opts)end
  local aliases={
    lilyp=home,lilypond=home,lilypond_curator=home,
    configure=configure,review=review,
    new_score=new_score,transpose=transpose,
    curate=function()
      local curator=require('lilyp')
      local root=curator.project_root()
      if root then return curator.open(root) end
      return curator.home()
    end,
  }
  -- Telescope enumerates exports with pairs(). Legacy shortcuts remain callable
  -- through __index, without adding duplicate entries to pickers/completion.
  local exports=name=='lilyp' and {new_score=new_score,configure=configure,review=review,transpose=transpose} or {}
  return require('telescope').register_extension({exports=setmetatable(exports,{__index=aliases})})
end
return M
