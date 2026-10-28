-- The bundled hook checks the actual child runtime; no version-probe process
-- or persistent cache is needed on the build path.
local M={}
M.path=vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1,'S').source:sub(2))))
  ..'/scripts/lilypond/svg-glyph-cache.ily'
function M.arguments(format,enabled)
  if format~='svg' or not enabled or vim.fn.filereadable(M.path)~=1 then return {} end
  return {'-dinclude-settings='..M.path}
end
return M
