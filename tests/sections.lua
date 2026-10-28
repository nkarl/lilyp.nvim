local root=vim.fs.dirname(vim.fs.dirname(debug.getinfo(1,'S').source:sub(2)))
vim.opt.rtp:prepend(root)
local scaffold=require('lilyp.scaffold')
local sections=require('lilyp.sections')
local fs=require('lilyp.fs')
local function defaults(preset)
  scaffold.setup({title='Sections',composer='',preset=preset,key='c',mode='major',meter='4/4',tempo=100,
    pickup='8',paper='a4',lyrics=true,chords=true,midi=true,engraving_mode='default',sections={
      {id='section_a',type='intro',name='Intro',verses=2,lyrics=false},
      {id='section_b',type='refrain',name='Refrain "Điệp khúc"',verses=1},
      {id='section_c',type='verse',name='Verses',verses=4,lyrics=true}}})
  return scaffold.defaults()
end
local function compile(main,stem)
  vim.fn.mkdir(vim.fs.dirname(stem),'p')
  local result=vim.system({'lilypond','-o',stem,main},{text=true}):wait(30000)
  local log=(result.stdout or '')..(result.stderr or '')
  assert(result.code==0 and not log:find('warning:') and not log:find('error:'),log)
  return fs.read(stem..'.pdf')
end
local artifact=vim.fn.tempname();vim.fn.mkdir(artifact,'p')
for _,preset in ipairs(scaffold.presets()) do
  local options=defaults(preset.value)
  options.sections[1].meter='2/4'
  options.sections[2].key='g';options.sections[2].mode='minor';options.sections[2].meter='3/4'
  options.project_directory=artifact..'/'..preset.value
  local source=scaffold.render(options)
  local legacy=vim.deepcopy(options)
  legacy.sections[1].verses=0
  for _,section in ipairs(legacy.sections) do section.lyrics=nil end
  assert(scaffold.render(legacy)==source,'Explicit section switches changed an equivalent score')
  local main=scaffold.create_project(source,options)
  local folder=vim.fs.dirname(main)
  local declared=require('lilyp.spec').call({action='read',text=fs.read(folder..'/score.yaml')})
  local specification=fs.read(folder..'/score.yaml')
  for _,id in ipairs({'key','mode','meter'}) do assert(specification:find('\n'..id..': '..vim.json.encode(options[id])..'\n',1,true)) end
  assert(declared.sections[1].meter=='2/4' and declared.sections[2].key=='g' and declared.sections[2].mode=='minor' and declared.sections[2].meter=='3/4')
  assert(declared.sections[3].meter==nil and declared.sections[3].key==nil)
  assert(#declared.sections==3 and declared.sections[3].verses==4 and declared.sections[1].verses==0)
  assert(declared.sections[1].lyrics==false and declared.sections[3].lyrics==true and declared.sections[2].lyrics==nil)
  assert(vim.deep_equal(declared.printed_order,{'section_a','section_b','section_c'}))
  local assembled=fs.read(main)
  for _,section in ipairs(options.sections) do
    local path=sections.filename(section)
    assert(assembled:find('\\include "'..path..'"',1,true))
    assert(vim.fn.filereadable(folder..'/'..path)==1)
    local music=fs.read(folder..'/'..path)
    for _,staff in ipairs(preset.staves) do assert(music:find(staff.id..'Music =',1,true)) end
  end
  assert(fs.read(folder..'/sections/section_b.ily'):find('\\key g \\minor',1,true))
  assert(fs.read(folder..'/sections/section_b.ily'):find('\\time 3/4',1,true))
  assert(fs.read(folder..'/sections/section_c.ily'):find('\\global',1,true))
  assert(not fs.read(folder..'/sections/section_a.ily'):find('\\lyricmode',1,true))
  assert(fs.read(folder..'/sections/section_c.ily'):find(scaffold.lyric_name(preset,preset.staves[1],4)..' = \\lyricmode',1,true))
  compile(main,folder..'/build/main')
  -- Inline source preview and split project have identical pages and MIDI.
  local inline=artifact..'/'..preset.value..'.ly';fs.write(inline,source)
  compile(inline,artifact..'/'..preset.value..'-inline')
  assert(fs.read(folder..'/build/main.midi')==fs.read(artifact..'/'..preset.value..'-inline.midi'))
  for _,kind in ipairs({'project','inline'}) do
    local pdf=kind=='project' and folder..'/build/main.pdf' or artifact..'/'..preset.value..'-inline.pdf'
    local result=vim.system({'pdftoppm','-r','60','-singlefile','-png',pdf,artifact..'/'..kind},{text=true}):wait(10000)
    assert(result.code==0,result.stderr)
  end
  assert(fs.read(artifact..'/project.png')==fs.read(artifact..'/inline.png'),'Splitting changed the PDF appearance')
  -- A section can enable lyrics with the score default Off. Shared lyric style
  -- helpers must still be emitted when the first/inherited sections have none.
  options.lyrics=false
  local mixed=scaffold.render(options)
  local _,files=sections.split(mixed,options)
  assert(not files['sections/section_a.ily']:find('\\lyricmode',1,true))
  assert(not files['sections/section_b.ily']:find('\\lyricmode',1,true))
  assert(files['sections/section_c.ily']:find('\\lyricmode',1,true))
  assert(mixed:find('oddVerseStyle =',1,true))
  local equivalent=vim.deepcopy(options);equivalent.lyrics=true
  for _,section in ipairs(equivalent.sections) do section.lyrics=nil end
  equivalent.sections[1].verses=0;equivalent.sections[2].verses=0
  assert(scaffold.render(equivalent)==mixed,'Section inheritance changed equivalent music/layout')
  local mixed_main=artifact..'/'..preset.value..'-mixed-lyrics.ly';fs.write(mixed_main,mixed)
  compile(mixed_main,artifact..'/'..preset.value..'-mixed-lyrics')
end
-- Parse actual note-on events: lyric counts do not repeat the music.
local options=defaults('treble');options.chords=false;options.project_directory=artifact..'/playback'
options.sections[2].key='d';options.sections[2].meter='3/4';options.sections[2].staff_preset='piano'
local main=scaffold.create_project(scaffold.render(options),options)
local folder=vim.fs.dirname(main)
for id,pitch in pairs({section_b='f',section_c='f'}) do
  local path=folder..'/sections/'..id..'.ily'
  fs.write(path,(fs.read(path):gsub('[cd]1%*([34]/4)',pitch..'1*%1')))
end
compile(main,folder..'/build/main')
local midi=fs.read(folder..'/build/main.midi')
local function u32(pos)local a,b,c,d=midi:byte(pos,pos+3);return ((a*256+b)*256+c)*256+d end
local ppq=midi:byte(13)*256+midi:byte(14)
local offset,notes,signatures=15,{},{}
while offset<=#midi do
  local length=u32(offset+4)
  local data=midi:sub(offset+8,offset+7+length);offset=offset+8+length
  local pos,running,time=1,nil,0
  local function vlq()
    local value=0
    repeat local byte=data:byte(pos);pos=pos+1;value=value*128+byte%128;if byte<128 then return value end until false
  end
  while pos<=#data do
    time=time+vlq()
    local status=data:byte(pos)
    if status>=128 then pos=pos+1 else status=running end
    if status==255 then
      local kind=data:byte(pos);pos=pos+1;local size=vlq()
      if kind==88 or kind==89 then signatures[#signatures+1]={kind=kind,time=time,a=data:byte(pos),b=data:byte(pos+1)} end
      pos=pos+size
    elseif status==240 or status==247 then local size=vlq();pos=pos+size
    else
      running=status;local kind=math.floor(status/16)
      if kind==9 and data:byte(pos+1)>0 then notes[#notes+1]={pitch=data:byte(pos),time=time} end
      pos=pos+((kind==12 or kind==13) and 1 or 2)
    end
  end
end
assert(#notes==2 and notes[1].pitch==65 and notes[2].pitch==65,vim.inspect(notes))
assert(notes[1].time==ppq*4.5 and notes[2].time==ppq*7.5,vim.inspect(notes))
local function has_signature(kind,time,a,b)
  for _,event in ipairs(signatures) do
    if event.kind==kind and event.time==time*ppq and event.a==a and event.b==b then return true end
  end
  return false
end
assert(has_signature(88,4.5,3,2) and has_signature(88,7.5,4,2),vim.inspect(signatures))
-- Lyric Off and PDF-only remain supported for planned sections.
options=defaults('bass');options.lyrics=false;options.midi=false
for _,section in ipairs(options.sections) do section.lyrics=nil end
local silent=scaffold.render(options)
assert(not silent:find('\\lyricmode',1,true) and not silent:find('\\midi',1,true))
fs.write(artifact..'/pdf-only.ly',silent);compile(artifact..'/pdf-only.ly',artifact..'/pdf-only')
assert(vim.fn.filereadable(artifact..'/pdf-only.midi')==0)
-- Validation rejects malformed plans before writing even a project directory.
for _,bad in ipairs({{},{{id='../escape',type='verse',name='Bad',verses=1}},
  {{id='section_a',type='verse',name='Bad',verses=13}},
  {{id='section_a',type='verse',name='Bad',verses=1,lyrics='yes'}},
  {{id='section_a',type='verse',name='Bad',verses=1,key='invalid'}},
  {{id='section_a',type='verse',name='Bad',verses=1,mode='dorian'}},
  {{id='section_a',type='verse',name='Bad',verses=1,meter='3/3'}},
  {{id='section_a',type='verse',name='Bad',verses=1},{id='section_a',type='verse',name='Duplicate',verses=1}}}) do
  options=defaults('treble');options.sections=bad;options.project_directory=vim.fn.tempname()
  assert(scaffold.validate(options).tab==5)
  assert(not pcall(scaffold.create_project,'invalid',options))
  assert(vim.fn.isdirectory(options.project_directory)==0)
end
-- The initial pickup belongs to the first section's effective meter.
options=defaults('treble');options.pickup='2';options.sections[1].meter='2/4'
assert(scaffold.validate(options).field=='pickup')
options.sections[1].meter='3/4';assert(not scaffold.validate(options))
-- Real form editing keeps identifiers stable and changes only a draft.
vim.o.columns,vim.o.lines=72,27
scaffold.setup({title='Plan',composer='',preset='treble',key='c',mode='major',meter='4/4',tempo=100,
  paper='a4',lyrics=true,midi=true,engraving_mode='default'})
local ui=require('lilyp.ui')
local form=ui.new();form.switch_tab(5)
assert(form.set('section_key','d') and form.set('section_mode','minor') and form.set('section_meter','7/8'))
assert(form.set('key','g') and form.set('meter','3/4'))
local effective=sections.options(form.options,sections.plan(form.options)[1])
assert(effective.key=='d' and effective.mode=='minor' and effective.meter=='7/8')
assert(not form.set('section_meter','3/3') and not form.set('section_key','bad'))
assert(form.set('section_key','inherit') and form.set('section_mode','inherit') and form.set('section_meter','inherit'))
effective=sections.options(form.options,sections.plan(form.options)[1])
assert(effective.key=='g' and effective.mode=='major' and effective.meter=='3/4')
local rows=sections.plan(form.options)[1].verses
assert(form.set('section_lyrics',false))
assert(form.options.sections[1].verses==rows and sections.lyric_rows(form.options,form.options.sections[1])==0)
assert(form.set('section_lyrics',true) and form.options.sections[1].verses==rows)
assert(form.set('lyrics',false))
assert(sections.lyric_rows(form.options,form.options.sections[1])==rows,'Section On did not override score Off')
assert(form.set('section_lyrics','inherit'))
assert(form.options.sections[1].lyrics==nil and sections.lyric_rows(form.options,form.options.sections[1])==0)
assert(form.set('section_verses',0) and form.set('section_lyrics',true))
assert(form.options.sections[1].verses==form.options.lyric_verses,'On did not restore a positive row count')
assert(not form.set('section_lyrics','yes'))
assert(form.set('lyrics',true))
assert(form.set('section_name','Refrain'))
assert(form.set('section_type','refrain'))
local id=form.options.sections[1].id
assert(form.section_action('add'))
assert(form.set('section_verses',4))
assert(form.set('section_name','Four verses'))
assert(form.section_action('up'))
assert(form.options.sections[1].id~=id and form.options.sections[2].id==id)
assert(form.set('section',id) and form.set('section_name','Renamed'))
assert(form.options.sections[2].id==id)
assert(not form.set('section_verses',-1))
assert(form.section_action('remove') and not form.section_action('remove'))
local lines=vim.api.nvim_buf_get_lines(form.buf,0,-1,false)
assert(#lines==vim.api.nvim_win_get_height(form.win) and table.concat(lines,'\n'):find('5 Sections',1,true),'Sections navigation is clipped')
form.close()
-- Existing section metadata is inspectable without making any source changes.
local before=fs.snapshot(folder)
local view=ui.open(main)
assert(table.concat(view.sections(),'\n'):find('Verses',1,true))
assert(vim.deep_equal(before,fs.snapshot(folder)))
view.close()
print('PASS: section plans, stable IDs, all presets, split/inline PDF and MIDI parity, playback once in order, validation, UI, and read-only inspection')
print('Artifacts: '..artifact)
