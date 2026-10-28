local root=vim.fs.dirname(vim.fs.dirname(debug.getinfo(1,'S').source:sub(2)))
vim.opt.rtp:prepend(root)
local scaffold=require('lilyp.scaffold')
local fs=require('lilyp.fs')
local inventory=vim.env.LILYPOND_INSTRUMENT_INVENTORY
local artifact=vim.env.LILYP_CREATION_OUTPUT or vim.fn.tempname();vim.fn.mkdir(artifact,'p')
scaffold.setup({title='Presentation creation',subtitle='Learning source',composer='Test',preset='treble',key='c',mode='major',
  meter='4/4',tempo=90,paper='a4',lyrics=true,chords=true,midi=true,engraving_mode='default',instrument_inventory=inventory})
local function compile(name,source)
  local path=artifact..'/'..name;fs.write(path..'.ly',source)
  local result=vim.system({'lilypond','-o',path,path..'.ly'},{text=true}):wait(30000)
  local log=(result.stdout or '')..(result.stderr or '')
  fs.write(path..'.log',log)
  assert(result.code==0 and not log:lower():find('warning:',1,true),log)
  return path
end
local options=scaffold.defaults()
local baseline=compile('baseline',scaffold.prepare(options))
local values={staff_size=16,paper='letter',top_margin=12,bottom_margin=13,left_margin=14,right_margin=15,
  page_count=1,ragged_last_bottom=false,title_size=5,subtitle_size=4,subtitle_shape='upright',composer_size=2,
  lyric_font='DejaVu Serif',lyric_size=2,lyric_shape='upright',word_spacing=3,stanza_size=2,stanza_shape='upright',
  row_spacing=5,odd_color='#002266',even_color='#662200',metronome_color='#cc0000',rehearsal_color='#aa0000',
  text_mark_color='#880000',hide_tempo_note=true,header_gap=1,section_gap=1,chord_size=1,chord_padding=3,indent=8,short_indent=6}
for id,value in pairs(values) do require('lilyp.creation_settings').set(options,id,value) end
local source=scaffold.prepare(options)
local main,style=scaffold.split_style(source)
local observed=require('lilyp.style').inspect(style)
for id,value in pairs(values) do
  assert(observed[id].tag=='recognized' and observed[id].value==value,id..': '..vim.inspect(observed[id]))
end
assert(main:find('\\headerGap',1,true) and style:find('headerGap =',1,true))
local styled=compile('styled',source)
assert(fs.read(styled..'.midi')==fs.read(baseline..'.midi'),'Presentation changed playback')
options.sections={{id='section_a',type='intro',name='Intro',verses=1,presentation={staff_size=18,lyric_size=0,hide_tempo_note=false,indent=0}},
  {id='section_b',type='verse',name='Verse',verses=2}}
options.project_directory=artifact..'/project'
source=scaffold.prepare(options)
local project=scaffold.create_project(source,options)
local split=compile('split', '\\version "2.26.0"\n\\include '..vim.json.encode(project))
local inline=compile('inline',source)
assert(fs.read(split..'.midi')==fs.read(inline..'.midi'))
local function pages(path)
  local result=vim.system({'pdftoppm','-r','100','-png',path..'.pdf',path..'-page'},{text=true}):wait(30000)
  assert(result.code==0,result.stderr)
  local found={}
  for name,kind in vim.fs.dir(artifact) do
    local number=name:match('^'..vim.pesc(vim.fs.basename(path))..'%-page%-(%d+)%.png$')
    if kind=='file' and number then found[number]=fs.read(artifact..'/'..name) end
  end
  assert(next(found));return found
end
assert(vim.deep_equal(pages(split),pages(inline)),'Splitting creation styling changed PDF appearance')
local s=require('lilyp.session').open(project)
assert(not s.specified,'Creation must retain the explicit specification-import workflow')
local local_values=s.section_styles.section_a.import_candidate
assert(local_values.staff_size==18 and local_values.lyric_size==0 and local_values.hide_tempo_note==false and local_values.indent==0)
s:close()
options.sections[1].presentation={paper='a4'}
assert(scaffold.validate(options).tab==5,'Document-only setting accepted in section scope')

vim.o.columns,vim.o.lines=100,32
local state=require('lilyp.ui').new()
for id,value in pairs(values) do
  if id=='paper' then assert(state.set('paper',value)) else assert(state.set('style:'..id,value)) end
end
assert(not state.set('style:page_count',0) and not state.set('style:odd_color','red'))
assert(state.set('style:page_count',1))
assert(state.set('presentation_scope','section_a'))
assert(state.set('style:staff_size',18) and state.set('style:lyric_size',0) and state.set('style:hide_tempo_note',false))
local explanation=table.concat(require('lilyp.learning').creation(state.options,{key='style:staff_size',id='staff_size',scope='section_a'}),'\n')
assert(explanation:find('layout-set-staff-size 18',1,true),'Learning details must show the selected section’s actual generated expression')
assert(not state.set('style:page_count',2))
state.inherit_style('lyric_size')
assert(state.options.sections[1].presentation.lyric_size==nil)
assert(state.set('presentation_scope','score'))
assert(state.options.style.lyric_size==2 and state.options.sections[1].presentation.hide_tempo_note==false)
assert(not scaffold.render(state.options):find('piece =',1,true),'An appearance override introduced a section heading')
assert(state.set('style:word_spacing',4) and state.options.style.lyric_word_spacing==4)
assert(state.set('preset','satb_two_staves') and state.set('assignment_mode','separate'))
assert(state.set('sound:alto','oboe') and state.set('label:alto','Altos'))
assert(state.set('preset','two_treble') and state.set('preset','satb_two_staves'))
assert(state.options.assignments.satb_two_staves.staves.alto.instrument=='oboe')
assert(state.options.assignments.satb_two_staves.staves.alto.label=='Altos')
assert(state.set('section','section_a') and state.set('section_staff_preset','two_treble'))
assert(state.set('presentation_scope','score'))
state.inherit_style('lyric_font');state.inherit_style('staff_size')
assert(require('lilyp.creation_settings').values(state.options).staff_size==15)
state.close()
print('PASS: all presentation settings in creation, canonical/legacy options, section inheritance/false/zero, source import, split/inline compilation, unchanged MIDI, and UI validation')
print('Artifacts: '..artifact)
