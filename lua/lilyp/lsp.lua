-- Read-only project discovery for the project-context ly-lsp extension.
local M = {}

function M.root_dir(buf, on_dir)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' then return end
  local root = require('lilyp').project_root(name)
  if not root then return on_dir(vim.fs.dirname(name)) end
  -- Native root discovery supports callbacks: warm metadata without blocking
  -- buffer entry, so before_init can use the ordinary shared resolver.
  require('lilyp.project').resolve_async(name,function()
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf)==name then on_dir(root) end
  end)
end

function M.before_init(params, config)
  local root = config.root_dir
  if not root or vim.fn.filereadable(root .. '/score.yaml') ~= 1 then return end
  local ok, result = pcall(function()
    return assert(require('lilyp.project').resolve(root)).main
  end)
  if not ok then
    vim.schedule(function()
      vim.notify('LilyPond project context unavailable: ' .. tostring(result), vim.log.levels.WARN)
    end)
    return
  end
  config.init_options = vim.deepcopy(config.init_options or {})
  config.init_options.projectMain = config.init_options.projectMain or result
  local paths = config.init_options.includePaths or {}
  if not vim.tbl_contains(paths, root) then paths[#paths + 1] = root end
  config.init_options.includePaths = paths
  -- Neovim constructs the initialize payload before invoking this callback.
  params.initializationOptions = config.init_options
end

return M
