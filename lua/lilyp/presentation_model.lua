-- Pure specification validation and inheritance. No filesystem, editor, or source rewriting.
local settings=require('lilyp.settings')
local M={}
local observation=require('lilyp.source_observation')
local diagnostic=require('lilyp.yaml_diagnostic')
function M.copy(value)
  if type(value)~='table' then return value end
  local result={};for key,item in pairs(value) do result[key]=M.copy(item) end;return result
end
local function mapping(value,label)
  assert(type(value)=='table',label..' must be a mapping')
  for key in pairs(value) do assert(type(key)=='string',label..' must use setting IDs') end
end
function M.validate_values(values,scope)
  mapping(values,'Settings')
  for id,value in pairs(values) do
    local definition=assert(settings.by_id[id],'Unknown specification setting: '..id)
    assert(definition.presentation~=false,id..': not supported in the presentation specification')
    settings.validate(id,value,scope)
  end
  settings.validate_values(values,scope)
end
function M.read(raw,style_path,section_ids)
  if raw==nil then return nil end
  local function check(condition,kind,path,message)
    if not condition then error(diagnostic.new(kind,path,message),0) end
  end
  local function explain(err)return (tostring(err):gsub('^.-:%d+: ',''))end
  local function checked_map(value,path,label)
    local ok,err=pcall(mapping,value,label)
    check(ok,'InvalidShape',path,explain(err))
  end
  local function setting_map(value,scope,path)
    checked_map(value,path,'Settings')
    for id,item in pairs(value) do
      local at=vim.list_extend(vim.deepcopy(path),{id})
      check(settings.by_id[id]~=nil,'UnknownField',at,'Unknown specification setting: '..id)
      local ok,err=pcall(M.validate_values,{[id]=item},scope)
      check(ok,'InvalidValue',at,explain(err))
    end
  end
  check(type(raw)=='table' and (raw.schema_version==1 or raw.schema_version==2),'UnsupportedVersion',{'presentation','schema_version'},'Unsupported presentation specification version')
  local allowed={schema_version=true,id=true,style=true,settings=true,custom_policy=true,owner=true}
  if raw.schema_version==2 then allowed.sections=true end
  for key in pairs(raw) do check(allowed[key],'UnknownField',{'presentation',key},'Unsupported presentation specification field: '..tostring(key)) end
  check(raw.style==style_path,'InvalidPath',{'presentation','style'},'Invalid presentation specification style path')
  check(raw.id==nil or type(raw.id)=='string' and raw.id~='','InvalidValue',{'presentation','id'},'Invalid presentation specification ID')
  check(raw.custom_policy==nil or raw.custom_policy=='preserve-in-place','InvalidValue',{'presentation','custom_policy'},'Unsupported custom-style policy')
  setting_map(raw.settings,'global',{'presentation','settings'})
  local sections={}
  if raw.schema_version==2 then
    checked_map(raw.sections,{'presentation','sections'},'Section presentations')
    local bindings={}
    for id,section in pairs(raw.sections) do
      local at={'presentation','sections',id}
      check(section_ids and section_ids[id],'MissingReference',at,'Unknown presentation section: '..id)
      checked_map(section,at,'Section presentation')
      for key in pairs(section) do check(key=='settings' or key=='layout','UnknownField',vim.list_extend(vim.deepcopy(at),{key}),'Unsupported section presentation field: '..key) end
      local layout_at=vim.list_extend(vim.deepcopy(at),{'layout'})
      check(type(section.layout)=='string' and section.layout:match('^[%a][%a%-]*$') and section.layout~='scoreLayout','InvalidValue',layout_at,'Invalid section layout binding')
      check(not bindings[section.layout],'DuplicateId',layout_at,'Duplicate section layout binding: '..section.layout);bindings[section.layout]=true
      setting_map(section.settings,'section',vim.list_extend(vim.deepcopy(at),{'settings'}))
      sections[id]={layout=section.layout,settings=M.copy(section.settings)}
    end
  end
  return {schema_version=raw.schema_version,id=raw.id or 'presentation-default',style=style_path,
    settings=M.copy(raw.settings),sections=sections,custom_policy='preserve-in-place'}
end
function M.resolve(defaults,overrides,section_id)
  M.validate_values(defaults,'global');M.validate_values(overrides or {},'section')
  local values,origins=M.copy(defaults),{}
  for id in pairs(defaults) do origins[id]={scope='global'} end
  for id,value in pairs(overrides or {}) do
    values[id]=M.copy(value);origins[id]={scope='section',section_id=section_id}
  end
  return {values=values,origins=origins}
end
function M.import(observed)
  local values={}
  for id,entry in pairs(observed) do if observation.assert_valid(entry).tag=='recognized' then values[id]=M.copy(entry.value) end end
  return values
end
function M.compare(declared,observed)
  local conflicts={}
  for id,value in pairs(declared) do
    local entry=observed[id]
    if not entry or entry.tag~='recognized' or entry.value~=value then
      conflicts[#conflicts+1]={id=id,scope='global',expected=M.copy(value),actual=observation.display_value(entry),
        status=entry and entry.tag or 'missing',location=observation.locate(entry) and {first=observation.locate(entry).first,last=observation.locate(entry).last}}
    end
  end
  table.sort(conflicts,function(a,b)return a.id<b.id end);return conflicts
end
return M
