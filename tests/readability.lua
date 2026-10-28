local root=vim.fs.dirname(vim.fs.dirname(debug.getinfo(1,'S').source:sub(2)))
vim.opt.rtp:prepend(root)
local fs=require('lilyp.fs')
local settings=require('lilyp.settings')
local fonts=require('lilyp.fonts')
local scaffold=require('lilyp.scaffold')
local artifact=vim.env.LILYP_READABILITY_OUTPUT or vim.fn.tempname();vim.fn.mkdir(artifact,'p')
local function rejects(fn,needle)
  local ok,err=pcall(fn);assert(not ok,'Expected rejection')
  assert(tostring(err):find(needle,1,true),tostring(err))
end
local function press(state,key)
  for _,map in ipairs(vim.api.nvim_buf_get_keymap(state.buf,'n')) do if map.lhs==key then return map.callback() end end
  error('Missing mapping '..key)
end
local function compile(name,text)
  local path=artifact..'/'..name
  fs.write(path..'.ly',text)
  local result=vim.system({'lilypond','-o',path,path..'.ly'},{text=true}):wait(30000)
  local log=(result.stdout or '')..(result.stderr or '');fs.write(path..'.log',log)
  assert(result.code==0 and not log:find('warning:',1,true),log)
  return path,log
end
assert(settings.adjust('lyric_size',2,1)==2.25 and settings.adjust('staff_size',20,-1)==19.5)
assert(settings.adjust('lyric_size',6,1)==6)
settings.validate_values({lyric_staff_distance=3,lyric_staff_minimum=4},'global')
settings.validate_values({row_minimum=1,row_padding=2},'section')
rejects(function()settings.validate('system_distance',12,'section')end,'unsupported scope')
assert(fonts.check({lyric_font='DejaVu Sans',lyric_weight='bold',lyric_shape='oblique'}))
rejects(function()fonts.check({lyric_font='Nonexistent Lylip Test Family',lyric_weight='bold'})end,'No supported static')
assert(vim.tbl_contains(fonts.families({lyric_shape='upright',lyric_weight='normal'}),'DejaVu Sans'))

scaffold.setup({title='Đọc rõ lời ca',composer='Readability checks',preset='satb_two_staves',key='c',mode='major',meter='4/4',
  tempo=90,paper='a4',lyrics=true,midi=true,chords=false,engraving_mode='default',
  instrument_inventory=vim.env.LILYPOND_INSTRUMENT_INVENTORY})
local options=scaffold.defaults()
local function music(opts)return scaffold.prepare(opts):gsub('c1%*4/4 |','c4 d e f | \\break g4 f e d |'):gsub('\\skip 1','Đâu có tình yêu thương ở nơi này')end
local baseline=compile('baseline',music(options))
options.style.lyric_font='DejaVu Sans';options.style.lyric_weight='bold';options.style.lyric_shape='oblique';options.style.lyric_size=2.25
for _,relationship in ipairs(require('lilyp.spacing')) do
  options.style[relationship.preferred or relationship.id..'_distance']=20
  options.style[relationship.id..'_minimum']=10
  options.style[relationship.id..'_padding']=2
  options.style[relationship.id..'_stretch']=0
end
local source=music(options)
local styled=compile('styled',source)
assert(fs.read(styled..'.midi')==fs.read(baseline..'.midi'),'Appearance changed MIDI')
local _,styling=scaffold.split_style(source)
local inspected=require('lilyp.style').inspect(styling)
for _,f in ipairs(settings.list) do
  if f.id=='lyric_weight' or f.spacing then
    local value=options.style[f.id]
    assert(inspected[f.id].tag=='recognized' and inspected[f.id].value==value,f.id..': '..vim.inspect(inspected[f.id]))
  end
end
local parent=styling..'\n\\paper { system-system-spacing = #\'( (basic-distance . 12) ) }\n'
assert(require('lilyp.style').inspect(parent).system_distance.tag=='custom','Compound spacing expression was treated as editable')

-- Verify that the grouped-staff control changes physical separation, not voice count.
local function geometry(distance)
  local text=[=[\version "2.26.0"
\paper { ragged-bottom = ##t }
\score {
  \new PianoStaff << \new Staff { c'1 } \new Staff { \clef bass c1 } >>
  \layout {
    \context { \Score \override StaffGrouper.staff-staff-spacing.basic-distance = #DISTANCE
      \override StaffGrouper.staff-staff-spacing.minimum-distance = #4
      \override StaffGrouper.staff-staff-spacing.padding = #0
      \override StaffGrouper.staff-staff-spacing.stretchability = #0 }
    \context { \Staff \override StaffSymbol.after-line-breaking =
      #(lambda (grob) (format #t "STAFF-Y=~a\n" (ly:grob-relative-coordinate grob (ly:grob-system grob) Y))) }
  }
}
]=]
  local _,log=compile('geometry-'..distance,text:gsub('DISTANCE',tostring(distance)))
  local y={};for n in log:gmatch('STAFF%-Y=([%-%d%.]+)') do y[#y+1]=tonumber(n) end
  assert(#y==2,log);return math.abs(y[1]-y[2])
end
assert(geometry(24)>geometry(8)+10,'Grouped staff spacing had no physical effect')

local project=fs.stage(fs.snapshot(root..'/tests/fixtures'))
local s=require('lilyp.session').open(project)
local _,yaml=s:render();s:close();fs.write(project..'/score.yaml',yaml)
local before=fs.snapshot(project)
s=require('lilyp.session').open(project)
s:set_many({lyric_font='DejaVu Sans',lyric_weight='bold',lyric_shape='oblique',lyric_size=2.25})
s:set_many({staff_group_distance=16,staff_group_minimum=8,staff_group_padding=2,staff_group_stretch=0},'refrain')
local saved={draft=vim.deepcopy(s.draft),sections=vim.deepcopy(s.section_drafts)}
rejects(function()s:set_many({staff_size=22,lyric_font='Nonexistent Lylip Test Family'})end,'No supported static')
assert(vim.deep_equal(saved.draft,s.draft) and vim.deep_equal(saved.sections,s.section_drafts),'Failed profile partially changed the draft')
rejects(function()s:set_many({lyric_size=3,system_distance=10},'refrain')end,'Not available in section scope')
assert(vim.deep_equal(saved.sections,s.section_drafts))
local preview=s:preview();assert(vim.fn.filereadable(preview.pdf)==1)
assert(vim.deep_equal(before,fs.snapshot(project)))
s:apply();s:close()
s=require('lilyp.session').open(project)
assert(#s.conflicts==0 and s.values.lyric_weight=='bold' and s.values.lyric_size==2.25)
assert(s:view('refrain').overrides.staff_group_stretch==0)
s:inherit('refrain','staff_group_stretch');s:apply();s:close()

vim.o.columns,vim.o.lines=160,44
local ui=require('lilyp.ui')
local state=ui.new()
local select=vim.ui.select
vim.ui.select=function(items,_,callback)assert(#items==2);callback(items[1])end
press(state,'R');vim.ui.select=select
assert(state.options.style.staff_size==20 and state.options.style.lyric_size==2)
state.switch_tab(3)
local common_count=#state.workspace_view.fields
press(state,'A');assert(state.advanced and #state.workspace_view.fields==common_count+8)
press(state,'A');assert(not state.advanced and #state.workspace_view.fields==common_count)
state.select_outline('section_a')
assert(state.apply_profile('large_print') and state.options.sections[1].presentation.staff_size==22)
assert(state.options.style.staff_size==20)
-- An inherited family change must also support the retained local shape.
fonts.load()['Lylip Upright Only Test']={normal={upright=true}}
assert(state.set('style:lyric_font','DejaVu Sans') and state.set('style:lyric_shape','oblique'))
state.select_outline(nil)
assert(state.set('style:lyric_font','Lylip Upright Only Test')) -- local family still protects the oblique face
state.select_outline('section_a')
local reset_saved=vim.deepcopy(state.options)
assert(not state.inherit_style('lyric_font') and vim.deep_equal(reset_saved,state.options),'Reset staged an unavailable inherited face')
state.select_outline(nil);assert(state.set('style:lyric_font','DejaVu Sans'))
state.select_outline('section_a');assert(state.inherit_style('lyric_font'));state.select_outline(nil)
local creation_saved=vim.deepcopy(state.options)
assert(not state.set('style:lyric_font','Lylip Upright Only Test'))
assert(vim.deep_equal(creation_saved,state.options),'Global edit invalidated an inherited section font')
state.close()
state=ui.open(project)
assert(state.apply_profile('large_print') and state.session.draft.staff_size==22)
state.switch_tab(5);common_count=#state.workspace_view.fields
press(state,'A');assert(state.advanced and #state.workspace_view.fields==common_count+8)
press(state,'A');assert(not state.advanced)
state.select_scope('refrain');assert(state.apply_profile('standard_reading'))
assert(state.session:view('refrain').overrides.lyric_weight=='normal')
assert(state.set('lyric_shape','oblique'))
state.select_scope(nil)
local current=vim.deepcopy(state.session.draft)
assert(not state.set('lyric_font','Lylip Upright Only Test') and vim.deep_equal(current,state.session.draft))
assert(state.set('lyric_font','DejaVu Sans'))
state.select_scope('refrain');assert(state.set('lyric_shape','upright'));state.select_scope(nil)
assert(state.set('lyric_font','Lylip Upright Only Test'))
state.switch_tab(3)
for index,field in ipairs(require('lilyp.fields').list) do
  if field.tab==3 and field.id=='lyric_shape' then
    local selection=0
    for i=1,index do if require('lilyp.fields').list[i].tab==3 then selection=selection+1 end end
    state.selection=selection;break
  end
end
current=vim.deepcopy(state.session.draft)
assert(not state.undo_setting() and vim.deep_equal(current,state.session.draft),'Undo partially staged an unavailable font face')
state.close()
local custom=fs.stage(fs.snapshot(root..'/tests/fixtures'))
fs.write(custom..'/style.ily',fs.read(custom..'/style.ily')..'\nscoreLayout = \\layout { \\scoreLayout \\context { \\Lyrics \\override LyricText.font-name = "DejaVu Sans" } }\n')
s=require('lilyp.session').open(custom);local _,custom_yaml=s:render();s:close();fs.write(custom..'/score.yaml',custom_yaml)
state=ui.open(custom)
local draft=vim.deepcopy(state.session.draft)
assert(not state.apply_profile('large_print') and vim.deep_equal(draft,state.session.draft),'Custom font override was overwritten or partially staged')
state.close()
print('PASS: font faces/fractional sizing, coherent spacing catalog, physical staff separation, source preservation, batch rollback, scoped YAML/reset, compile/MIDI protection, and draft-only profiles')
print('Artifacts: '..artifact)
