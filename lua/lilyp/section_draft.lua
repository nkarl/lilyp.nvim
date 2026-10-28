-- Ephemeral section intent. YAML and source effects are projections, never draft state.
local model=require('lilyp.presentation_model')
local settings=require('lilyp.settings')
local M={}
local function scoped(id)
  local field=assert(settings.by_id[id],'Unknown section setting: '..tostring(id))
  assert(field.presentation~=false and vim.tbl_contains(field.scopes,'section'),id..': unsupported scope section')
end
function M.keep()return {tag='keep'}end
function M.inherit()return {tag='inherit'}end
function M.explicit(id,value)
  scoped(id);assert(value~=nil,'Explicit intent requires a value')
  settings.validate(id,value,'section')
  return {tag='explicit',value=value}
end
function M.assert_intent(id,intent)
  scoped(id)
  assert(type(intent)=='table','Section intent must be a tagged value')
  assert(intent.tag=='keep' or intent.tag=='explicit' or intent.tag=='inherit','Unknown section intent')
  for key in pairs(intent) do
    assert(key=='tag' or key=='value' and intent.tag=='explicit','Unexpected section intent payload')
  end
  if intent.tag=='explicit' then M.explicit(id,intent.value) end
  return intent
end
function M.new(layout,opening)
  assert(type(layout)=='string' and layout~='','Section draft requires a layout')
  model.validate_values(opening,'section')
  local intents={}
  for id,field in pairs(settings.by_id) do
    if field.presentation~=false and vim.tbl_contains(field.scopes,'section') then intents[id]=M.keep() end
  end
  return {layout=layout,opening=model.copy(opening),intents=intents}
end
function M.set(draft,id,intent)
  M.assert_intent(id,intent)
  assert(draft.intents[id],'Setting is absent from section intent contract')
  draft.intents[id]=model.copy(intent)
end
function M.resolve(draft,source,saved)
  source=source or {};saved=saved or {}
  local declared=model.copy(draft and draft.opening or source)
  local effective=model.copy(source)
  local removed,changed={},{}
  if draft then
    model.validate_values(draft.opening,'section')
    for id,intent in pairs(draft.intents) do
      M.assert_intent(id,intent)
      if intent.tag=='explicit' then declared[id]=intent.value
      elseif intent.tag=='inherit' then
        declared[id]=nil;effective[id]=nil
        -- Import candidates contain only recognized, editable local literals.
        if source[id]~=nil then removed[id]=true end
      end
    end
    for id,field in pairs(settings.by_id) do
      if field.presentation~=false and vim.tbl_contains(field.scopes,'section') then
        assert(draft.intents[id],'Missing section intent: '..id)
        if declared[id]~=saved[id] or removed[id] and saved[id]==nil then changed[id]=true end
      end
    end
  end
  model.validate_values(declared,'section')
  for id,value in pairs(declared) do effective[id]=value end
  return {layout=draft and draft.layout,settings=declared,effective=effective,removed=removed,changed=changed}
end
return M
