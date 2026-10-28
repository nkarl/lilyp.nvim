-- Optional nvim-lilypond-suite adapter. Call after nvls.setup().
local M = { enabled = false }
function M.root(path) return require('lilyp.build').root(path) end

function M.setup()
  local suite = require('nvls')
  M.enabled = true
  if suite._user_project_paths then return end
  suite._user_project_paths = true
  local original = suite.get_file_infos
  M.source_info=original
  suite.get_file_infos = function()
    if vim.bo.filetype ~= 'lilypond' then return original() end
    local path = vim.api.nvim_buf_get_name(0)
    assert(path ~= '', 'Save the LilyPond score before compiling or playing it.')
    local root = M.root(path)
    local file
    if root then
      local opts = suite.get_nvls_options()
      local main = require('lilyp.project').resolve(path).main
      local audio_format = opts.player.options.midi_synth == 'timidity' and 'wav' or opts.player.options.audio_format
      file = {main=main, name='main', folder=root, tmp=suite.get_tmp_folder(),
        audio_format=audio_format, midi_synth=opts.player.options.midi_synth,
        output_fm=opts.lilypond.options.output}
    else
      file = original()
    end
    file.source_folder = root or vim.fs.dirname(file.main)
    file.folder = require('lilyp.output').ensure(file.source_folder,not root and file.main or nil)
    local base = vim.fs.joinpath(file.folder, file.name)
    file.pdf, file.midi, file.audio = base .. '.pdf', base .. '.midi', base .. '.' .. file.audio_format
    return file
  end

  local group = vim.api.nvim_create_augroup('LilyPondProjectBuild', {clear=true})
  vim.api.nvim_create_autocmd('FileType', {group=group, pattern='lilypond', callback=function(event)
    M.attach(event.buf)
  end})
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == 'lilypond' then M.attach(buf) end
  end
end

function M.compile(opts)
  return require('lilyp.compiler').compile(opts)
end

function M.attach(buf)
  require('lilyp.navigation').attach(buf)
  vim.api.nvim_buf_call(buf,function()
    if vim.fn.maparg('<F8>','n')=='' then
      vim.keymap.set('n','<F8>','<cmd>LylipPublishPDF<CR>',{buffer=buf,desc='Build a publication PDF'})
    end
  end)
  -- Buffer-local command takes precedence over upstream's global command/key mapping.
  vim.api.nvim_buf_create_user_command(buf, 'LilyCmp', function()
    local ok, err = pcall(M.compile)
    if not ok then vim.notify(tostring(err), vim.log.levels.ERROR) end
  end, {desc='Compile the score into the configured build location', force=true})
end

return M
