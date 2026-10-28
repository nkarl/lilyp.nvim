-- Run with Neovim headless; compiles real LilyPond and inspects timed MIDI events.
local root=vim.fs.dirname(vim.fs.dirname(debug.getinfo(1,'S').source:sub(2)))
vim.opt.rtp:prepend(root)
local scaffold=require('lilyp.scaffold')
local sections=require('lilyp.sections')
local fs=require('lilyp.fs')
local artifact=vim.fn.tempname();vim.fn.mkdir(artifact,'p')
local inventory=vim.env.LILYPOND_INSTRUMENT_INVENTORY
local function defaults(preset)
  scaffold.setup({title='Mixed staves',composer='',preset=preset,key='c',mode='major',meter='4/4',tempo=100,
    pickup='8',paper='a4',lyrics=true,chords=false,midi=true,engraving_mode='default',instrument_inventory=inventory,
    sections={{id='section_a',type='verse',name='Verse',verses=1},
      {id='section_b',type='refrain',name='Refrain',verses=2,staff_preset='treble'},
      {id='section_c',type='verse',name='Return',verses=1}}})
  local opts=scaffold.defaults()
  local draft=opts.assignments[preset]
  draft.mode='shared';draft.shared='flute'
  if preset=='piano' then draft.mode='separate';draft.staves.upper.instrument='flute';draft.staves.lower.instrument='cello' end
  return opts
end
local function compile(main,stem)
  vim.fn.mkdir(vim.fs.dirname(stem),'p')
  local result=vim.system({'lilypond','-o',stem,main},{text=true}):wait(30000)
  local log=(result.stdout or '')..(result.stderr or '')
  assert(result.code==0 and not log:find('warning:') and not log:find('error:'),log)
  assert(vim.fn.filereadable(stem..'.pdf')==1)
end
local function midi(path)
  local data=fs.read(path)
  local function u32(pos)local a,b,c,d=data:byte(pos,pos+3);return ((a*256+b)*256+c)*256+d end
  local ppq=data:byte(13)*256+data:byte(14)
  local offset,events=15,{}
  local track=0
  while offset<=#data do
    track=track+1
    local length=u32(offset+4)
    local bytes=data:sub(offset+8,offset+7+length);offset=offset+8+length
    local pos,running,time=1,nil,0
    local function vlq()
      local value=0
      repeat local b=bytes:byte(pos);pos=pos+1;value=value*128+b%128;if b<128 then return value end until false
    end
    while pos<=#bytes do
      time=time+vlq()
      local status=bytes:byte(pos)
      if status>=128 then pos=pos+1 else status=assert(running) end
      if status==255 then pos=pos+1;local size=vlq();pos=pos+size
      elseif status==240 or status==247 then local size=vlq();pos=pos+size
      else
        running=status
        local kind=math.floor(status/16)
        events[#events+1]={time=time,kind=kind,channel=status%16,a=bytes:byte(pos),b=bytes:byte(pos+1),order=#events+1,track=track}
        pos=pos+((kind==12 or kind==13) and 1 or 2)
      end
    end
  end
  table.sort(events,function(a,b)
    if a.time~=b.time then return a.time<b.time end
    if (a.kind==12)~=(b.kind==12) then return a.kind==12 end
    return a.order<b.order
  end)
  local programs,notes={},{}
  for _,event in ipairs(events) do
    if event.kind==12 then programs[event.channel]=event.a end
    if event.kind==9 and event.b>0 then
      notes[#notes+1]={time=event.time/ppq,pitch=event.a,program=assert(programs[event.channel]),track=event.track}
    end
  end
  return notes
end
local function program_notes(notes,program)
  return vim.tbl_filter(function(note)return note.program==program end,notes)
end
local function times(notes)
  return vim.tbl_map(function(note)return note.time end,notes)
end

-- Piano -> treble -> piano: a missing lower voice must skip the entire repeated section.
local opts=defaults('piano');opts.chords=true;opts.project_directory=artifact..'/repeated'
local main=scaffold.create_project(scaffold.prepare(opts),opts)
local folder=vim.fs.dirname(main)
local a=folder..'/sections/section_a.ily'
fs.write(a,(fs.read(a):gsub('r1%*4/4','c1*4/4')))
local b=folder..'/sections/section_b.ily'
fs.write(b,(fs.read(b):gsub('c1%*4/4 |','\\repeat volta 2 { d1 | }')))
local c=folder..'/sections/section_c.ily'
fs.write(c,(fs.read(c):gsub('c1%*4/4','e1*4/4'):gsub('r1%*4/4','c1*4/4')))
compile(main,folder..'/build/main')
local notes=midi(folder..'/build/main.midi')
local lead,lower,chords=program_notes(notes,73),program_notes(notes,42),program_notes(notes,0)
assert(vim.deep_equal(times(lead),{0,0.5,4.5,8.5,12.5}),vim.inspect(lead))
assert(vim.deep_equal(times(lower),{0.5,12.5}),vim.inspect(lower))
assert(#chords==12 and chords[1].time==0.5 and chords[#chords].time==12.5,vim.inspect(chords))
assert(lead[3].track==lead[1].track and lead[5].track==lead[1].track,'Lead must keep its track across arrangements')
-- Editing the one shared source instrument value changes MIDI at that boundary only.
fs.write(b,(fs.read(b):gsub('MidiInstrument = "flute"','MidiInstrument = "oboe"')))
compile(main,folder..'/build/changed')
notes=midi(folder..'/build/changed.midi')
assert(vim.deep_equal(times(program_notes(notes,68)),{4.5,8.5}),vim.inspect(notes))
assert(vim.deep_equal(times(program_notes(notes,73)),{0,0.5,12.5}),vim.inspect(notes))

-- Exercise all directed preset transitions, including voices entering after an intro.
local count=0
for _,first in ipairs(scaffold.presets()) do
  for _,second in ipairs(scaffold.presets()) do
    local options=defaults(first.value)
    options.pickup='none'
    options.sections[2].staff_preset=second.value
    options.sections[3]=nil
    local effective=sections.options(options,options.sections[2])
    assert(scaffold.instrument(effective,second.staves[1].id)=='flute','Compatible lead should inherit its sound')
    local source=scaffold.prepare(options)
    local path=artifact..'/'..first.value..'-'..second.value..'.ly';fs.write(path,source)
    local stem=path:sub(1,-4);compile(path,stem)
    local played=program_notes(midi(stem..'.midi'),73)
    local lead_times={}
    local lead_track=played[1].track
    for _,note in ipairs(played) do if note.track==lead_track then lead_times[#lead_times+1]=note.time end end
    assert(vim.deep_equal(lead_times,{0,4}),first.value..' -> '..second.value..': '..vim.inspect(played))
    count=count+1
  end
end

-- The new printed arrangements retain independently editable lyrics and MIDI parts.
for _,key in ipairs({'satb_two_staves','two_treble'}) do
  local options=defaults(key)
  options.pickup='none';options.sections=nil
  options.project_directory=artifact..'/'..key..'-parts'
  local definition=scaffold.preset(key)
  local draft=options.assignments[key];draft.mode='separate'
  local sounds={'flute','oboe','viola','cello'}
  local programs={73,68,41,42}
  for index,staff in ipairs(definition.staves) do draft.staves[staff.id].instrument=sounds[index] end
  local source=scaffold.prepare(options):gsub('\\skip 1','La')
  local entry=scaffold.create_project(source,options)
  local section=fs.read(options.project_directory..'/sections/section_a.ily')
  local _,printed=section:gsub('\\new Staff%s','')
  assert(printed==2,key..': must print exactly two staves')
  for _,staff in ipairs(definition.staves) do
    local lyric=scaffold.lyric_name(definition,staff,1)
    assert(section:find(lyric..' = \\lyricmode',1,true))
    assert(section:find('\\lyricsto "'..staff.id..'" { \\'..lyric..' }',1,true))
  end
  if key=='satb_two_staves' then
    assert(section:find('\\voiceOne \\sopranoMusic',1,true) and section:find('\\voiceTwo \\altoMusic',1,true))
    assert(section:find('\\voiceOne \\tenorMusic',1,true) and section:find('\\voiceTwo \\bassMusic',1,true))
  else
    local _,clefs=section:gsub('\\clef "treble"','')
    assert(clefs==2 and not section:find('\\clef "bass"',1,true))
  end
  compile(entry,options.project_directory..'/build/main')
  local actual=midi(options.project_directory..'/build/main.midi')
  for index=1,#definition.staves do
    local notes=program_notes(actual,programs[index])
    assert(#notes==1 and notes[1].time==0,key..': missing/duplicated part '..index..': '..vim.inspect(actual))
  end
  if key=='satb_two_staves' then
    -- Changing only the printed grouping must leave all timed notes/programs intact.
    local full=vim.deepcopy(options)
    full.preset='satb';full.assignments.satb=vim.deepcopy(draft)
    local four=scaffold.prepare(full):gsub('r1%*4/4','c1*4/4')
    local path=artifact..'/four-staff-reference.ly';fs.write(path,four)
    compile(path,artifact..'/four-staff-reference')
    assert(vim.deep_equal(actual,midi(artifact..'/four-staff-reference.midi')),'Printed SATB grouping changed timed MIDI events/programs')
  end
end

-- New parts enter exactly after a silent intro, with no section-start delay.
local entrance=defaults('treble')
entrance.sections[1].verses=0
entrance.sections[2].staff_preset='satb'
entrance.sections[3]=nil
local profile=sections.assignment(entrance,entrance.sections[2])
profile.mode='separate'
profile.staves.alto.instrument='oboe';profile.staves.tenor.instrument='bassoon';profile.staves.bass.instrument='cello'
entrance.sections[2].assignments={satb=profile}
entrance.project_directory=artifact..'/entrance'
local entry=scaffold.create_project(scaffold.prepare(entrance),entrance)
local entrydir=vim.fs.dirname(entry)
local voices=entrydir..'/sections/section_b.ily'
fs.write(voices,(fs.read(voices):gsub('r1%*4/4','c1*4/4')))
compile(entry,entrydir..'/build/main')
local entered=midi(entrydir..'/build/main.midi')
for _,program in ipairs({73,68,70,42}) do
  assert(vim.deep_equal(times(program_notes(entered,program)),{4.5}),vim.inspect(entered))
end
entrance.midi=false
local pdfonly=scaffold.prepare(entrance)
assert(not pdfonly:find('\\midi',1,true))
fs.write(artifact..'/mixed-pdf.ly',pdfonly);compile(artifact..'/mixed-pdf.ly',artifact..'/mixed-pdf')
assert(vim.fn.filereadable(artifact..'/mixed-pdf.midi')==0)

-- Spec records inheritance, overrides, stable playback IDs, and effective instruments.
local metadata=require('lilyp.spec').call({action='read',text=fs.read(folder..'/score.yaml')})
assert(metadata.staff_preset=='piano' and metadata.sections[1].staff_preset==nil)
assert(metadata.sections[2].staff_preset=='treble')
assert(metadata.sections[2].voices[1].playback_voice=='upper')
assert(metadata.sections[2].voices[1].instrument=='flute')
assert(metadata.sections[3].voices[2].playback_voice=='lower')

-- Actual UI: per-section choices, retained assignments, default inheritance, and no writes.
vim.o.columns,vim.o.lines=72,27
opts=defaults('piano')
local ui=require('lilyp.ui')
local form=ui.new();form.options=opts
assert(form.set('section','section_b'))
assert(form.set('section_staff_preset','satb'))
form.switch_tab(2)
assert(form.set('assignment_mode','separate'))
assert(form.set('sound:soprano','oboe'))
assert(form.set('label:soprano','Solo'))
form.switch_tab(5)
assert(form.set('section_staff_preset','bass'))
form.switch_tab(2)
assert(form.set('shared_instrument','cello'))
form.switch_tab(5)
assert(form.set('section_staff_preset','satb'))
form.switch_tab(2)
local draft=form.options.sections[2].assignments.satb
assert(draft.staves.soprano.instrument=='oboe' and draft.staves.soprano.label=='Solo')
local lines=vim.api.nvim_buf_get_lines(form.buf,0,-1,false)
assert(#lines==vim.api.nvim_win_get_height(form.win) and lines[form.layout.actions_row]:find('q Close',1,true),'Instrument controls must fit the narrow form')
assert(form.set('instrument_section','score'))
assert(form.set('preset','bass'))
assert(form.options.sections[1].staff_preset==nil and sections.staff_preset(form.options,form.options.sections[1])=='bass')
assert(form.options.sections[2].staff_preset=='satb')
assert(form.set('section','section_b') and form.set('section_staff_preset','inherit'))
assert(form.options.sections[2].staff_preset==nil)
assert(not form.set('section_staff_preset','unknown'))
assert(not form.set('section_staff_preset',false))
assert(form.set('section_staff_preset','satb'))
local preview=assert(form.preview())
assert(table.concat(vim.api.nvim_buf_get_lines(preview,0,-1,false),'\n'):find('sectionbsopranoMidiInstrument = "oboe"',1,true))
form.close()

-- Malformed overrides fail validation before a project can be created.
opts=defaults('piano');opts.sections[2].staff_preset='unknown'
assert(scaffold.validate(opts).tab==5)
opts=defaults('piano');opts.sections[2].assignments={treble={mode='shared',shared='\n',staves={melody={label='Solo'}}}}
local err=scaffold.validate(opts)
assert(err and err.tab==2 and err.section_id=='section_b',vim.inspect(err))

-- Existing project inspection stays read-only, including new arrangement metadata.
local before=fs.snapshot(folder)
local view=ui.open(main)
assert(table.concat(view.sections(),'\n'):find('Staff arrangement: treble',1,true))
view.close()
assert(vim.deep_equal(before,fs.snapshot(folder)))
print('PASS: '..count..' staff transitions, continuous MIDI timing, repeats, pickups, instruments, metadata, UI retention, and read-only inspection')
print('Artifacts: '..artifact)
