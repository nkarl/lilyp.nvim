local root=vim.fn.fnamemodify(debug.getinfo(1,'S').source:sub(2),':p:h:h')
vim.opt.rtp:prepend(root)
local inspection=require('lilyp.inspection')
local legacy=require('lilyp.inspection_legacy')
local fs=require('lilyp.fs')
local duration={denominator=8,dots=1,notation='8.',inherited=false}
local rhythmic={first=10,last=11,duration=duration,tuplets={},grace=false}
local note=vim.tbl_extend('force',rhythmic,{written_pitch='c',absolute_pitch="c'",pitch='C4',midi=60,mode='relative',anchor="c'",chord_member=1,chord_size=1})
local examples={
  note=note,rest=rhythmic,skip=rhythmic,
  lyric={form='syllable',text='Người <img src=x>',definition='verseOne',stanza='1.'},
  chord={form='name',written='d1*2/4:m/a',duration={notation='1*2/4',inherited=true},root='D',modifier='m',bass='A'},
  dynamic={name='Dynamic marking',notation='\\mf',meaning='Mezzo forte'},
  articulation={name='Staccato',notation='-.'},
  beam={name='Beam start',notation='[',direction='Above'},
  slur={name='Slur start',notation='(',direction='Below'},
  tie={name='Tie',notation='~'},
  key={form='literal',written='bes \\major',key='B♭ major'},
  meter={meter='3/4',command='\\time'},tuplet={ratio='3/2',command='\\tuplet'},
  tempo={text='Vui hoạt',beat_unit='4.',bpm='90'},
  ['repeat']={repeat_type='volta',count=2},alternative={ending=2},
  grace={command='\\slashedGrace'},pitch_context={mode='fixed',anchor="c'"},
  barline={style='|.'},clef={clef='treble'},pickup={duration='8.'},
  mark={form='score',mark='\\markup \\musicglyph "scripts.segno"',glyph='Segno'},layout={command='\\break'},
}
local required={
  note={'first','last','written_pitch','absolute_pitch','pitch','midi','mode','duration','tuplets','chord_member','chord_size','grace'},
  rest={'first','last','duration','tuplets','grace'},skip={'first','last','duration','tuplets','grace'},
  lyric={'form','text'},chord={'form','written','duration'},dynamic={'name','notation'},articulation={'name','notation'},
  beam={'name','notation'},slur={'name','notation'},tie={'name','notation'},key={'form'},
  meter={'meter','command'},tuplet={'ratio','command'},tempo={},['repeat']={'repeat_type','count'},alternative={},
  grace={'command'},pitch_context={'mode'},barline={'style'},clef={'clef'},pickup={'duration'},mark={'form','mark'},layout={'command'},
}
local results={}
for _,kind in ipairs(inspection.kinds) do
  local detail=assert(examples[kind],'Missing contract example for '..kind)
  local result=inspection.supported(kind,detail)
  assert(inspection.valid(result) and result.symbol.kind==kind)
  assert(vim.deep_equal(result,inspection.normalize(vim.json.decode(vim.json.encode(result)))))
  local invalid=vim.deepcopy(detail);invalid.wrong_variant_field='not allowed'
  assert(not pcall(inspection.supported,kind,invalid),'Constructor accepted an extra field for '..kind)
  for _,key in ipairs(assert(required[kind])) do
    local missing=vim.deepcopy(detail);missing[key]=nil
    assert(not pcall(inspection.supported,kind,missing),'Constructor accepted missing '..kind..'.'..key)
  end
  results[#results+1]=result
end
for _,invalid in ipairs({{}, {tag='future'}, {tag='unsupported',reason='internal diagnostics'},
  {tag='supported',symbol={kind='future'}}, {tag='supported',symbol={kind='note'}},
  {tag='supported',symbol={kind='rest',pitch='C4'}},
  {tag='supported',symbol={kind='tempo',beat_unit='4'}},
  {tag='supported',symbol={kind='chord',form='name',written='c',duration={notation='4',inherited=true},bass='G'}}}) do
  assert(not inspection.valid(invalid))
  assert(vim.deep_equal(inspection.normalize(invalid),{tag='unsupported'}))
end
assert(not pcall(inspection.supported,'future',{}))
assert(not pcall(inspection.supported,'note',vim.tbl_extend('force',note,{chord_member=2})))
assert(not pcall(inspection.supported,'note',vim.tbl_extend('force',note,{anchor=false})))
assert(not pcall(inspection.supported,'rest',vim.tbl_extend('force',rhythmic,{tuplets={bad=true}})))
assert(not pcall(inspection.supported,'rest',vim.tbl_extend('force',rhythmic,{tuplets=vim.empty_dict()})))
assert(not pcall(inspection.choose,{},inspection.unsupported()))
assert(inspection.choose(inspection.supported('note',note),inspection.supported('tie',examples.tie)).symbol.kind=='note')
assert(inspection.choose(inspection.unsupported(),inspection.supported('tie',examples.tie)).symbol.kind=='tie')
-- Optional forms remain explicit valid variants rather than partial notes.
for _,example in ipairs({
  {'alternative',{}}, {'tempo',{text='Calm'}}, {'key',{form='literal',written='b \\major'}},
  {'key',{form='alias',alias='\\partKey',key='G major'}},
  {'chord',{form='skip',written='s2',duration={notation='2',inherited=false}}},
  {'lyric',{form='stanza',text='"1."'}}, {'mark',{form='end',mark='"D.C."'}},
}) do results[#results+1]=inspection.supported(example[1],example[2]) end
local source={kind='token',available=true,path='part.ily',line=1,column=3,before='c ',focus='text',after=' d'}
local excerpt=legacy.origin(source)
assert(excerpt.inspection.tag=='unsupported' and excerpt.focus==source.focus)
local malformed=legacy.origin(vim.tbl_extend('force',source,{inspection={tag='supported',symbol={kind='future'}},music=vim.tbl_extend('force',note,{status='resolved',event_type='note'})}))
assert(malformed.inspection.tag=='unsupported' and malformed.music==nil)
local raw=vim.json.encode(source)
legacy.origin(source);assert(vim.json.encode(source)==raw,'Legacy normalization mutated the input')
-- The actual card renderer must cover exactly the Lua constructors. Its legacy
-- display output also exercises the cached-manifest adapter for every variant.
if vim.fn.executable('node')==1 then
  local folder=vim.fn.tempname();vim.fn.mkdir(folder,'p')
  fs.write(folder..'/inspection.json',vim.json.encode({kinds=inspection.kinds,results=results}))
  local run=vim.system({'node',root..'/tests/inspection-renderers.mjs',folder..'/inspection.json',folder..'/legacy.json'},{text=true}):wait(10000)
  assert(run.code==0,(run.stdout or '')..(run.stderr or ''))
  local old=vim.json.decode(fs.read(folder..'/legacy.json'))
  assert(#old==#results)
  for n,origin in ipairs(old) do
    local normalized=legacy.origin(origin)
    assert(vim.deep_equal(normalized.inspection,results[n]),vim.inspect({actual=normalized.inspection,expected=results[n]}))
    assert(normalized.music==nil and normalized.symbol==nil)
  end
  print(vim.trim(run.stdout))
else print('SKIP: optional Node renderer contract check (node unavailable)') end
print('PASS: validated sum type, variant invariants, malformed/future data refusal, legacy normalization, and source-preview preservation')
