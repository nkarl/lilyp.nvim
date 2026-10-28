-- Canonical presentation semantics; independent of UI, YAML transport, and source syntax.
local M={}
M.list={
  {kind="number",id="staff_size",max=40,min=8,scopes={"global","section"},default=15},
  {kind="string",id="paper",choices={"a4","letter"},scopes={"global"}},
  {kind="number",id="top_margin",max=100,min=0,scopes={"global"},unit="mm"},
  {kind="number",id="bottom_margin",max=100,min=0,scopes={"global"},unit="mm"},
  {kind="number",id="left_margin",max=100,min=0,scopes={"global"},unit="mm"},
  {kind="number",id="right_margin",max=100,min=0,scopes={"global"},unit="mm"},
  {kind="number",id="page_count",integer=true,min=1,max=20,scopes={"global"}},
  {kind="number",id="title_size",max=12,min=-6,scopes={"global"},unit="font-step",default=5},
  {kind="number",id="subtitle_size",max=12,min=-6,scopes={"global"},unit="font-step",default=3},
  {kind="symbol",id="subtitle_shape",choices={"italic","upright"},scopes={"global"},default="upright"},
  {kind="number",id="composer_size",max=12,min=-6,scopes={"global"},unit="font-step",default=0},
  {kind="string",id="lyric_font",scopes={"global","section"},default="LilyPond Serif"},
  {kind="number",id="lyric_size",max=6,min=-6,scopes={"global","section"},unit="font-step",default=2},
  {kind="symbol",id="lyric_shape",choices={"italic","upright","oblique","slanted"},scopes={"global","section"},default="upright"},
  {kind="number",id="word_spacing",max=20,min=0,scopes={"global","section"},default=2},
  {kind="number",id="stanza_size",max=6,min=-6,scopes={"global","section"},unit="font-step"},
  {kind="symbol",id="stanza_shape",choices={"italic","upright"},scopes={"global","section"}},
  {kind="number",id="row_spacing",max=20,min=0,scopes={"global","section"}},
  {kind="string",id="odd_color",color=true,scopes={"global"},default="#00007f"},
  {kind="string",id="even_color",color=true,scopes={"global"},default="#55007f"},
  {kind="number",id="header_gap",max=30,min=0,scopes={"global"}},
  {kind="number",id="section_gap",max=40,min=0,scopes={"global"},default=1},
  {kind="number",id="chord_size",max=6,min=-6,scopes={"global","section"},unit="font-step",default=0.5},
  {kind="number",id="chord_padding",max=20,min=0,scopes={"global","section"},default=2},
  {kind="boolean",id="ragged_last_bottom",choices={false,true},scopes={"global"}},
  {kind="boolean",id="hide_tempo_note",choices={false,true},scopes={"global","section"}},
  {kind="string",id="metronome_color",color=true,scopes={"global"}},
  {kind="string",id="rehearsal_color",color=true,scopes={"global"}},
  {kind="string",id="text_mark_color",color=true,scopes={"global"}},
  {kind="number",id="indent",min=0,max=100,scopes={"global","section"},unit="mm"},
  {kind="number",id="short_indent",min=0,max=100,scopes={"global","section"},unit="mm"},
  {id="numeric_time",presentation=false,kind="boolean",scopes={"global"},default=true},
  {id="inner_note_size",presentation=false,kind="number",min=-6,max=0,unit="font-step",scopes={"global"},default=-2},
}
M.list[#M.list+1]={kind='symbol',id='lyric_weight',choices={'normal','medium','semibold','bold','thin','ultralight','light','semilight','book','ultrabold','heavy','ultraheavy',
  'regular','extralight','demilight','demibold','extrabold','black','ultrablack','extrablack'},scopes={'global','section'}}
for _,relationship in ipairs(require('lilyp.spacing')) do
  for _,part in ipairs({'distance','minimum','padding','stretch'}) do
    local id=part=='distance' and relationship.preferred or nil
    id=id or relationship.id..'_'..part
    if id~='row_spacing' then
      M.list[#M.list+1]={id=id,kind='number',min=0,max=part=='stretch' and 10000 or 100,
        scopes=relationship.scopes,unit=part=='stretch' and 'ratio' or 'staff-space',step=part=='stretch' and 1 or 0.5,
        advanced=part=='minimum' or part=='stretch',spacing=relationship.id}
    end
  end
end
M.by_id={}
for _,definition in ipairs(M.list) do
  if definition.unit=='font-step' then definition.step=0.25 end
  if definition.id=='staff_size' then definition.unit='pt';definition.step=0.5 end
  if definition.id=='row_spacing' then definition.unit='staff-space';definition.step=0.5;definition.spacing='row';definition.max=100 end
  assert(not M.by_id[definition.id],'Duplicate presentation setting ID: '..definition.id)
  M.by_id[definition.id]=definition
end
local function contains(items,value)
  for _,item in ipairs(items) do if item==value then return true end end
  return false
end
function M.validate(id,value,scope)
  local f=assert(M.by_id[id],'Unknown presentation setting: '..tostring(id))
  assert(contains(f.scopes,scope or 'global'),id..': unsupported scope '..tostring(scope))
  if f.kind=='number' then
    assert(type(value)=='number' and value==value and value>=f.min and value<=f.max,id..': expected '..f.min..'–'..f.max)
  elseif f.kind=='boolean' then assert(type(value)=='boolean',id..': expected a boolean')
  else assert(type(value)=='string' and value:find('%S') and not value:find('[%z\r\n\\"]'),id..': invalid text') end
  if f.integer then assert(value==math.floor(value),id..': expected an integer') end
  if f.choices then assert(contains(f.choices,value),id..': unsupported choice') end
  if f.color then assert(value:match('^#%x%x%x%x%x%x$'),id..': use #RRGGBB') end
  return value
end
function M.validate_values(values,scope)
  assert(type(values)=='table','Expected a settings mapping')
  for id,value in pairs(values) do M.validate(id,value,scope) end
  -- These are independent LilyPond constraints: distances use reference points,
  -- while padding measures visible edges. The engraver resolves their interaction.
  return values
end
function M.adjust(id,value,delta)
  local f=assert(M.by_id[id])
  local result=(value==nil and f.min or value)+delta*(f.step or 1)
  return math.max(f.min,math.min(f.max,math.floor(result*1000000+0.5)/1000000))
end
for _,definition in ipairs(M.list) do
  if definition.default~=nil then M.validate(definition.id,definition.default,'global') end
end
return M
