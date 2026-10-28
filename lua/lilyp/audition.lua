local M = {}
local active

local function u32(n)
  return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end
local function vlq(n)
  local bytes = {n % 128}
  while n >= 128 do n = math.floor(n / 128); table.insert(bytes, 1, n % 128 + 128) end
  return string.char(unpack(bytes))
end

-- A short C-major arpeggio, with a lower register for bass/tenor staves.
function M.midi(program, low)
  assert(type(program) == 'number' and program >= 0 and program <= 127 and program == math.floor(program))
  local track = '\0\255\81\3\7\161\32' .. '\0\192' .. string.char(program)
  local root = low and 48 or 60
  for index, offset in ipairs({0, 4, 7, 12, 7, 4, 0}) do
    local note = root + offset
    track = track .. '\0\144' .. string.char(note, 82)
      .. vlq(index == 7 and 480 or 240) .. '\128' .. string.char(note, 0)
  end
  track = track .. '\0\255\47\0'
  return 'MThd' .. u32(6) .. '\0\0\0\1\1\224' .. 'MTrk' .. u32(#track) .. track
end

local function remove(job)
  if job.dir then vim.fn.delete(job.dir, 'rf'); job.dir = nil end
end

function M.stop()
  local job = active
  active = nil
  if not job then return end
  if job.process then pcall(function() job.process:kill(15) end) else remove(job) end
  job.on_status('Audition stopped.')
end

function M.play(catalog, entry, low, on_status)
  on_status = on_status or function() end
  M.stop()
  for _, executable in ipairs({'fluidsynth', 'mpv'}) do
    if vim.fn.executable(executable) ~= 1 then on_status('Audition requires ' .. executable .. '.'); return false end
  end
  if type(catalog.font) ~= 'string' or vim.fn.filereadable(catalog.font) ~= 1 then on_status('SoundFont not found: ' .. tostring(catalog.font)); return false end
  local valid, data = pcall(M.midi, entry.program, low)
  if not valid then on_status('Choose a valid GM preset before auditioning.'); return false end
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local job = {dir = dir, on_status = on_status}
  active = job
  local midi, wav = dir .. '/audition.mid', dir .. '/audition.wav'
  local file, err = io.open(midi, 'wb')
  if not file then active = nil; remove(job); on_status(err); return false end
  file:write(data); file:close()
  local gain = (require('lilyp').options().gain or 0.6)
  on_status('Rendering ' .. entry.fluidr3_name .. ' with FluidR3 GM…')
  local function done(message)
    if active == job then active = nil; on_status(message) end
    remove(job)
  end
  local ok, process = pcall(vim.system, {'fluidsynth', '-ni', '-r', '44100', '-g', tostring(gain), '-F', wav, catalog.font, midi},
    {text = true, cwd = dir}, function(result)
      vim.schedule(function()
        job.process = nil
        if active ~= job then remove(job); return end
        if result.code ~= 0 or vim.fn.filereadable(wav) ~= 1 then done('Audition render failed.'); return end
        on_status('Playing ' .. entry.fluidr3_name .. ' · x stops playback.')
        local played, player = pcall(vim.system, {'mpv', '--no-config', '--no-video', '--no-terminal', '--really-quiet', '--volume=100', wav}, {cwd = dir, text = true}, function(play_result)
          vim.schedule(function() job.process = nil; done(play_result.code == 0 and 'Audition complete.' or 'Audition playback stopped or failed.') end)
        end)
        if played then job.process = player else done('Could not start mpv: ' .. tostring(player)) end
      end)
    end)
  if ok then job.process = process else done('Could not start FluidSynth: ' .. tostring(process)); return false end
  return true
end

vim.api.nvim_create_autocmd('VimLeavePre', {
  group = vim.api.nvim_create_augroup('LilyPondAudition', {clear = true}),
  callback = M.stop,
})

return M
