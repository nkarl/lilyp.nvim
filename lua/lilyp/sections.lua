-- New-score section plans only; existing musical source is never reconstructed.
local M={types={'refrain','verse','bridge','intro','outro','custom'},max_sections=32,max_verses=12}
local labels={refrain='Refrain',verse='Verse',bridge='Bridge',intro='Intro',outro='Outro',custom='Section'}
function M.label(kind)return labels[kind] or kind end
local function letters(number)
  local result=''
  repeat
    number=number-1
    result=string.char(97+number%26)..result
    number=math.floor(number/26)
  until number==0
  return result
end
function M.plan(options)
  if options.sections~=nil then
    local plan=vim.deepcopy(options.sections)
    if options._implicit_sections then plan[1].verses=options.lyric_verses or 1 end
    return plan
  end
  return {{id='section_a',type='custom',name='Section',verses=options.lyric_verses or 1}}
end
function M.lyric_rows(options,section)
  local enabled=options.lyrics
  if section.lyrics~=nil then enabled=section.lyrics end
  return enabled and section.verses or 0
end
function M.validate(plan)
  if type(plan)~='table' or #plan<1 or #plan>M.max_sections then return 'Use 1–32 sections.' end
  local ids={}
  for _,section in ipairs(plan) do
    if type(section)~='table' or type(section.id)~='string' or not section.id:match('^section_[a-z]+$') or ids[section.id] then
      return 'Section IDs must be unique generated identifiers.'
    end
    ids[section.id]=true
    if section.key~=nil and not require('lilyp.scaffold').valid_key(section.key) then return 'Choose a valid section key tonic or inherit.' end
    if section.mode~=nil and section.mode~='major' and section.mode~='minor' then return 'Choose major, minor, or inherit for the section.' end
    if section.meter~=nil and not require('lilyp.scaffold').valid_meter(section.meter) then return 'Use a valid section time signature such as 5/4 or 7/8.' end
    if section.lyrics~=nil and type(section.lyrics)~='boolean' then return 'Section lyrics must be true or false, or omitted to inherit.' end
    if not vim.tbl_contains(M.types,section.type) then return 'Choose a supported section type.' end
    if type(section.name)~='string' or not section.name:find('%S') or section.name:find('[%c]') then return 'Each section needs a single-line name.' end
    if section.staff_preset~=nil and not pcall(require('lilyp.scaffold').preset,section.staff_preset) then
      return 'Choose a supported section staff arrangement or inherit the score default.'
    end
    if section.assignments~=nil and type(section.assignments)~='table' then
      return 'Section instrument assignments must be a table.'
    end
    if section.presentation~=nil then
      local ok,err=pcall(require('lilyp.settings').validate_values,section.presentation,'section')
      if not ok then return tostring(err) end
    end
    if type(section.verses)~='number' or section.verses~=math.floor(section.verses) or section.verses<0 or section.verses>M.max_verses then
      return 'Lyric verses must be an integer from 0 to 12.'
    end
  end
end
function M.add(plan)
  assert(#plan<M.max_sections,'Use at most 32 sections.')
  local ids={};for _,section in ipairs(plan) do ids[section.id]=true end
  local number=1
  while ids['section_'..letters(number)] do number=number+1 end
  local section={id='section_'..letters(number),type='verse',name='Verse',verses=1}
  plan[#plan+1]=section
  return #plan
end
function M.prefix(section,index)return index==1 and '' or section.id:gsub('_','') end
function M.filename(section)return 'sections/'..section.id..'.ily' end
function M.verse_name(number)
  return ({'verseOne','verseTwo','verseThree'})[number] or 'verse'..letters(number):upper()
end
function M.staff_preset(options,section)return section.staff_preset or options.preset end

local function default_assignment(options,key)
  if options.assignments and options.assignments[key] then return vim.deepcopy(options.assignments[key]) end
  local preset=require('lilyp.scaffold').preset(key)
  local draft={mode='shared',shared=preset.staves[1].instrument,
    group_label=preset.group_label or (key=='piano' and 'Piano' or 'Choir'),staves={}}
  for _,staff in ipairs(preset.staves) do
    draft.staves[staff.id]={instrument=staff.instrument,label=staff.label or (key=='piano' and '' or staff.name),customized=false}
  end
  return draft
end

-- Pure lookup: reading a draft or rendering a preview never seeds persisted state.
function M.assignment(options,section)
  local scaffold=require('lilyp.scaffold')
  local key=M.staff_preset(options,section)
  if section.assignments and section.assignments[key] then return vim.deepcopy(section.assignments[key]) end
  local draft=default_assignment(options,key)
  if key==options.preset then return draft end
  local source=scaffold.preset(options.preset)
  local sounds,labels={},{}
  for _,staff in ipairs(source.staves) do
    sounds[staff.playback_role]=scaffold.instrument(options,staff.id)
    labels[staff.playback_role]=default_assignment(options,options.preset).staves[staff.id].label
  end
  local shared,uniform=nil,true
  for _,staff in ipairs(scaffold.preset(key).staves) do
    local entry=draft.staves[staff.id]
    local original=draft.mode=='shared' and draft.shared or entry.instrument
    entry.instrument=sounds[staff.playback_role] or original
    if sounds[staff.playback_role] then
      local label=labels[staff.playback_role]
      entry.label=label and label~='' and label or staff.name
    end
    entry.customized=false
    shared=shared or entry.instrument
    if entry.instrument~=shared then uniform=false end
  end
  draft.mode=uniform and 'shared' or 'separate';draft.shared=shared
  return draft
end

function M.options(options,section)
  local result=vim.deepcopy(options)
  for _,id in ipairs({'key','mode','meter'}) do result[id]=section[id] or options[id] end
  result.preset=M.staff_preset(options,section)
  result.assignments={[result.preset]=M.assignment(options,section)}
  return result
end

-- Presets explicitly declare compatible playback roles. Keep the score's
-- existing staff IDs for those roles, regardless of the printed arrangement.
function M.playback_id(options,staff)
  for _,base in ipairs(require('lilyp.scaffold').preset(options.preset).staves) do
    if base.playback_role==staff.playback_role then return base.id end
  end
  return staff.playback_role
end

function M.tracks(options)
  local scaffold=require('lilyp.scaffold')
  local tracks,seen={},{}
  for _,section in ipairs(M.plan(options)) do
    local opts=M.options(options,section)
    for _,staff in ipairs(scaffold.preset(opts.preset).staves) do
      local id=M.playback_id(options,staff)
      if not seen[id] then
        seen[id]=true
        tracks[#tracks+1]={id=id,role=staff.name,playback_role=staff.playback_role,
          instrument=scaffold.instrument(opts,staff.id)}
      end
    end
  end
  return tracks
end

local function rename(text,names,prefix)
  if prefix=='' then return text end
  local lookup={};for _,name in ipairs(names) do lookup[name]=prefix..name end
  local code=require('lilyp.style').code_positions(text)
  return (text:gsub('()([%a]+)()',function(a,name,b)
    if lookup[name] and code[a] and (text:sub(a-1,a-1)=='\\' or text:sub(b):match('^%s*=')) then return lookup[name] end
    return name
  end))
end
function M.render(options,render_score)
  local scaffold=require('lilyp.scaffold')
  local plan=M.plan(options)
  assert(not M.validate(plan),M.validate(plan))
  local layouts,definitions,parts={},{},{}
  for index,section in ipairs(plan) do
    local opts=M.options(options,section)
    local preset=scaffold.preset(opts.preset)
    opts.lyric_verses=M.lyric_rows(options,section)
    opts.lyrics=opts.lyric_verses>0
    if index>1 then opts.pickup='none' end
    local capture={};opts._capture=capture
    render_score(opts)
    local names={'harmonies','chordSettings','staffMusic'}
    for _,staff in ipairs(preset.staves) do
      for _,suffix in ipairs({'Music','Settings','MidiInstrument'}) do names[#names+1]=staff.id..suffix end
    end
    for verse=1,section.verses do names[#names+1]=M.verse_name(verse) end
    if preset.lyrics_per_voice then
      for _,staff in ipairs(preset.staves) do
        for verse=1,section.verses do names[#names+1]=scaffold.lyric_name(preset,staff,verse) end
      end
    end
    local prefix=M.prefix(section,index)
    local section_global='global'
    local globals=''
    if section.key~=nil or section.mode~=nil or section.meter~=nil then
      -- A separate name also for section one keeps the shared default intact.
      section_global=section.id:gsub('_','')..'Global'
      globals=capture.global:gsub('keyAndTime',section.id:gsub('_','')..'KeyAndTime'):gsub('global',section_global)
    end
    local body=rename(capture.settings..capture.music..capture.ensemble,names,prefix)
    if section_global~='global' then body=body:gsub('\\global',function()return '\\'..section_global end) end
    body=globals..body
    local layout=rename(capture.layout,names,prefix)
    if section.presentation and next(section.presentation) then
      local local_style=require('lilyp.scaffold_style').layout(section.presentation,'section',options.chords)
      if #local_style>0 then
        layout=layout:gsub('\\layout { \\scoreLayout }',function()
          return '\\layout {\n  \\scoreLayout\n'..table.concat(local_style,'\n')..'\n}'
        end,1)
      end
    end
    if options.sections and not options._implicit_sections then
      local name='"'..section.name:gsub('\\','\\\\'):gsub('"','\\"')..'"'
      layout=layout:gsub('\\score {',function()return '\\score {\n  \\header { piece = '..name..' }' end,1)
    end
    definitions[#definitions+1]='% curator-section-start '..section.id..'\n'..body..'% curator-section-end '..section.id..'\n'
    layouts[#layouts+1]=layout
    local voices,anchor={},{}
    for _,staff in ipairs(preset.staves) do
      voices[M.playback_id(options,staff)]=prefix..staff.id
      anchor[#anchor+1]='\\'..prefix..staff.id..'Music'
    end
    parts[#parts+1]={voices=voices,anchor='<< '..table.concat(anchor,' ')..' >>',prefix=prefix,global=section_global}
  end
  -- Shared engraving includes lyric helpers even if the first section has none.
  local template=vim.deepcopy(options)
  for _,section in ipairs(plan) do if M.lyric_rows(options,section)>0 then template.lyrics=true;break end end
  template._capture={};render_score(template)
  local midi=''
  if options.midi then
    local lines={'% One continuous timeline; staff changes introduce no pauses.','playbackMusic = <<'}
    for _,track in ipairs(M.tracks(options)) do
      lines[#lines+1]='  \\new Staff \\new Voice = "'..track.id..'" {'
      lines[#lines+1]='    \\global'
      for _,part in ipairs(parts) do
        local voice=part.voices[track.id]
        if voice then
          lines[#lines+1]='    \\set Voice.midiInstrument = \\'..voice..'MidiInstrument'
          lines[#lines+1]='    \\'..voice..'Music'
        else
          -- Skipping unfolded source follows later duration/repeat edits too.
          lines[#lines+1]='    \\'..part.global
          lines[#lines+1]='    \\skip \\unfoldRepeats '..part.anchor
        end
      end
      lines[#lines+1]='  }'
    end
    lines[#lines+1]='>>'
    lines[#lines+1]='\n\\score {\n  \\unfoldRepeats\n  <<\n    \\playbackMusic'
    if options.chords then
      local sequence={}
      local scoped=false
      for _,part in ipairs(parts) do if part.global~='global' then scoped=true end end
      for _,part in ipairs(parts) do sequence[#sequence+1]=(scoped and ('\\'..part.global..' ') or '')..'\\'..part.prefix..'harmonies' end
      lines[#lines+1]='    \\new Staff \\new Voice = "chords" \\with { \\chordSettings } {'
      lines[#lines+1]='      \\global { '..table.concat(sequence,' ')..' }'
      lines[#lines+1]='    }'
    end
    lines[#lines+1]='  >>\n  \\midi { \\scoreMidi }\n}'
    midi=table.concat(lines,'\n')..'\n'
  end
  local assembled=template._capture.header..template._capture.style..table.concat(definitions,'\n')..'\n'..table.concat(layouts,'\n')..(midi~='' and '\n'..midi or '')
  return require('lilyp.generated_format').normalize(assembled)
end
function M.split(source,options)
  local files={}
  for _,section in ipairs(M.plan(options)) do
    local first='% curator-section-start '..section.id..'\n'
    local last='% curator-section-end '..section.id..'\n'
    local a,b=source:find(first,1,true)
    assert(a,'Missing generated section: '..section.id)
    local c,d=source:find(last,b+1,true)
    assert(c,'Incomplete generated section: '..section.id)
    files[M.filename(section)]=source:sub(b+1,c-1)
    source=source:sub(1,a-1)..'\\include "'..M.filename(section)..'"\n'..source:sub(d+1)
  end
  local format=require('lilyp.generated_format')
  for path,music in pairs(files) do files[path]=format.normalize(music) end
  return format.normalize(source,{includes=true}),files
end
return M
