local M={}
M.record={'Enter notation','Correct pitch','Correct rhythm','Correct lyrics','Adjust styling','Review section','Custom'}
M.milestone={'Section checked','Transcription complete','Print ready','Custom'}
local remembered={record='Enter notation',milestone='Section checked'}
function M.last(kind) return remembered[kind] end
function M.remember(kind,preset)
  assert(vim.tbl_contains(M[kind],preset),'Unknown message preset');remembered[kind]=preset
end
function M.compose(preset,section)
  return preset=='Custom' and '' or preset..(section and section~='' and ': '..section or '')
end
return M
