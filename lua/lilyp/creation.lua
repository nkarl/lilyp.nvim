local M = {}
local form = require('lilyp.form')
local tabs = {'Score', 'Instruments', 'Engraving', 'Project', 'Sections'}
local sections = require('lilyp.sections')
local function choice(value, label) return {value = value, label = label} end
local function clean(value) return tostring(value or ''):gsub('[\r\n]', ' ') end
local keys = {}
for _, item in ipairs({{'c','C'},{'cis','C#'},{'des','Db'},{'d','D'},{'dis','D#'},{'ees','Eb'},
  {'e','E'},{'f','F'},{'fis','F#'},{'ges','Gb'},{'g','G'},{'gis','G#'},{'aes','Ab'},
  {'a','A'},{'ais','A#'},{'bes','Bb'},{'b','B'}}) do keys[#keys + 1] = choice(item[1], item[2]) end
local meters = {}
for _, meter in ipairs({'4/4','3/4','6/8','2/4','2/2','9/8','12/8'}) do meters[#meters + 1] = choice(meter,meter) end
local score_fields = {
  {key='title',label='Title',help='Score title. Enter edits the value in place.'},
  {key='subtitle',label='Subtitle',help='Optional subtitle; the saved style prints it in italics.'},
  {key='composer',label='Composer',help='Optional composer credit.'},
  {key='preset',label='Default staff layout',help='Sections inherit this layout unless they choose their own arrangement.'},
  {key='key',label='Default key tonic',choices=keys,help='Choose the tonic; set major/minor mode below.'},
  {key='mode',label='Default key mode',choices={choice('major','Major'),choice('minor','Minor')},help='Changing the key does not transpose existing music.'},
  {key='meter',label='Default time signature',choices=meters,editable=true,help='Cycle common meters or Enter a custom meter, such as 5/4 or 7/8.'},
  {key='tempo',label='Tempo (quarter BPM)',help='Quarter notes/minute, 1–400. h/l changes by one; Enter types a value.'},
  {key='pickup',label='Pickup measure',editable=true,choices={choice('none','None'),choice('4','Quarter note'),choice('8','Eighth note')},
    help='Enter a LilyPond duration: 4, 8, 4., or 8*3. It must be shorter than a bar.'},
  {key='lyrics',label='Lyrics default',choices={choice(false,'Off'),choice(true,'On')},help='Default for sections. Each section can inherit this choice or turn lyrics On/Off independently.'},
  {key='midi',label='Output',choices={choice(true,'Score + MIDI'),choice(false,'Score only')},help='MIDI is needed for F3 playback; all-rest scores are silent.'},
  {key='chords',label='Chords',choices={choice(false,'Off'),choice(true,'Names + MIDI accompaniment')},help='Add editable harmonies: chord names in layout, block chords in MIDI.'},
}
local engraving_fields = {
  {key='paper',label='Paper size',choices={choice('a4','A4'),choice('letter','US Letter')},help='Engraved page size for SVG and PDF.'},
  {key='lyric_verses',label='Lyric verses',choices={choice(1,'1'),choice(2,'2'),choice(3,'3')},help='Default lyric rows for the generic section; the Sections tab overrides counts per section.'},
  {key='engraving_mode',label='Font settings',choices={choice('embed','Embed portable snapshot'),choice('include','Include shared file'),choice('default','LilyPond defaults')},
    help='Embed travels with the score; Include follows the shared file.'},
  {key='engraving_template',label='Template',help='Path to engraving.ily. Ignored when using LilyPond defaults.'},
}
local project_fields = {
  {key='project_mode',label='Create',choices={choice('project','Score project folder'),choice('standalone','Unsaved standalone buffer')},help='Projects contain main.ly, score.yaml, sections/, and build output. Git records and milestones are deliberate actions.'},
  {key='project_directory',label='Project directory',help='New folder only. Empty uses the title under the starting directory; existing folders are never overwritten.'},
  {key='lyrics_language',label='Lyrics language',help='Optional language code, such as vi, recorded in the descriptive score.yaml.'},
}

function M.mount(state)
  local templates = require('lilyp.scaffold')
  local instruments = require('lilyp.instruments')
  local audition = require('lilyp.audition')
  local presets, preset_map = templates.presets(), {}
  for _, preset in ipairs(presets) do preset_map[preset.value] = preset end
  state.tab, state.selections, state.status, state.section_index = 1, {1,1,1,1,1}, '', 1
  state.instrument_section='score'
  state.presentation_section='score'
  state.creation_baseline=vim.deepcopy(state.options)

  local function presentation_section()
    if state.presentation_section=='score' then return end
    for _,section in ipairs(sections.plan(state.options)) do
      if section.id==state.presentation_section then return section end
    end
    state.presentation_section='score'
  end
  local function presentation_value(id)
    local section=presentation_section()
    if section and section.presentation and section.presentation[id]~=nil then return section.presentation[id] end
    return require('lilyp.creation_settings').values(state.options)[id]
  end
  local function appearance_values()
    local values=require('lilyp.creation_settings').values(state.options)
    local section=presentation_section()
    return vim.tbl_extend('force',values,section and section.presentation or {})
  end
  local function validate_appearance_change(before,after,section)
    local fonts=require('lilyp.fonts')
    fonts.validate_change(before,after)
    if not section then
      for _,item in ipairs(sections.plan(state.options)) do
        local overrides=item.presentation or {}
        fonts.validate_change(vim.tbl_extend('force',before,overrides),vim.tbl_extend('force',after,overrides))
      end
    end
  end
  local function stage_appearance(values)
    local settings=require('lilyp.settings')
    local section=presentation_section()
    settings.validate_values(values,section and 'section' or 'global')
    local before=appearance_values()
    local after=vim.tbl_extend('force',before,values)
    settings.validate_values(after,'global')
    validate_appearance_change(before,after,section)
    if section then
      local plan=sections.plan(state.options)
      for _,item in ipairs(plan) do if item.id==section.id then
        item.presentation=vim.tbl_extend('force',item.presentation or {},values)
      end end
      if state.options.sections==nil then state.options._implicit_sections=true end
      state.options.sections=plan
    else for id,value in pairs(values) do require('lilyp.creation_settings').set(state.options,id,value) end end
  end

  local function instrument_section()
    if state.instrument_section=='score' then return end
    for _,section in ipairs(sections.plan(state.options)) do
      if section.id==state.instrument_section then return section end
    end
    state.instrument_section='score'
  end
  local function preset()
    local section=instrument_section()
    return preset_map[section and sections.staff_preset(state.options,section) or state.options.preset]
  end
  local function draft(edit)
    local section=instrument_section()
    if not section then return state.options.assignments[state.options.preset] end
    local value=sections.assignment(state.options,section)
    if not edit then return value end
    local plan=sections.plan(state.options)
    for _,item in ipairs(plan) do
      if item.id==section.id then
        item.assignments=item.assignments or {}
        item.assignments[preset().value]=value
        state.options.sections=plan
        return value
      end
    end
  end
  local function catalog()
    local ok, value = pcall(instruments.load,state.options.instrument_inventory)
    return ok and value or nil, not ok and tostring(value) or nil
  end
  local function fields_for(tab)
    if tab == 1 then
      local fields = vim.deepcopy(score_fields)
      for _, field in ipairs(fields) do
        if field.key == 'preset' then
          field.choices = {}
          for _, p in ipairs(presets) do field.choices[#field.choices + 1] = choice(p.value,p.label) end
        end
      end
      return fields
    end
    if tab == 5 then
      local plan=sections.plan(state.options)
      state.section_index=math.min(state.section_index,#plan)
      local choices={}
      for index,section in ipairs(plan) do choices[#choices+1]=choice(section.id,index..'. '..section.name) end
      local types={};for _,kind in ipairs(sections.types) do types[#types+1]=choice(kind,sections.label(kind)) end
      local layouts={choice('inherit','Inherit score default')}
      for _,p in ipairs(presets) do layouts[#layouts+1]=choice(p.value,p.label) end
      local function inherited(values,default)
        local result={choice('inherit','Inherit score default ('..default..')')}
        vim.list_extend(result,vim.deepcopy(values));return result
      end
      return {
        {key='section',label='Selected section',choices=choices,help='h/l selects a section. + adds; - removes; J/K moves it in printed order.'},
        {key='section_type',label='Type',choices=types,help='Section type describes its role; it does not create musical repeats.'},
        {key='section_name',label='Name',help='Printed section heading. Renaming preserves its ID and source filename.'},
        {key='section_staff_preset',label='Staff arrangement',choices=layouts,help='Choose printed staves for this section. Set its sounds on Instruments; playback stays continuous.'},
        {key='section_key',label='Key tonic',choices=inherited(keys,state.options.key),help='Tonic for this new section; Inherit follows the score default.'},
        {key='section_mode',label='Key mode',choices=inherited({choice('major','Major'),choice('minor','Minor')},state.options.mode),help='Major/minor for this section. Does not transpose handwritten music.'},
        {key='section_meter',label='Time signature',choices=inherited(meters,state.options.meter),editable=true,help='Inherit the score default or enter a meter such as 5/4 or 7/8.'},
        {key='section_lyrics',label='Lyrics',choices={choice('inherit','Inherit score default ('..(state.options.lyrics and 'On' or 'Off')..')'),choice(true,'On'),choice(false,'Off')},
          help='Enable or disable lyrics for this section. Off retains the verse count; Inherit follows the Score default.'},
        {key='section_verses',label='Lyric verses',help='0–12 lyric rows sharing this music. Off retains this count; zero means instrumental. Turning lyrics On restores a positive count.'},
        {key='section_add',label='Add section',action='add',help='Enter adds a verse section; its type, name, and lyric count can be changed.'},
        {key='section_remove',label='Remove section',action='remove',help='Enter removes the selected draft section. Keep at least one section.'},
        {key='section_up',label='Move earlier',action='up',help='Enter moves the selected section earlier in printed and playback order.'},
        {key='section_down',label='Move later',action='down',help='Enter moves the selected section later in printed and playback order.'},
      }
    end
    if tab == 3 then
      local section=presentation_section()
      local result=section and {} or vim.deepcopy(engraving_fields)
      local scopes={choice('score','Score default')}
      for _,item in ipairs(sections.plan(state.options)) do scopes[#scopes+1]=choice(item.id,item.name) end
      result[#result+1]={key='presentation_scope',label='Appearance for',choices=scopes,
        help='Choose score defaults or a section. Section values inherit until explicitly overridden; u removes the selected override.'}
      local appearance_fields=vim.list_extend({},require('lilyp.fields').list)
      for i,f in ipairs(appearance_fields) do
        if f.id=='lyric_size' then table.remove(appearance_fields,i);table.insert(appearance_fields,1,f);break end
      end
      for _,f in ipairs(appearance_fields) do
        local chord_setting=f.id=='chord_size' or f.id=='chord_padding'
        if f.id~='paper' and (state.options.chords or not chord_setting)
          and (not f.advanced or state.advanced) and (not section or vim.tbl_contains(f.scopes,'section')) then
          local field={key='style:'..f.id,id=f.id,label=f.label,kind=f.kind,min=f.min,max=f.max,scope=state.presentation_section,
            advanced=f.advanced,help=require('lilyp.field_ui').tabs[f.tab]..' · '..(f.help or require('lilyp.learning').explanations[f.id] or f.label)}
          if f.choices then
            field.choices={}
            for _,v in ipairs(require('lilyp.fonts').choices(f.id,appearance_values(),f.choices)) do
              field.choices[#field.choices+1]=choice(v,type(v)=='boolean' and (v and 'On' or 'Off') or (f.choice_labels and f.choice_labels[v]) or tostring(v))
            end
          end
          result[#result+1]=field
        end
      end
      return result
    end
    if tab == 4 then return vim.deepcopy(project_fields) end
    local scopes={choice('score','Score default')}
    for _,section in ipairs(sections.plan(state.options)) do scopes[#scopes+1]=choice(section.id,section.name) end
    local fields, data = {{key='instrument_section',label='Instruments for',choices=scopes,
      help='Score default supplies inherited sounds. Each section retains its own changes for each arrangement.'}}, catalog()
    if #preset().staves > 1 then
      fields[#fields + 1] = {key='assignment_mode',label='Assignment',choices={choice('shared','Shared sound'),choice('separate','Separate per part')},
        help='Shared and separate choices are retained while switching modes.'}
      fields[#fields + 1] = {key='group_label',label='Group label',help='Printed label for the grand staff or choir group; independent of MIDI sound.'}
    end
    local categories = {choice('all','All families')}
    if data then vim.list_extend(categories,data.category_options) end
    fields[#fields + 1] = {key='category',label='Category filter',choices=categories,
      help='Filter the sound picker. Browsing categories does not replace an assigned sound.'}
    fields[#fields + 1] = {key='subcategory',label='Type filter',choices=data and instruments.subcategories(data,draft().filter_category) or {choice('all','All types')},
      help='Optional inventory filter; Enter on an instrument selects or edits its name.'}
    if draft().mode == 'shared' or #preset().staves == 1 then
      fields[#fields + 1] = {key='shared_instrument',label=#preset().staves == 1 and 'Instrument' or 'Shared instrument',kind='instrument',staff_id=preset().staves[1].id,
        help='Enter edits a MIDI name; with an inventory, search/cycle sounds and v auditions.'}
    end
    for _, staff in ipairs(preset().staves) do
      if draft().mode == 'separate' and #preset().staves > 1 then
        fields[#fields + 1] = {key='sound:'..staff.id,label=staff.name..' instrument',kind='instrument',staff_id=staff.id,
          help='Enter edits a MIDI name; with an inventory, search/cycle sounds and v auditions.'}
      end
      fields[#fields + 1] = {key='label:'..staff.id,label=staff.name..' label',staff_id=staff.id,
        help='Printed staff label. Instrument changes leave this label and clef unchanged.'}
    end
    return fields
  end
  local function value(field)
    if field.key=='presentation_scope' then return state.presentation_section end
    if field.id then return presentation_value(field.id) end
    if field.key=='section' then return sections.plan(state.options)[state.section_index].id end
    if field.key=='section_type' then return sections.plan(state.options)[state.section_index].type end
    if field.key=='section_name' then return sections.plan(state.options)[state.section_index].name end
    if field.key=='instrument_section' then return state.instrument_section end
    if field.key=='section_staff_preset' then return sections.plan(state.options)[state.section_index].staff_preset or 'inherit' end
    if vim.tbl_contains({'section_key','section_mode','section_meter'},field.key) then return sections.plan(state.options)[state.section_index][field.key:sub(9)] or 'inherit' end
    if field.key=='section_lyrics' then
      local enabled=sections.plan(state.options)[state.section_index].lyrics
      if enabled==nil then return 'inherit' end
      return enabled
    end
    if field.key=='section_verses' then return sections.plan(state.options)[state.section_index].verses end
    if field.action then return 'Enter' end
    if field.key == 'assignment_mode' then return draft().mode end
    if field.key == 'group_label' then return draft().group_label end
    if field.key == 'category' then return draft().filter_category or 'all' end
    if field.key == 'subcategory' then return draft().filter_subcategory or 'all' end
    if field.key == 'shared_instrument' then return draft().shared end
    if field.key:match('^sound:') then return draft().staves[field.staff_id].instrument end
    if field.key:match('^label:') then return draft().staves[field.staff_id].label end
    return state.options[field.key]
  end
  local function sound_label(name)
    local data = catalog()
    local entry = data and data.by_name[name]
    return entry and (entry.fluidr3_name..' (GM '..entry.display_program..')') or clean(name)
  end
  local function field_label(field)
    if field.id and value(field)==nil then return 'LilyPond default' end
    if field.kind == 'instrument' then return sound_label(value(field)) end
    for _, item in ipairs(field.choices or {}) do if item.value == value(field) then return item.label end end
    return clean(value(field))
  end
  local function font_summary()
    local style=require('lilyp.creation_settings').values(state.options)
    local fonts = {serif='LilyPond Serif',sans='LilyPond Sans Serif',typewriter='LilyPond Monospace',music='emmentaler'}
    if state.options.engraving_mode ~= 'default' then
      local ok, lines = pcall(vim.fn.readfile,vim.fn.expand(state.options.engraving_template))
      if not ok then return {'  Template font summary: unavailable (check the template path).'} end
      for _, line in ipairs(lines) do
        if not line:match('^%s*%%') then
          local key, name = line:match('property%-defaults%.fonts%.([a-z]+)%s*=%s*"([^"]+)"')
          if key then fonts[key] = name end
        end
      end
    end
    return {'  Font summary (informational):', '    Serif: '..fonts.serif, '    Sans: '..fonts.sans,
      '    Monospace: '..fonts.typewriter, '    Notation: '..fonts.music,
      '    Lyrics: '..style.lyric_font,
      '    Staff size: '..style.staff_size..' / persistent style: setup defaults'}
  end
  local redraw
  local function focus(tab,key)
    state.tab = tab
    if tab==1 or tab==4 then state.outline_section=nil;state.presentation_section='score';state.instrument_section='score' end
    local fields = fields_for(tab)
    for index, field in ipairs(fields) do if field.key == key then state.selections[tab] = index; break end end
  end
  local function show_error(err)
    if type(err) ~= 'table' then err = {tab=state.tab,message=tostring(err):gsub('^.-:%d+: ','')} end
    if err.section_id then
      state.instrument_section=err.section_id
      for index,section in ipairs(sections.plan(state.options)) do
        if section.id==err.section_id then state.section_index=index end
      end
    end
    focus(err.tab or state.tab,err.field)
    state.error_field, state.status = err.field, err.message
    if vim.api.nvim_win_is_valid(state.win) then vim.api.nvim_set_current_win(state.win) end
    redraw()
  end
  redraw = function()
    if state.closed or not state.is_current() or state.editing or not vim.api.nvim_buf_is_valid(state.buf) then return end
    local fields = fields_for(state.tab)
    state.selections[state.tab] = math.max(1,math.min(#fields,state.selections[state.tab]))
    local selected = fields[state.selections[state.tab]]
    if selected.staff_id then state.sound_target = selected.staff_id end
    local rows, summary = {}, {}
    for _, field in ipairs(fields) do
      local section=field.id and presentation_section()
      local badge
      if section then badge=section.presentation and section.presentation[field.id]~=nil and 'override' or 'inherited' end
      rows[#rows+1] = {label=field.label, value=field_label(field), error=field.key==state.error_field,badge=badge,
        color=field.id and require('lilyp.settings').by_id[field.id].color}
    end
    if state.tab == 3 then summary = font_summary()
    elseif state.tab == 5 then
      local plan=sections.plan(state.options)
      summary={'Printed / playback order (once each):'}
      for index,section in ipairs(plan) do
        summary[#summary+1]=index..'. '..section.name..' · '..preset_map[sections.staff_preset(state.options,section)].label..' · '..sections.lyric_rows(state.options,section)..' lyrics'
      end
    elseif state.tab == 2 then
      local mapping={}
      for _,staff in ipairs(preset().staves) do mapping[#mapping+1]=staff.name..' → '..sections.playback_id(state.options,staff) end
      summary={'Arrangement: '..preset().label,'Playback voices: '..table.concat(mapping,', ')}
    elseif state.tab == 4 then
      summary = {'Destination: '..require('lilyp.build').directory(state.options),
        'score.yaml describes intentions; main.ly remains authoritative.'}
    end
    local detail
    if selected.kind == 'instrument' then
      local data = catalog()
      local entry = data and data.by_name[value(selected)]
      detail = entry and entry.category_label..' / '..entry.subcategory_label..' · '..entry.lilypond_midi_instrument or 'Choose a GM instrument using Enter.'
    else
      local choices = {}
      for _, item in ipairs(selected.choices or {}) do choices[#choices + 1] = item.value == value(selected) and '['..item.label..']' or item.label end
      detail = #choices > 0 and table.concat(choices,' | ') or 'Edit: Enter commits · Esc cancels · Ctrl+U clears the value.'
    end
    state.drawing = true
    local sidebar={{label='Score defaults',active=not state.outline_section,run=function()state.select_outline(nil)end}}
    local root_now,root_before=vim.deepcopy(state.options),vim.deepcopy(state.creation_baseline)
    root_now.sections=nil;root_before.sections=nil;root_now._implicit_sections=nil;root_before._implicit_sections=nil
    sidebar[1].dirty=not vim.deep_equal(root_now,root_before)
    local baseline_sections={}
    for _,section in ipairs(sections.plan(state.creation_baseline)) do baseline_sections[section.id]=section end
    for index,section in ipairs(sections.plan(state.options)) do
      sidebar[#sidebar+1]={label='  '..section.name,active=state.outline_section==section.id,dirty=not vim.deep_equal(section,baseline_sections[section.id]),
        run=function()state.select_outline(section.id)end}
    end
    local scope_label='Score defaults'
    for _,section in ipairs(sections.plan(state.options)) do if section.id==state.outline_section then scope_label=section.name..' ['..section.id..']' end end
    form.render(state, {
      heading='LYLIP · NEW SCORE  /  '..state.options.title,
      context='Creation draft · '..(state.tab==3 and ('Appearance: '..(presentation_section() and presentation_section().name or 'Score default'))
        or (state.options.project_mode=='project' and 'Score project' or 'Standalone source'))..' · no files written',
      scope_label=scope_label,scope_key=state.outline_section or 'score',outline=sidebar,
      sidebar=sidebar,learning=state.expanded and require('lilyp.learning').creation(state.options,selected) or nil,
      tabs=tabs, tab=state.tab, fields=rows, selection=state.selections[state.tab], summary=summary,
      help=selected.help, detail=detail, status=state.status, error=state.error_field~=nil,
      actions='g Create   p Source   v Sound   H Home   q Close',
      navigation='1–5 / [ ] Categories · Tab Panes · j/k Fields · h/l Adjust · Enter Edit or select',
    })
    state.drawing = false
  end

  function state.section_action(action)
    if state.finish_edit and not state.finish_edit(false) then return false end
    local plan=sections.plan(state.options)
    local index=state.section_index
    if action=='add' then
      if #plan>=sections.max_sections then state.status='Use at most 32 sections.';redraw();return false end
      state.section_index=sections.add(plan)
    elseif action=='remove' then
      if #plan==1 then state.status='Keep at least one section.';redraw();return false end
      table.remove(plan,index);state.section_index=math.min(index,#plan)
    elseif action=='up' or action=='down' then
      local target=index+(action=='up' and -1 or 1)
      if target<1 or target>#plan then return false end
      plan[index],plan[target]=plan[target],plan[index];state.section_index=target
    else return false end
    state.options.sections=plan;state.options._implicit_sections=nil
    state.outline_section=plan[state.section_index].id
    state.presentation_section=state.outline_section
    state.instrument_section=plan[state.section_index].id
    state.tab=5;state.status='Section plan updated; no files written.';redraw();return true
  end
  function state.set(key,input)
    if key:match('^style:') then
      local id=key:sub(7)
      local f=require('lilyp.settings').by_id[id]
      if not f then return false end
      local parsed=input
      if f.kind=='number' then parsed=tonumber(input) end
      local ok,err=pcall(function()
        assert(parsed~=nil,'A value is required')
        stage_appearance({[id]=parsed})
      end)
      if not ok then show_error({tab=3,field=key,message=tostring(err)});return false end
      focus(3,key);state.status,state.error_field='Appearance draft updated; p shows the generated LilyPond source.',nil;redraw();return true
    end
    if key=='section' then
      for index,section in ipairs(sections.plan(state.options)) do
        if section.id==input then state.section_index=index;state.instrument_section=section.id;state.presentation_section=section.id;state.outline_section=section.id;focus(5,key);redraw();return true end
      end
      return false
    elseif key=='section_type' or key=='section_name' or key=='section_verses' or key=='section_staff_preset' or key=='section_lyrics' or key=='section_key' or key=='section_mode' or key=='section_meter' then
      local plan=sections.plan(state.options)
      local section=plan[state.section_index]
      if key=='section_type' then section.type=input
      elseif key=='section_name' then section.name=clean(input)
      elseif key=='section_key' or key=='section_mode' or key=='section_meter' then
        section[key:sub(9)]=input~='inherit' and input or nil
      elseif key=='section_lyrics' then
        if input=='inherit' then section.lyrics=nil
        elseif type(input)=='boolean' then
          section.lyrics=input
          if input and section.verses==0 then section.verses=state.options.lyric_verses or 1 end
        else show_error({tab=5,field=key,message='Choose Inherit, On, or Off.'});return false end
      elseif key=='section_staff_preset' then
        if input~='inherit' and not preset_map[input] then
          show_error({tab=5,field=key,message='Choose a supported staff arrangement.'});return false
        end
        section.staff_preset=input~='inherit' and input or nil
      else section.verses=tonumber(input) end
      local err=sections.validate(plan)
      if err then show_error({tab=5,field=key,message=err});return false end
      state.options.sections=plan;state.options._implicit_sections=nil;state.instrument_section=section.id;focus(5,key);state.status,state.error_field='',nil;redraw();return true
    end
    for tab=1,#tabs do
      for _, field in ipairs(fields_for(tab)) do
        if field.key == key then
          local parsed = input
          if key == 'tempo' then
            parsed = tonumber(input)
            if not parsed or parsed ~= math.floor(parsed) or parsed < 1 or parsed > 400 then
              show_error({tab=1,field=key,message='Tempo must be an integer from 1 to 400.'}); return false
            end
          elseif key == 'meter' then
            if not templates.valid_meter(input) then show_error({tab=1,field=key,message='Use a meter such as 5/4 or 7/8.'}); return false end
          elseif key == 'pickup' then
            parsed = clean(input)
            if parsed == '' then parsed = 'none' end
            local length = templates.pickup_length(parsed)
            local first=sections.plan(state.options)[1]
            local n,d = (first.meter or state.options.meter):match('^(%d+)/(%d+)$')
            if not length or length >= tonumber(n)/tonumber(d) then
              show_error({tab=1,field=key,message='Pickup must be shorter than a bar: none, 4, 8, 4., or 8*3.'}); return false
            end
          elseif field.kind == 'instrument' then
            local data, err = catalog()
            local configured = state.options.instrument_inventory and state.options.instrument_inventory ~= ''
            if (configured and (not data or not data.by_name[input])) or type(input) ~= 'string'
              or not input:find('%S') or input:find('[%c]') then
              show_error({tab=2,field=key,message=err or 'Enter a LilyPond MIDI instrument name.'}); return false
            end
          elseif field.choices then
            local found = false
            for _, item in ipairs(field.choices) do if item.value == input then found = true end end
            if not found then show_error({tab=tab,field=key,message='Choose one of the available values.'}); return false end
          else
            parsed = clean(input)
            if key == 'title' and parsed == '' then parsed = 'Untitled' end
          end
          local instrument_keys={assignment_mode=true,group_label=true,category=true,subcategory=true,shared_instrument=true}
          local target=(instrument_keys[key] or key:match('^sound:') or key:match('^label:')) and draft(true) or nil
          if key == 'presentation_scope' then
            state.presentation_section=parsed;state.instrument_section=parsed;state.outline_section=parsed~='score' and parsed or nil;state.selections[3]=1
          elseif key == 'instrument_section' then
            state.instrument_section=parsed;state.presentation_section=parsed;state.outline_section=parsed~='score' and parsed or nil;state.sound_target=nil
          elseif key == 'assignment_mode' then target.mode = parsed
          elseif key == 'group_label' then target.group_label = parsed
          elseif key == 'category' then target.filter_category, target.filter_subcategory = parsed,'all'
          elseif key == 'subcategory' then target.filter_subcategory = parsed
          elseif key == 'shared_instrument' then
            target.shared = parsed
            for _, staff in pairs(target.staves) do if not staff.customized then staff.instrument = parsed end end
          elseif key:match('^sound:') then target.staves[field.staff_id].instrument, target.staves[field.staff_id].customized = parsed,true
          elseif key:match('^label:') then target.staves[field.staff_id].label = parsed
          else state.options[key] = parsed end
          focus(tab,key)
          state.status,state.error_field = '',nil
          redraw()
          return true
        end
      end
    end
    return false
  end

  local editor=require('lilyp.form_edit').attach(state,{
    redraw=redraw,
    commit=function(field,text)return state.set(field.key,text)end,
    invalid_prefix=function(field)
      show_error({tab=state.tab,field=field.key,message='Field label changed; edit discarded. Ctrl+U clears only the value.'})
    end,
  })
  local finish_edit=editor.finish
  function state.switch_tab(tab)
    if not finish_edit(false) then return end
    state.tab = ((tab-1)%#tabs)+1
    if state.tab==1 or state.tab==4 then state.outline_section=nil;state.presentation_section='score';state.instrument_section='score' end
    redraw()
  end
  local function move(delta)
    if not finish_edit(false) then return end
    state.selections[state.tab] = ((state.selections[state.tab]-1+delta)%#fields_for(state.tab))+1
    redraw()
  end
  local function current_field() return fields_for(state.tab)[state.selections[state.tab]] end
  local function target_sound()
    local first
    for _, field in ipairs(fields_for(2)) do
      if field.kind == 'instrument' then
        first = first or field
        if field.staff_id == state.sound_target then return field end
      end
    end
    return first
  end
  local function on_status(message)
    if state.closed then return end
    state.status = message; redraw()
  end
  local function low_register(field)
    for _, staff in ipairs(preset().staves) do if staff.id == field.staff_id then return staff.clef ~= 'treble' end end
    return false
  end
  local function pick_sound(field)
    local layout,scope=preset().value,state.instrument_section
    instruments.pick(state.options,{
      category=draft().filter_category or 'all',subcategory=draft().filter_subcategory or 'all',current=value(field),
      low=low_register(field),on_status=on_status,on_select=function(entry)
        if state.closed or preset().value ~= layout or state.instrument_section~=scope then return end
        if vim.api.nvim_win_is_valid(state.win) then vim.api.nvim_set_current_win(state.win) end
        state.set(field.key,entry.lilypond_midi_instrument)
      end,
    })
  end
  local function cycle(delta)
    local field = current_field()
    if field.kind == 'instrument' then
      local data, err = catalog()
      if not data then show_error({tab=2,field=field.key,message=err}); return end
      local entries = instruments.filtered(data,draft().filter_category,draft().filter_subcategory,nil,state.options)
      local index = 0
      for i,e in ipairs(entries) do if e.lilypond_midi_instrument == value(field) then index=i end end
      if #entries > 0 then state.set(field.key,entries[((index-1+delta)%#entries)+1].lilypond_midi_instrument) end
    elseif field.key=='section_verses' then state.set(field.key,math.max(0,math.min(sections.max_verses,value(field)+delta)))
    elseif field.action then state.section_action(field.action)
    elseif field.key == 'tempo' then state.set(field.key,math.max(1,math.min(400,state.options.tempo+delta)))
    elseif field.id and field.kind=='number' then state.set(field.key,require('lilyp.settings').adjust(field.id,value(field),delta))
    elseif field.choices then
      if #field.choices==0 then state.status='No compatible font face; choose another family or reset weight/shape.';redraw();return end
      local index = 0
      for i,item in ipairs(field.choices) do if item.value == value(field) then index=i end end
      state.set(field.key,field.choices[((index-1+delta)%#field.choices)+1].value)
    else state.status='Press Enter to edit this field.'; redraw() end
  end
  local function edit()
    local field = current_field()
    if field.action then state.section_action(field.action); return end
    if field.kind == 'instrument' and state.options.instrument_inventory and state.options.instrument_inventory ~= '' then pick_sound(field); return end
    if field.id=='lyric_font' then
      local ok,fonts=pcall(require('lilyp.fonts').families,appearance_values())
      if not ok then state.status=tostring(fonts);redraw();return end
      local scope=state.presentation_section
      vim.ui.select(fonts,{prompt='Compatible static lyric font family'},function(item)
        if item and not state.closed and state.is_current() and state.presentation_section==scope then state.set(field.key,item) end
      end)
      return
    end
    if field.choices and not field.editable then
      if type(value(field))=='boolean' then cycle(1)
      else
        local scope,appearance=state.instrument_section,state.presentation_section
        vim.ui.select(field.choices,{prompt=field.label,format_item=function(item)return item.label end},function(item)
          if item and not state.closed and state.is_current() and state.instrument_section==scope and state.presentation_section==appearance then state.set(field.key,item.value) end
        end)
      end
      return
    end
    local row = form.row(state,state.selections[state.tab])
    editor.begin(field,row,clean(value(field)))
  end
  local function close_preview()
    if state.preview_win and vim.api.nvim_win_is_valid(state.preview_win) then vim.api.nvim_win_close(state.preview_win,true) end
    state.preview_win=nil
    if not state.closed and vim.api.nvim_win_is_valid(state.win) then vim.api.nvim_set_current_win(state.win) end
  end
  state.finish_edit = finish_edit
  state.close_preview = close_preview
  function state.dispose()
    state.closed=true
    state.editing=nil
    audition.stop()
    close_preview()
  end
  local function prepare()
    if not finish_edit(false) then return end
    local ok,source=pcall(templates.prepare,state.options)
    if not ok then close_preview(); show_error(source); return end
    return source
  end
  function state.create()
    local source=prepare()
    if not source then return end
    local path
    if state.options.project_mode == 'project' then
      local ok, result = pcall(templates.create_project,source,state.options)
      if not ok then
        show_error({tab=4,field='project_directory',message=tostring(result)})
        return
      end
      path = result
    end
    return state.created(source,path)
  end
  state.generate = state.create -- Compatibility for older integrations.
  function state.preview()
    local source=prepare()
    if not source then return end
    audition.stop()
    close_preview()
    local buf=vim.api.nvim_create_buf(false,true)
    vim.bo[buf].bufhidden,vim.bo[buf].swapfile='wipe',false
    vim.api.nvim_buf_set_lines(buf,0,-1,false,vim.split(source,'\n',{plain=true,trimempty=true}))
    vim.bo[buf].modifiable=false
    vim.bo[buf].syntax='lilypond'
    local w,h=math.min(116,vim.o.columns-4),vim.o.lines-6
    state.preview_win=vim.api.nvim_open_win(buf,true,{relative='editor',row=1,col=math.floor((vim.o.columns-w-2)/2),width=w,height=h,
      style='minimal',border='rounded',title=' Source preview · q returns · g creates ',title_pos='center'})
    for _,key in ipairs({'q','<Esc>'}) do vim.keymap.set('n',key,close_preview,{buffer=buf,silent=true}) end
    vim.keymap.set('n','g',state.create,{buffer=buf,silent=true,nowait=true})
    return buf
  end
  function state.audition()
    if not finish_edit(false) then return end
    local field=target_sound()
    local data,err=catalog()
    if not data then show_error({tab=2,field='category',message=err}); return end
    local entry=data.by_name[value(field)]
    if not entry then show_error({tab=2,field=field.key,message='Choose an instrument before auditioning.'}); return end
    audition.play(data,entry,low_register(field),on_status)
  end
  function state.reset()
    finish_edit(true)
    audition.stop()
    state.options,state.selections,state.tab,state.sound_target=templates.defaults(),{1,1,1,1,1},1,nil
    state.section_index=1;state.instrument_section='score';state.presentation_section='score'
    state.outline_section=nil
    state.status,state.error_field='Defaults restored.',nil
    redraw()
  end

  local function map(mode,key,action,opts)
    vim.keymap.set(mode,key,action,vim.tbl_extend('force',{buffer=state.buf,silent=true,nowait=true},opts or {}))
  end
  for _,key in ipairs({'j','<Down>','<Tab>'}) do map('n',key,function() move(1) end) end
  for _,key in ipairs({'k','<Up>','<S-Tab>'}) do map('n',key,function() move(-1) end) end
  for _,key in ipairs({'l','<Right>','<Space>'}) do map('n',key,function() cycle(1) end) end
  for _,key in ipairs({'h','<Left>'}) do map('n',key,function() cycle(-1) end) end
  for _,key in ipairs({'<CR>','i','a'}) do map('n',key,edit) end
  for i=1,#tabs do map('n',tostring(i),function() state.switch_tab(i) end) end
  map('n','[',function() state.switch_tab(state.tab-1) end)
  map('n',']',function() state.switch_tab(state.tab+1) end)
  for _,key in ipairs({'q','<Esc>'}) do map('n',key,state.close) end
  map('n','g',state.create)
  map('n','p',state.preview)
  map('n','v',state.audition)
  map('n','x',function() audition.stop(); on_status('Audition stopped.') end)
  map('n','r',state.reset)
  function state.inherit_style(id)
    if state.tab~=3 and not id then return end
    id=id or current_field().id
    if not id then return end
    local section=presentation_section()
    local saved,before=vim.deepcopy(state.options),appearance_values()
    local ok,err=pcall(function()
      if section then
        local plan=sections.plan(state.options)
        for _,item in ipairs(plan) do if item.id==section.id and item.presentation then item.presentation[id]=nil end end
        state.options.sections=plan
      else
        local baseline=require('lilyp.creation_settings').values(templates.defaults())[id]
        require('lilyp.creation_settings').set(state.options,id,baseline)
      end
      validate_appearance_change(before,appearance_values(),section)
    end)
    if not ok then state.options=saved end
    state.status=ok and ('Appearance setting reset to '..(section and 'inherit the score default.' or 'its creation default.')) or tostring(err)
    redraw();return ok
  end
  map('n','u',function()state.inherit_style()end)
  for key,action in pairs({['+']='add',['-']='remove',J='down',K='up'}) do
    map('n',key,function()if state.tab==5 then state.section_action(action)end end)
  end
  map({'n','i'},'<C-s>',state.create)
  editor.bind(move)
  vim.api.nvim_create_autocmd('CursorMoved',{buffer=state.buf,callback=function()
    if state.drawing or state.editing or state.closed or not state.is_current() or not vim.api.nvim_win_is_valid(state.win) then return end
    local row=vim.api.nvim_win_get_cursor(state.win)[1]
    local index=form.cursor_index(state)
    if not index then return end
    if index ~= state.selections[state.tab] or row < state.layout.first or row > state.layout.last then
      state.selections[state.tab]=index; redraw()
    end
  end})
  state.redraw = redraw
  function state.apply_profile(id)
    if not finish_edit(false) then return false end
    local ok,err=pcall(function()stage_appearance(require('lilyp.readability').get(id))end)
    state.status=ok and 'Readability trial staged; p inspects source. Create/Preview before choosing defaults.' or tostring(err)
    state.error_field=nil;redraw();return ok
  end
  state.center_content=function(kind)
    return require('lilyp.workspace_content').creation(state,kind,current_field())
  end
  function state.select_outline(id)
    if not finish_edit(false) then return end
    if id then
      local found=false
      for index,section in ipairs(sections.plan(state.options)) do
        if section.id==id then state.section_index=index;found=true end
      end
      assert(found,'Unknown section')
    end
    state.outline_section=id
    state.instrument_section=id or 'score';state.presentation_section=id or 'score'
    if id then
      if state.tab~=2 and state.tab~=5 then state.tab=3 end
    else state.tab=1 end
    state.status='';redraw()
  end
  function state.search()
    local advanced=state.advanced;state.advanced=true
    local entries={}
    for tab,name in ipairs(tabs) do
      for index,field in ipairs(fields_for(tab)) do
        entries[#entries+1]={label=name..' · '..field.label,run=function()
          if field.advanced then state.advanced=true end
          focus(tab,field.key)
          redraw()
        end}
      end
    end
    state.advanced=advanced
    return form.search(state,entries)
  end
  function state.choose_navigation()
    vim.ui.select(state.workspace_view.outline,{prompt='Project outline',format_item=function(item)return item.label end},
      function(item)if item and not state.closed then state.focus='settings';state.inspector_closed=false;item.run() end end)
  end
  form.attach(state)
  redraw()
  return state
end

return M
