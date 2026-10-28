-- Section layout discovery is a separate sum type from setting observations:
-- Named | Inline | Unavailable. Failed discovery cannot retain editable layouts.
local observation=require('lilyp.source_observation')
local M={}
local function text(v)return type(v)=='string' and v~='' end
local messages={
  UnparsedSources=function(c)return 'Cannot inspect section layouts; finish the source blocks and Reload. '..c.detail end,
  MissingSource=function()return 'Section source is missing' end,
  PrintedScoreAmbiguous=function()return 'Expected one printed score referencing this section’s source variables' end,
  AdditionalPrintedStyling=function()return 'Printed layout contains additional styling beside its named binding' end,
  ExtraReferences=function()return 'Section layout binding has additional references' end,
  MissingInheritance=function()return 'Section layout must reference scoreLayout exactly once' end,
  NameCollision=function(c)return 'Section layout name already exists: '..c.detail end,
  SharedPrintedScore=function()return 'Printed score references multiple declared sections' end,
  SharedLayout=function()return 'Sections share a layout binding' end,
  InvalidLayout=function(c)return c.detail end,
}
function M.cause(kind,detail)
  assert(messages[kind],'Unknown binding cause: '..tostring(kind))
  if kind=='UnparsedSources' or kind=='InvalidLayout' or kind=='NameCollision' then assert(text(detail),'Missing binding diagnostic detail')
  else assert(detail==nil,'Unexpected binding diagnostic detail') end
  return {kind=kind,detail=detail}
end
function M.reason(entry)
  if entry.tag=='unavailable' then return assert(messages[entry.cause.kind])(entry.cause) end
  assert(entry.tag=='named' or entry.tag=='inline','Unknown binding variant')
end
local function span(v)
  return type(v)=='table' and type(v.first)=='number' and type(v.close)=='number' and v.first>=1 and v.close>=v.first
end
function M.assert_valid(entry)
  assert(type(entry)=='table' and text(entry.id) and type(entry.name)=='string','Invalid binding identity')
  local allowed={tag=true,id=true,name=true}
  if entry.tag=='unavailable' then
    allowed.cause=true;allowed.evidence=true
    assert(vim.deep_equal(entry.cause,M.cause(entry.cause.kind,entry.cause.detail)),'Invalid binding cause')
    assert(type(entry.evidence)=='table','Missing binding evidence')
    for key,value in pairs(entry.evidence) do
      assert(key=='path' and text(value) or key=='layout' and text(value) or key=='printed' and type(value)=='table','Invalid binding evidence')
    end
  elseif entry.tag=='named' or entry.tag=='inline' then
    for _,key in ipairs({'layout','path','observed','printed','import_candidate'}) do allowed[key]=true end
    assert(text(entry.layout) and text(entry.path),'Missing layout binding')
    assert(type(entry.observed)=='table' and type(entry.observed.source)=='string' and span(entry.observed.region),'Missing bounded observation')
    assert(type(entry.printed)=='table' and text(entry.printed.path) and span(entry.printed.layout),'Missing printed layout')
    assert(type(entry.observed.entries)=='table' and type(entry.import_candidate)=='table','Missing layout settings')
    for id,value in pairs(entry.observed.entries) do
      observation.assert_valid(value);assert(value.id==id,'Observed setting mismatch')
      assert(value.context.path==entry.path and value.context.binding==entry.layout,'Observation binding context mismatch')
      if value.tag=='recognized' then assert(entry.import_candidate[id]==value.value,'Missing imported observation') end
    end
    for id,value in pairs(entry.import_candidate) do
      local setting=assert(entry.observed.entries[id]);assert(setting.tag=='recognized' and setting.value==value,'Invalid imported observation')
    end
  else error('Unknown source binding variant: '..tostring(entry.tag)) end
  for key in pairs(entry) do assert(allowed[key],'Unexpected binding field: '..tostring(key)) end
  return entry
end
function M.bound(tag,id,name,detail)
  assert(tag=='named' or tag=='inline','Invalid bound variant')
  return M.assert_valid(vim.tbl_extend('force',vim.deepcopy(detail),{tag=tag,id=id,name=name}))
end
function M.unavailable(id,name,cause,evidence)
  return M.assert_valid({tag='unavailable',id=id,name=name,cause=vim.deepcopy(cause),evidence=vim.deepcopy(evidence or {})})
end
function M.available(entry)
  M.assert_valid(entry)
  return entry.tag=='named' or entry.tag=='inline'
end
function M.reject(entry,cause)
  M.assert_valid(entry)
  local evidence=entry.tag=='unavailable' and entry.evidence or {path=entry.path,layout=entry.layout,printed=entry.printed}
  return M.unavailable(entry.id,entry.name,cause,evidence)
end
function M.path(entry)return entry.tag=='unavailable' and entry.evidence.path or entry.path end
return M
