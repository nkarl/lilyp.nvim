-- Validated setting observations. Transformations return fresh records. Only
-- Recognized carries an
-- editable typed value; Custom retains diagnostic evidence, never edit authority.
local settings=require('lilyp.settings')
local M={}
local function text(v)return type(v)=='string' and v~='' end
local function integer(v)return type(v)=='number' and v%1==0 and v>=0 end
local function keys(value,allowed)
  assert(type(value)=='table','Expected an observation record')
  for key in pairs(value) do assert(allowed[key],'Unexpected observation field: '..tostring(key)) end
end
local messages={
  Nonliteral=function()return 'Not a unique supported literal setting' end,
  InvalidLiteral=function(c)return c.detail end,
  CompoundSpacing=function()return 'Compound spacing expression controls this relationship' end,
  ExplicitFontFace=function()return 'Explicit font-name controls face selection' end,
  UnsupportedScope=function()return 'Not available in section scope' end,
  AdditionalAssignment=function(c)return 'Additional styling assignment in '..c.path end,
  SectionUnavailable=function(c)return c.detail end,
}
function M.cause(kind,detail)
  assert(messages[kind],'Unknown observation cause: '..tostring(kind))
  local result=vim.tbl_extend('force',detail or {},{kind=kind})
  keys(result,{kind=true,detail=kind=='InvalidLiteral' or kind=='SectionUnavailable',path=kind=='AdditionalAssignment'})
  if kind=='InvalidLiteral' or kind=='SectionUnavailable' then assert(text(result.detail),'Missing diagnostic detail') end
  if kind=='AdditionalAssignment' then assert(text(result.path),'Missing assignment path') end
  return vim.deepcopy(result)
end
local function span(value,literal)
  keys(value,{first=true,last=true,raw=literal,display=literal})
  assert(integer(value.first) and value.first>0 and integer(value.last) and value.last>=value.first,'Invalid source span')
  if literal then
    assert(type(value.raw)=='string','Missing literal source text')
    assert(value.display==nil or type(value.display)=='string','Invalid diagnostic display value')
  end
end
local function check_context(context)
  keys(context,{scope=true,path=true,binding=true})
  assert(context.scope=='global' or context.scope=='section','Invalid observation scope')
  assert(context.path==nil or text(context.path),'Invalid observation path')
  assert(context.binding==nil or context.scope=='section' and text(context.binding),'Invalid layout binding')
end
local function check_evidence(evidence)
  keys(evidence,{assignments=true,location=true,font_override=true})
  assert(integer(evidence.assignments),'Invalid assignment count')
  if evidence.location then span(evidence.location,true) end
  if evidence.font_override then span(evidence.font_override,false) end
end
function M.assert_valid(entry)
  assert(type(entry)=='table' and settings.by_id[entry.id],'Unknown observed setting')
  check_context(entry.context);check_evidence(entry.evidence)
  if entry.tag=='recognized' then
    keys(entry,{tag=true,id=true,value=true,location=true,evidence=true,context=true})
    span(entry.location,true);assert(entry.location.display==nil,'Recognized source span is not diagnostic display data')
    settings.validate(entry.id,entry.value,entry.context.scope)
    assert(entry.evidence.assignments==1 and not entry.evidence.font_override,'Recognized setting must be a unique unblocked literal')
  elseif entry.tag=='available' then
    keys(entry,{tag=true,id=true,insertion=true,evidence=true,context=true})
    keys(entry.insertion,{kind=true,at=true})
    local kind=entry.insertion.kind
    assert(kind=='paper' or kind=='score_layout' or kind=='section_layout','Invalid insertion recipe')
    assert((entry.context.scope=='section')==(kind=='section_layout'),'Insertion scope mismatch')
    assert(entry.insertion.at==nil or integer(entry.insertion.at) and entry.insertion.at>0,'Invalid insertion offset')
    assert(entry.evidence.assignments==0 and not entry.evidence.font_override,'Available setting has blocking source evidence')
  elseif entry.tag=='custom' then
    keys(entry,{tag=true,id=true,cause=true,evidence=true,context=true})
    assert(vim.deep_equal(entry.cause,M.cause(entry.cause.kind,entry.cause)),'Invalid custom cause')
  else error('Unknown source observation variant: '..tostring(entry.tag)) end
  return entry
end
local function construct(tag,id,payload,evidence,context)
  local entry=vim.tbl_extend('force',payload,{tag=tag,id=id,evidence=vim.deepcopy(evidence or {assignments=0}),context=vim.deepcopy(context or {scope='global'})})
  return M.assert_valid(vim.deepcopy(entry))
end
function M.recognized(id,value,location,evidence,context)
  return construct('recognized',id,{value=value,location=location},evidence,context)
end
function M.available(id,insertion,evidence,context)
  return construct('available',id,{insertion=insertion},evidence,context)
end
function M.custom(id,cause,evidence,context)
  return construct('custom',id,{cause=cause},evidence,context)
end
function M.block(entry,cause)
  M.assert_valid(entry)
  local evidence=vim.deepcopy(entry.evidence)
  if entry.tag=='recognized' then
    evidence.location=vim.deepcopy(entry.location);evidence.location.display=tostring(entry.value)
  end
  return M.custom(entry.id,cause,evidence,entry.context)
end
function M.locate(entry)
  if not entry then return nil end
  return entry.tag=='recognized' and entry.location or entry.evidence.location
end
function M.display_value(entry)
  if not entry then return nil end
  if entry.tag=='recognized' then return entry.value end
  local location=M.locate(entry);return location and location.display
end
function M.reason(entry)
  if not entry then return nil end
  if entry.tag=='custom' then return assert(messages[entry.cause.kind])(entry.cause) end
  if entry.tag=='available' then return 'Not declared; editing adds an explicit presentation override' end
  assert(entry.tag=='recognized','Unknown source observation variant')
end
function M.editable(entry)
  M.assert_valid(entry)
  return entry.tag=='recognized' or entry.tag=='available'
end
function M.font_override(entry)return entry.evidence.font_override~=nil end
function M.with_context(entry,context,offset,insertion_at)
  M.assert_valid(entry)
  local copy=vim.deepcopy(entry)
  copy.context=vim.tbl_extend('force',copy.context,context or {})
  for _,location in ipairs({copy.location or false,copy.evidence.location or false,copy.evidence.font_override or false}) do
    if location and offset then location.first=location.first+offset;location.last=location.last+offset end
  end
  if copy.tag=='available' then
    if copy.insertion.at and offset then copy.insertion.at=copy.insertion.at+offset end
    if insertion_at then copy.insertion.at=insertion_at end
  end
  return M.assert_valid(copy)
end
return M
