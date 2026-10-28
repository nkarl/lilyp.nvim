-- Optional callback for compiler diagnostics; no build or diagnostics dependency.
local M = {}
function M.resolve_entry(buf, done)
  if not vim.api.nvim_buf_is_loaded(buf) then return done(nil) end
  local name = vim.api.nvim_buf_get_name(buf)
  require('lilyp.project').resolve_async(name, function(project, err)
    done(project and project.main or nil, err)
  end)
end
return M
