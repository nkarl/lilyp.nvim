local M = {}
local defaults = vim.deepcopy(require('lilyp.defaults').defaults)

-- Persistent style defaults, independent of a score's staff preset or music.
local style_defaults = require('lilyp.creation_settings').defaults()

local function style_for(options)
  return require('lilyp.creation_settings').values(options)
end

local presets = {
  { value = "piano", label = "Piano grand staff", group = "PianoStaff", staves = {
    { id = "upper", playback_role = "lead", name = "Upper", clef = "treble", relative = "c'", instrument = "acoustic grand" },
    { id = "lower", playback_role = "lower", name = "Lower", clef = "bass", relative = "c", instrument = "acoustic grand" },
  } },
  { value = "treble", label = "Single treble staff", staves = {
    { id = "melody", playback_role = "lead", name = "Melody", clef = "treble", relative = "c'", instrument = "flute" },
  } },
  { value = "bass", label = "Single bass staff", staves = {
    { id = "melody", playback_role = "lead", name = "Melody", clef = "bass", relative = "c", instrument = "cello" },
  } },
  { value = "satb", label = "SATB choir (four staves)", group = "ChoirStaff", staves = {
    { id = "soprano", playback_role = "lead", name = "Soprano", clef = "treble", relative = "c'", instrument = "choir aahs" },
    { id = "alto", playback_role = "alto", name = "Alto", clef = "treble", relative = "c'", instrument = "choir aahs" },
    { id = "tenor", playback_role = "tenor", name = "Tenor", clef = "treble_8", relative = "c", instrument = "choir aahs" },
    { id = "bass", playback_role = "bass", name = "Bass", clef = "bass", relative = "c", instrument = "choir aahs" },
  } },
  { value='satb_two_staves',label='SATB choir (two staves)',group='PianoStaff',group_label='Choir',lyrics_per_voice=true,
    staves={
      {id='soprano',playback_role='lead',name='Soprano',label='S',clef='treble',relative="c'",instrument='choir aahs'},
      {id='alto',playback_role='alto',name='Alto',label='A',clef='treble',relative="c'",instrument='choir aahs'},
      {id='tenor',playback_role='tenor',name='Tenor',label='T',clef='bass',relative='c',instrument='choir aahs'},
      {id='bass',playback_role='bass',name='Bass',label='B',clef='bass',relative='c',instrument='choir aahs'},
    },printed_staves={{voices={'soprano','alto'}},{voices={'tenor','bass'}}}},
  { value='two_treble',label='Two treble staves',group='PianoStaff',group_label='',lyrics_per_voice=true,staves={
    {id='upper',playback_role='lead',name='Upper',clef='treble',relative="c'",instrument='acoustic grand'},
    {id='lower',playback_role='lower',name='Lower',clef='treble',relative="c'",instrument='acoustic grand'},
  }},
}

local function quote(value)
  return '"' .. tostring(value):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("[\r\n]", " ") .. '"'
end

local function preset_for(value)
  for _, preset in ipairs(presets) do
    if preset.value == value then return preset end
  end
  error("Unknown LilyPond score preset: " .. tostring(value))
end

local function valid_meter(value)
  local numerator, denominator = value:match("^(%d+)/(%d+)$")
  numerator, denominator = tonumber(numerator), tonumber(denominator)
  if not numerator or numerator < 1 or numerator > 32 then return false end
  return denominator == 1 or denominator == 2 or denominator == 4 or denominator == 8
    or denominator == 16 or denominator == 32 or denominator == 64
end

function M.preset(value)
  return vim.deepcopy(preset_for(value))
end

function M.presets()
  return vim.deepcopy(presets)
end

function M.lyric_name(preset,staff,verse)
  local name=require('lilyp.sections').verse_name(verse)
  return preset.lyrics_per_voice and staff.id..name:sub(1,1):upper()..name:sub(2) or name
end

function M.valid_key(value)
  local keys = {c = true, cis = true, des = true, d = true, dis = true, ees = true,
    e = true, f = true, fis = true, ges = true, g = true, gis = true, aes = true, a = true, ais = true, bes = true, b = true}
  return type(value)=='string' and keys[value]==true
end

function M.valid_meter(value)
  return type(value) == "string" and valid_meter(value)
end

function M.pickup_length(value)
  if not value or value == "none" or value == "" then return 0 end
  if type(value) ~= "string" then return nil end
  local base, dots, multiplier = value:match("^(%d+)(%.*)%*(%d+)$")
  if not base then base, dots = value:match("^(%d+)(%.*)$"); multiplier = "1" end
  base, multiplier = tonumber(base), tonumber(multiplier)
  if not base or not vim.tbl_contains({1, 2, 4, 8, 16, 32, 64}, base)
    or #dots > 3 or not multiplier or multiplier < 1 or multiplier > 32 then return nil end
  return (2 - 1 / 2 ^ #dots) * multiplier / base
end

local function assignment(options)
  return options.assignments and options.assignments[options.preset]
end

function M.instrument(options, staff_id)
  local draft = assignment(options)
  if draft then
    if draft.mode == "shared" then return draft.shared end
    return draft.staves[staff_id].instrument
  end
  for _, staff in ipairs(preset_for(options.preset).staves) do
    if staff.id == staff_id then return staff.instrument end
  end
end

-- Generate ordinary LilyPond source so it remains editable without the wizard.
local function render_score(options)
  local preset, style = preset_for(options.preset), style_for(options)
  local pickup = M.pickup_length(options.pickup) ~= 0
  assert(valid_meter(options.meter), "Invalid time signature")
  local lines = { '\\version "2.26.0"', '\\language "nederlands"',
    '#(set-global-staff-size ' .. tostring(style.staff_size) .. ')', '',
    '% Lylip: handwritten music; presentation specification in score.yaml.',
    '% Neovim: F5 compile, F6 score viewer, F3 MIDI playback; :LylipPublishPDF builds a publication PDF.', '' }
  local function add(line) lines[#lines + 1] = line end

  if options.engraving_mode == "embed" then
    assert(options.engraving_text, "Missing engraving template contents")
    add('% Snapshot of engraving.ily: these font choices travel with this score.')
    local snapshot={}
    for _,line in ipairs(vim.split(options.engraving_text,"\n",{plain=true})) do
      if not line:match("^%s*\\version") and not line:match("^%s*%%") then snapshot[#snapshot+1]=line end
    end
    local compact=require('lilyp.generated_format').normalize(table.concat(snapshot,"\n"),{font_properties=true})
    for _,line in ipairs(vim.split(compact,"\n",{plain=true,trimempty=false})) do add(line) end
    add('')
  elseif options.engraving_mode == "include" then
    add('% Local shared typography: this absolute path must exist when compiling.')
    add('\\include ' .. quote(vim.fn.expand(options.engraving_template)))
    add('')
  end

  add('titleFontSize = #'..style.title_size)
  add('subtitleFontSize = #'..style.subtitle_size)
  add("subtitleFontShape = #'" .. style.subtitle_shape)
  add('composerFontSize = #'..style.composer_size)
  add('')
  add('\\header {')
  add('  title = \\markup \\fontsize #titleFontSize ' .. quote(options.title))
  if options.subtitle and options.subtitle ~= '' then
    add("  subtitle = \\markup \\override #(cons 'font-shape subtitleFontShape) \\fontsize #subtitleFontSize " .. quote(options.subtitle))
  end
  add('  composer = \\markup \\fontsize #composerFontSize ' .. quote(options.composer))
  add('  tagline = ##f')
  add('}')
  add('')
  if style.header_gap~=nil then
    add('headerGap = \\markup \\vspace #'..style.header_gap)
    add('\\headerGap')
  end
  add('\\paper { #(set-paper-size ' .. quote(options.paper) .. ') }')
  local paper=require('lilyp.scaffold_style').paper(style)
  if #paper>0 then add('\\paper {');for _,line in ipairs(paper) do add(line) end;add('}') end
  add('')
  local global_start = #lines+1
  add('keyAndTime = {')
  add('  \\key ' .. options.key .. ' \\' .. options.mode)
  if style.numeric_time then add('  \\numericTimeSignature') end
  add('  \\time ' .. options.meter)
  add('}')
  add('')
  add('global = {')
  add('  \\keyAndTime')
  add('  \\tempo 4 = ' .. tostring(options.tempo))
  add('}')
  add('')
  local settings_start = #lines+1
  for _, staff in ipairs(preset.staves) do
    add(staff.id .. 'MidiInstrument = ' .. quote(M.instrument(options, staff.id)))
    add(staff.id .. 'Settings = \\with { midiInstrument = \\' .. staff.id .. 'MidiInstrument }')
  end
  add('')
  local settings_end = #lines
  add('% Use <b \\smallInnerNote g> for a shared stem with a small inner notehead.')
  add('% For one melody-only grace slur: \\slashedGrace { g8^( } <a \\smallInnerNote d>2)')
  add('smallInnerNote = \\tweak font-size #' .. tostring(style.inner_note_size) .. ' \\etc')
  add('')
  add('% Insert between separate layout scores to leave a blank section gap.')
  add('sectionGap = \\markup \\vspace #' .. tostring(style.section_gap))
  add('')
  add('% Shared palette for lyric rows and matching volta brackets/numbers.')
  add('oddVerseColor = ' .. quote(style.odd_color))
  add('evenVerseColor = ' .. quote(style.even_color))
  add('')
  if options.lyrics then
    for _, item in ipairs({{'oddVerseStyle', 'oddVerseColor'}, {'evenVerseStyle', 'evenVerseColor'}}) do
      add(item[1] .. ' = \\with {')
      for _, grob in ipairs({'LyricText', 'StanzaNumber', 'LyricHyphen', 'LyricExtender'}) do
        add('  \\override ' .. grob .. '.color = \\' .. item[2])
      end
      add('}')
      add('')
    end
  end
  local music_start = #lines+1
  add('% Replace the music placeholders; keep all parts aligned.')
  for index, staff in ipairs(preset.staves) do
    add(staff.id .. 'Music = \\relative ' .. staff.relative .. ' {')
    add('  \\global')
    -- Lyric targets need a sounding placeholder; an all-rest voice cannot synchronize lyrics.
    local pitch = options.lyrics and (index == 1 or preset.lyrics_per_voice) and options.key or 'r'
    if pickup then
      add('  \\partial ' .. options.pickup .. ' ' .. pitch .. options.pickup .. ' |')
    end
    add('  ' .. pitch .. '1*' .. options.meter .. ' |')
    add('}')
    add('')
  end
  if options.chords then
    add('chordSettings = \\with { midiInstrument = ' .. quote(options.chord_instrument or 'acoustic grand') .. ' }')
    add('harmonies = \\chordmode {')
    if pickup then add('  \\partial ' .. options.pickup .. ' s' .. options.pickup .. ' |') end
    add('  % Match the melody durations and repeat/alternative structure.')
    add('  ' .. options.key .. '1*' .. options.meter .. (options.mode == 'minor' and ':m' or '') .. ' |')
    add('}')
    add('')
  end
  if options.lyrics then
    add('% Lyrics: -- joins syllables; __ extends a syllable.')
    for index,staff in ipairs(preset.staves) do
      if index==1 or preset.lyrics_per_voice then
        for verse = 1, options.lyric_verses or 1 do
          add(M.lyric_name(preset,staff,verse) .. ' = \\lyricmode {')
          add('  \\set stanza = ' .. quote(tostring(verse) .. '.'))
          add('  \\skip 1')
          add('}')
          add('')
        end
      end
    end
  end
  local music_end = #lines
  add('scoreLayout = \\layout {')
  add(style.indent~=nil and '  indent = '..style.indent..'\\mm' or '  indent = 0')
  add('  \\context {')
  add('    \\Score')
  add('    \\override VoltaBracket.color =')
  add('      #(lambda (grob)')
  add("         (let ((numbers (ly:grob-property grob 'volta-numbers '())))")
  add('           (if (and (pair? numbers) (even? (car numbers)))')
  add('               evenVerseColor')
  add('               oddVerseColor)))')
  add('  }')
  if options.chords then
    add('  \\context {')
    add('    \\ChordNames')
    add('    \\override VerticalAxisGroup.nonstaff-relatedstaff-spacing.padding = #' .. tostring(style.chord_padding))
    add('    \\override ChordName.font-size = #' .. tostring(style.chord_size))
    add('  }')
  end
  add('  \\context {')
  add('    \\Lyrics')
  add('    \\override LyricText.fonts.serif = ' .. quote(style.lyric_font))
  add("    \\override LyricText.font-shape = #'" .. style.lyric_shape)
  add('    \\override LyricText.font-size = #' .. tostring(style.lyric_size))
  add('    \\override LyricSpace.minimum-distance = #' .. tostring(style.word_spacing))
  add('  }')
  for _,line in ipairs(require('lilyp.scaffold_style').layout(style,nil,options.chords)) do add(line) end
  add('}')
  add('')
  if options.midi then
    add('% Instruments are assigned per voice, including voices on the same staff.')
    add('scoreMidi = \\midi {')
    add('  \\context { \\Staff \\remove "Staff_performer" }')
    add('  \\context { \\Voice \\consists "Staff_performer" }')
    add('}')
    add('')
  end
  local ensemble_start = #lines+1
  add('% Reuse the same notes and instrument assignments in both outputs.')
  add('staffMusic = <<')
  if preset.group then
    local draft = assignment(options)
    local name = draft and draft.group_label or preset.group_label or (preset.value == 'piano' and 'Piano' or 'Choir')
    add('  \\new ' .. preset.group .. ' \\with { instrumentName = ' .. quote(name) .. ' } <<')
  end
  local indent = preset.group and '    ' or '  '
  if preset.printed_staves then
    local by_id={};for _,staff in ipairs(preset.staves) do by_id[staff.id]=staff end
    for _,printed in ipairs(preset.printed_staves) do
      local draft=assignment(options)
      local labels={}
      for _,id in ipairs(printed.voices) do labels[#labels+1]=quote(draft and draft.staves[id].label or by_id[id].label or by_id[id].name) end
      local label='\\markup \\center-column { '..table.concat(labels,' ')..' }'
      add(indent..'\\new Staff \\with { instrumentName = '..label..' shortInstrumentName = '..label..' } <<')
      for index,id in ipairs(printed.voices) do
        local staff=by_id[id]
        add(indent..'  \\new Voice = '..quote(id)..' \\with { \\'..id..'Settings } {')
        add(indent..'    \\clef '..quote(staff.clef))
        add(indent..'    '..(index==1 and '\\voiceOne' or '\\voiceTwo')..' \\'..id..'Music')
        add(indent..'  }')
      end
      add(indent..'>>')
      if options.lyrics then
        for _,id in ipairs(printed.voices) do
          for verse=1,options.lyric_verses or 1 do
            local style_name=verse%2==1 and 'oddVerseStyle' or 'evenVerseStyle'
            add(indent..'\\new Lyrics \\with { \\'..style_name..' } \\lyricsto '..quote(id)..' { \\'..M.lyric_name(preset,by_id[id],verse)..' }')
          end
        end
      end
    end
  else
    for index, staff in ipairs(preset.staves) do
      local draft = assignment(options)
      local staff_label = draft and draft.staves[staff.id].label or (preset.value ~= 'piano' and staff.name or '')
      local label=staff_label~='' and (' \\with { instrumentName = '..quote(staff_label)..' }') or ''
      add(indent .. '\\new Staff'..label..' <<')
      add(indent .. '  \\new Voice = ' .. quote(staff.id) .. ' \\with { \\' .. staff.id .. 'Settings } {')
      add(indent .. '    \\clef ' .. quote(staff.clef))
      add(indent .. '    \\' .. staff.id .. 'Music')
      add(indent .. '  }')
      add(indent .. '>>')
      if options.lyrics and (index == 1 or preset.lyrics_per_voice) then
        for verse = 1, options.lyric_verses or 1 do
          local style_name = verse % 2 == 1 and 'oddVerseStyle' or 'evenVerseStyle'
          add(indent .. '\\new Lyrics \\with { \\' .. style_name .. ' } \\lyricsto ' .. quote(staff.id)
            .. ' { \\' .. M.lyric_name(preset,staff,verse) .. ' }')
        end
      end
    end
  end
  if preset.group then add('  >>') end
  add('>>')
  add('')
  local ensemble_end = #lines
  add('\\score {')
  add('  <<')
  if options.chords then add('    \\new ChordNames { \\harmonies }') end
  add('    \\staffMusic')
  add('  >>')
  add('  \\layout { \\scoreLayout }')
  add('}')
  local layout_end = #lines
  if options.midi then
    add('')
    add('\\score {')
    add('  \\unfoldRepeats')
    add('  <<')
    add('    \\staffMusic')
    if options.chords then
      add('    \\new Staff \\new Voice = "chords" \\with { \\chordSettings } {')
      add('      \\global \\harmonies')
      add('    }')
    end
    add('  >>')
    add('  \\midi { \\scoreMidi }')
    add('}')
  end
  if options._capture then
    local function slice(a,b)return table.concat(lines,'\n',a,b)..'\n' end
    options._capture.global=slice(global_start,settings_start-1)
    options._capture.header=slice(1,settings_start-1)..slice(settings_end+1,music_start-1)
    options._capture.settings=slice(settings_start,settings_end)
    options._capture.music=slice(music_start,music_end)
    options._capture.style=slice(music_end+1,ensemble_start-1)
    options._capture.ensemble=slice(ensemble_start,ensemble_end)
    options._capture.layout=slice(ensemble_end+1,layout_end)
    options._capture.midi=layout_end<#lines and slice(layout_end+1,#lines) or ''
  end
  return table.concat(lines, '\n') .. '\n'
end

function M.render(options)
  return require('lilyp.sections').render(options,render_score)
end

-- Settings are shared by the form and Telescope entry point.
function M.defaults()
  local options = vim.deepcopy(defaults)
  options.pickup = options.pickup or "none"
  options.subtitle = options.subtitle or ""
  options.project_mode = options.project_mode or "project"
  options.project_directory = options.project_directory or ""
  options.project_parent = vim.fn.getcwd()
  options.lyrics_language = options.lyrics_language or ""
  options.lyric_verses = options.lyric_verses or 1
  if options.chords == nil then options.chords = false end
  options.style = vim.tbl_extend('force',style_defaults,options.style or {})
  options.assignments = {}
  for _, preset in ipairs(presets) do
    local settings = options.instruments and options.instruments[preset.value] or {}
    local instrument = settings.instrument or preset.staves[1].instrument
    local draft = {mode = #preset.staves == 1 and "shared" or (settings.mode or "shared"), shared = instrument,
      group_label = settings.group_label or preset.group_label or (preset.value == "piano" and "Piano" or "Choir"), staves = {}}
    for _, staff in ipairs(preset.staves) do
      local custom = settings.staves and settings.staves[staff.id] or {}
      local name = staff.label or (preset.value == "piano" and "" or staff.name)
      if #preset.staves == 1 then name = settings.label or (preset.value == "treble" and "Flute" or "Cello") end
      draft.staves[staff.id] = {instrument = custom.instrument or instrument,
        label = custom.label ~= nil and custom.label or name, customized = custom.instrument ~= nil}
    end
    options.assignments[preset.value] = draft
  end
  return options
end

-- Errors carry a field and tab so the form can bring the correction into view.
function M.validate(options)
  local function failure(tab, field, message) return {tab = tab, field = field, message = message} end
  if not vim.tbl_contains({"project", "standalone"}, options.project_mode) then
    return failure(4, "project_mode", "Choose a project directory or standalone buffer.")
  end
  for _, field in ipairs({"project_directory", "lyrics_language"}) do
    if type(options[field]) ~= "string" or options[field]:find('[%z\r\n]') then
      return failure(4, field, "Use a single-line text value.")
    end
  end
  local section_error=require('lilyp.sections').validate(require('lilyp.sections').plan(options))
  if section_error then return failure(5,'section',section_error) end
  local ok, preset = pcall(preset_for, options.preset)
  if not ok then return failure(1, "preset", "Choose a supported staff layout.") end
  if not M.valid_meter(options.meter) then return failure(1, "meter", "Use a valid meter such as 5/4 or 7/8.") end
  local pickup = M.pickup_length(options.pickup)
  local first_meter=require('lilyp.sections').plan(options)[1].meter or options.meter
  local n, d = first_meter:match("^(%d+)/(%d+)$")
  if not pickup or pickup >= tonumber(n) / tonumber(d) then
    return failure(1, "pickup", "Pickup must be shorter than a bar: none, 4, 8, 4., or 8*3.")
  end
  if type(options.tempo) ~= "number" or options.tempo ~= math.floor(options.tempo)
    or options.tempo < 1 or options.tempo > 400 then return failure(1, "tempo", "Tempo must be an integer from 1 to 400.") end
  for _, field in ipairs({"lyrics", "midi", "chords"}) do
    if type(options[field]) ~= "boolean" then return failure(1, field, "Choose On/Off or PDF/MIDI using the form.") end
  end
  if type(options.lyric_verses) ~= "number" or options.lyric_verses ~= math.floor(options.lyric_verses)
    or options.lyric_verses < 1 or options.lyric_verses > 3 then
    return failure(3, "lyric_verses", "Choose one, two, or three lyric verses.")
  end
  if options.style ~= nil and type(options.style) ~= "table" then
    return failure(3, nil, "The defaults.style settings must be a table.")
  end
  local valid_style,style_error=pcall(style_for,options)
  if not valid_style then return failure(3,nil,tostring(style_error)) end
  if options.style and (options.style.lyric_weight~=nil or options.style.lyric_shape~=nil) then
    local ok,err=pcall(require('lilyp.fonts').check,style_error)
    if not ok then return failure(3,'style:lyric_weight',tostring(err)) end
  end
  if options.mode ~= "major" and options.mode ~= "minor" then return failure(1, "mode", "Choose major or minor.") end
  if not M.valid_key(options.key) then return failure(1, "key", "Choose a valid key tonic.") end
  if options.paper ~= "a4" and options.paper ~= "letter" then return failure(3, "paper", "Choose A4 or Letter.") end
  if not vim.tbl_contains({"embed", "include", "default"}, options.engraving_mode) then
    return failure(3, "engraving_mode", "Choose a supported engraving mode.")
  end
  if options.engraving_mode ~= "default" and (type(options.engraving_template) ~= "string"
    or vim.fn.filereadable(vim.fn.expand(options.engraving_template)) ~= 1) then
    return failure(3, "engraving_template", "Engraving template not found: " .. tostring(options.engraving_template))
  end
  local catalog
  if options.instrument_inventory and options.instrument_inventory ~= '' then
    local loaded, value = pcall(require("lilyp.instruments").load, options.instrument_inventory)
    if not loaded then return failure(2, "category", tostring(value)) end
    catalog = value
  end
  local function valid_instrument(name)
    return type(name) == 'string' and name:find('%S') and not name:find('[%c]')
      and (not catalog or catalog.by_name[name] ~= nil)
  end
  if options.chords and not valid_instrument(options.chord_instrument or 'acoustic grand') then
    return failure(1, "chords", "Set defaults.chord_instrument to a supported LilyPond MIDI instrument.")
  end
  local function validate_assignment(opts, section_id)
    local draft = assignment(opts)
    local function invalid(field, message)
      local err = failure(2, field, message); err.section_id = section_id; return err
    end
    if type(draft) ~= 'table' or not vim.tbl_contains({'shared','separate'}, draft.mode)
      or type(draft.staves) ~= 'table' then
      return invalid('assignment_mode', 'Choose shared or separate instrument assignments.')
    end
    for _, staff in ipairs(preset_for(opts.preset).staves) do
      local entry = draft.staves[staff.id]
      if type(entry) ~= 'table' then return invalid('assignment_mode', 'Missing staff assignment: '..staff.name) end
      local instrument = M.instrument(opts, staff.id)
      if not valid_instrument(instrument) then
        return invalid(draft.mode == 'shared' and 'shared_instrument' or 'sound:'..staff.id,
          'Choose a supported GM instrument for '..staff.name..'.')
      end
      if type(entry.label) ~= 'string' or entry.label:find('[%c]') then
        return invalid('label:'..staff.id, 'Use a single-line staff label.')
      end
    end
    if type(draft.group_label) ~= 'string' or draft.group_label:find('[%c]') then
      return invalid('group_label', 'Use a single-line group label.')
    end
  end
  local invalid = validate_assignment(options)
  if invalid then return invalid end
  local sections = require('lilyp.sections')
  for _, section in ipairs(sections.plan(options)) do
    local valid, opts = pcall(sections.options, options, section)
    if not valid then return failure(5, 'section_staff_preset', tostring(opts)) end
    invalid = validate_assignment(opts, section.id)
    if invalid then return invalid end
    if section.presentation then
      local effective=vim.tbl_extend('force',style_error,section.presentation)
      local checked,message=pcall(function()
        require('lilyp.settings').validate_values(effective,'global')
        if section.presentation.lyric_font or section.presentation.lyric_shape or section.presentation.lyric_weight then require('lilyp.fonts').check(effective) end
      end)
      if not checked then return failure(5,'section',tostring(message)) end
    end
  end
end

function M.prepare(options)
  local err = M.validate(options)
  if err then error(err, 0) end
  options = vim.deepcopy(options)
  if options.engraving_mode ~= "default" then
    options.engraving_template = vim.fn.fnamemodify(vim.fn.expand(options.engraving_template), ":p")
    if options.engraving_mode == "embed" then
      options.engraving_text = table.concat(vim.fn.readfile(options.engraving_template), "\n")
    end
  end
  return M.render(options)
end

function M.create_project(source, options)
  return require("lilyp.build").create(source, options)
end

function M.create(source, path)
  local buf = vim.api.nvim_create_buf(true, false)
  if path then
    source = require("lilyp.fs").read(path)
    vim.api.nvim_buf_set_name(buf, path)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(source, "\n", { plain = true, trimempty = true }))
  if path then vim.bo[buf].modified = false end
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "lilypond"
  for line, text in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if text:find("% Replace this full-bar placeholder", 1, true) then
      vim.api.nvim_win_set_cursor(0, { line + 1, 2 })
      break
    end
  end
  vim.notify(path and ("Project ready: " .. vim.fs.dirname(path) .. ". F5 compiles the score.")
    or "Score ready. Use :saveas /path/to/score.ly, then F5 to compile.")
  return buf
end

function M.run()
  return require("lilyp.ui").new()
end

function M.setup(settings)
  defaults = require('lilyp.config').resolve({defaults = settings}).defaults
  vim.api.nvim_create_user_command("LilyNewScore", M.run, {
    desc = "Open the LilyPond score configuration form", force = true,
  })
end


-- Only split our own generated source. Existing handwritten projects import a presentation specification.
function M.split_style(source)
  local positions=require('lilyp.style').code_positions(source)
  local chunks={}
  local function take(pattern,block,group)
    local cursor=1
    while true do
      local a,b=source:find(pattern,cursor);if not a then break end
      if positions[a] and not source:sub(a-1,a-1):match('[%w_]') then
        if block then
          local depth,i=1,b+1
          while depth>0 and i<=#source do
            if positions[i] then
              local c=source:sub(i,i)
              if c=='{' then depth=depth+1 elseif c=='}' then depth=depth-1 end
            end
            i=i+1
          end
          assert(depth==0,'Unbalanced generated style block');b=i-1
          if source:sub(b+1,b+1)=='\n' then b=b+1 end
        end
        local first=a
        while first>1 do
          local previous_end=first-2
          local previous_start=(source:sub(1,previous_end):match('.*()\n') or 0)+1
          local previous=source:sub(previous_start,previous_end)
          if not previous:match('^%%[^{}]') then break end
          first=previous_start
        end
        chunks[#chunks+1]={first=first,last=b,text=source:sub(first,b),group=group}
      end
      cursor=b+1
    end
  end
  take('#%(set%-global%-staff%-size[^\n]+\n',false,'staff')
  take('\\paper%s*{',true,'paper')
  for _,name in ipairs({'titleFontSize','subtitleFontSize','subtitleFontShape','composerFontSize',
    'smallInnerNote','headerGap','sectionGap','oddVerseColor','evenVerseColor'}) do
    local group=name:match('Font') and 'header' or name:match('VerseColor$') and 'palette' or name
    take(name..'%s*=[^\n]+\n',false,group)
  end
  take('oddVerseStyle%s*=%s*\\with%s*{',true,'oddVerseStyle')
  take('evenVerseStyle%s*=%s*\\with%s*{',true,'evenVerseStyle')
  take('scoreLayout%s*=%s*\\layout%s*{',true,'layout')
  table.sort(chunks,function(a,b)return a.first<b.first end)
  for i=2,#chunks do assert(chunks[i].first>chunks[i-1].last,'Overlapping generated style declarations') end
  local styles={'% Presentation settings; initialize or edit their YAML specification with :Lylip.\n'}
  local format=require('lilyp.generated_format')
  local previous_group
  for _,item in ipairs(chunks) do
    local scalar_group=item.group=='header' or item.group=='palette'
    if previous_group and (previous_group~=item.group or not scalar_group) then styles[#styles+1]='\n' end
    styles[#styles+1]=format.normalize(item.text,{font_properties=true})
    previous_group=item.group
  end
  for i=#chunks,1,-1 do local item=chunks[i];source=source:sub(1,item.first-1)..source:sub(item.last+1) end
  source=source:gsub('(\\language "nederlands"\n)','%1\\include "style.ily"\n',1)
  return format.normalize(source,{includes=true}),format.normalize(table.concat(styles),{font_properties=true})
end

return M
