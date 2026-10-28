-- Compose SVG-only compiler settings inside the unpublished generation.
local M={}
M.path=vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1,'S').source:sub(2))))
  ..'/scripts/lilypond/svg-selection.ily'
function M.arguments(format,directory,cache_enabled)
  if format~='svg' then return {} end
  local includes={'\\include '..vim.json.encode(M.path)}
  local cache=require('lilyp.svg_glyph_cache')
  if cache_enabled and vim.fn.filereadable(cache.path)==1 then
    includes[#includes+1]='\\include '..vim.json.encode(cache.path)
  end
  local path=directory..'/viewer-settings.ily'
  require('lilyp.fs').write(path,table.concat(includes,'\n')..'\n')
  return {'-dinclude-settings='..path}
end
return M
