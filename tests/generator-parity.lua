-- Portable generator regression checks; optional reference settings are explicit.
local plugin = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(plugin)
local templates = require('lilyp.generator')
local settings = vim.env.LILYP_TEMPLATE_DEFAULTS and vim.json.decode(table.concat(vim.fn.readfile(vim.env.LILYP_TEMPLATE_DEFAULTS), '\n')) or {}
settings.engraving_template = settings.engraving_template or plugin .. '/tests/engraving-fixture.ily'
templates.setup(settings)
local output = vim.fn.tempname()
vim.fn.mkdir(output, 'p')
local compiled = 0
local function contains(source, needle) return source:find(needle, 1, true) ~= nil end
local function compile(name, source, midi)
  local path = output .. '/' .. name
  vim.fn.writefile(vim.split(source, '\n', {plain = true}), path .. '.ly')
  local result = vim.system({'lilypond', '-o', path, path .. '.ly'}, {text = true}):wait(30000)
  local log = (result.stdout or '') .. (result.stderr or '')
  assert(result.code == 0 and not log:find('warning:') and not log:find('error:'), name .. '\n' .. log)
  assert(vim.fn.filereadable(path .. '.pdf') == 1, 'Missing PDF for ' .. name)
  assert((vim.fn.filereadable(path .. '.midi') == 1) == midi, 'Wrong MIDI output for ' .. name)
  compiled = compiled + 1
  return path, log
end

for _, preset in ipairs(templates.presets()) do
  for _, mode in ipairs({'embed', 'include', 'default'}) do
    for _, pickup in ipairs({'none', '4'}) do
      local options = templates.defaults()
      options.preset, options.engraving_mode, options.pickup = preset.value, mode, pickup
      options.lyrics, options.lyric_verses, options.chords, options.midi = true, 3, true, true
      options.subtitle = 'Our God Has Come'
      local draft = options.assignments[preset.value]
      if #preset.staves > 1 then
        draft.mode = 'separate'
        draft.staves[preset.staves[1].id].instrument = 'flute'
        draft.staves[preset.staves[2].id].instrument = 'cello'
      end
      local source = templates.prepare(options)
      for _, text in ipairs({'\\numericTimeSignature', '#(set-global-staff-size 15)',
        '\\unfoldRepeats', '\\layout { \\scoreLayout }', '\\midi { \\scoreMidi }',
        '\\new Voice = "chords"', '\\'..templates.lyric_name(preset,preset.staves[1],3), '#00007f', '#55007f',
        'LyricText.fonts.serif', 'fontsize #subtitleFontSize "Our God Has Come"',
        'smallInnerNote = \\tweak font-size #-2 \\etc'}) do
        assert(contains(source, text), 'Missing generated setting: ' .. text)
      end
      compile(preset.value .. '-' .. mode .. '-' .. pickup, source, true)
    end
  end
end

local options = templates.defaults()
options.preset, options.engraving_mode = 'treble', 'default'
options.lyrics, options.chords, options.midi = false, false, false
options.style.numeric_time = false
local source = templates.prepare(options)
assert(not contains(source, '\\midi') and not contains(source, 'harmonies =')
  and not contains(source, '\\new Lyrics') and not contains(source, '\\numericTimeSignature'))
compile('pdf-only', source, false)

options = templates.defaults()
options.preset, options.key, options.mode, options.meter, options.pickup = 'bass', 'fis', 'minor', '7/8', '8.'
options.lyrics, options.chords, options.midi = true, true, true
options.title, options.subtitle = 'A "quoted" title', 'Vietnamese: Người Đã Cất Bước'
options.style.lyric_italic, options.style.subtitle_italic = false, false
compile('minor-custom-meter', templates.prepare(options), true)

-- Verify actual MIDI events: repeats play twice and instruments stay separate.
options = templates.defaults()
options.preset, options.key, options.mode, options.meter, options.pickup = 'piano', 'c', 'major', '4/4', 'none'
options.engraving_mode, options.lyrics, options.chords, options.midi = 'default', true, true, true
local draft = options.assignments.piano
draft.mode, draft.staves.upper.instrument, draft.staves.lower.instrument = 'separate', 'flute', 'cello'
source = templates.prepare(options):gsub('r1%*4/4 |', 'c1*4/4 |')
source = source:gsub('c1%*4/4 |', '\\repeat volta 2 { c1 | }')
local path = compile('repeat-instruments', source, true)
local file = assert(io.open(path .. '.midi', 'rb'))
local midi = file:read('*a'); file:close()
local function u32(pos)
  local a, b, c, d = midi:byte(pos, pos + 3)
  return ((a * 256 + b) * 256 + c) * 256 + d
end
local offset, programs, notes = 15, {}, {}
while offset <= #midi do
  local length = u32(offset + 4)
  local data = midi:sub(offset + 8, offset + 7 + length)
  offset = offset + 8 + length
  local pos, running = 1, nil
  local function vlq()
    local value = 0
    repeat
      local byte = data:byte(pos); pos = pos + 1
      value = value * 128 + byte % 128
      if byte < 128 then return value end
    until false
  end
  while pos <= #data do
    vlq()
    local status = data:byte(pos)
    if status >= 128 then pos = pos + 1 else status = running end
    if status == 255 then
      pos = pos + 1
      local size = vlq(); pos = pos + size
    elseif status == 240 or status == 247 then
      local size = vlq(); pos = pos + size
    else
      running = status
      local kind, channel = math.floor(status / 16), status % 16
      if kind == 12 then programs[channel] = data:byte(pos) end
      if kind == 9 and data:byte(pos + 1) > 0 then notes[channel] = (notes[channel] or 0) + 1 end
      pos = pos + ((kind == 12 or kind == 13) and 1 or 2)
    end
  end
end
local by_program = {}
for channel, count in pairs(notes) do
  local program = assert(programs[channel], 'Missing MIDI instrument')
  by_program[program] = (by_program[program] or 0) + count
end
assert(by_program[73] == 2 and by_program[42] == 2 and by_program[0] == 6,
  'Expected flute/cello to play twice each and piano to play both three-note chords')

-- Exercise the actual bracket color callback on odd/even/odd alternatives.
options = templates.defaults()
options.preset, options.key, options.mode, options.meter, options.pickup = 'treble', 'c', 'major', '4/4', 'none'
options.engraving_mode, options.lyrics, options.chords, options.midi = 'default', true, false, false
source = templates.prepare(options):gsub('c1%*4/4 |', [[
\repeat volta 3 {
  c1 |
  \alternative {
    \volta 1 { d1 | }
    \volta 2 { e1 | }
    \volta 3 { f1 | }
  }
}]])
source = source:gsub('               evenVerseColor',
  '               (begin (ly:message "EVEN-VOLTA ~s" numbers) evenVerseColor)')
source = source:gsub('               oddVerseColor',
  '               (begin (ly:message "ODD-VOLTA ~s" numbers) oddVerseColor)')
local _, log = compile('volta-colors', source, false)
assert(contains(log, 'ODD-VOLTA (1)') and contains(log, 'EVEN-VOLTA (2)') and contains(log, 'ODD-VOLTA (3)'),
  'Volta bracket colors should follow odd/even ending numbers')

for _, invalid in ipairs({
  function(o) o.style.staff_size = -1 end,
  function(o) o.style.odd_verse_color = '#oops' end,
  function(o) o.style.numeric_time = 'yes' end,
  function(o) o.lyric_verses = 4 end,
  function(o) o.chords = 'yes' end,
  function(o) o.chords = true; o.chord_instrument = '\n' end,
}) do
  options = templates.defaults(); invalid(options)
  assert(templates.validate(options), 'Invalid settings should be rejected')
end

-- Exercise the real form's field routing after adding subtitle/chords/verse count.
vim.o.columns, vim.o.lines = 120, 40
local form = assert(require('lilyp.generator_form').open())
assert(form.set('subtitle', 'Test subtitle'))
assert(form.set('preset', 'treble'))
assert(form.set('lyrics', true))
assert(form.set('lyric_verses', 2))
assert(form.set('chords', true))
assert(form.set('engraving_mode', 'default'))
for tab = 1, 3 do
  form.switch_tab(tab)
  assert(vim.api.nvim_buf_line_count(form.buf) == vim.api.nvim_win_get_height(form.win), 'Form footer overflow on tab ' .. tab)
end
local preview = assert(form.preview())
local preview_source = table.concat(vim.api.nvim_buf_get_lines(preview, 0, -1, false), '\n')
assert(contains(preview_source, 'Test subtitle') and contains(preview_source, '\\verseTwo')
  and not contains(preview_source, '\\verseThree'))
form.close()
print('PASS: ' .. compiled .. ' warning-free compilations; MIDI repeats/instruments, settings validation, and form preview passed.')
