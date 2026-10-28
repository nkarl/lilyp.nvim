-- Pure normalization of consumed YAML fields. No filesystem checks or writes.
local model=require('lilyp.presentation_model')
local diagnostic=require('lilyp.yaml_diagnostic')
local M={}
local function absent(value)return value==nil or value==vim.NIL end
local function append(path,key)local result=vim.deepcopy(path);result[#result+1]=key;return result end
function M.validate(metadata,text)
  local locations=metadata._yaml and metadata._yaml.locations or {}
  local diagnostics={}
  local function reject(kind,path,message,part)
    diagnostics[#diagnostics+1]=diagnostic.new(kind,path,message,locations,part)
  end
  local function mapping(value,path)
    if type(value)~='table' or vim.islist(value) and next(value)~=nil then
      reject('InvalidShape',path,'Expected a mapping');return false
    end
    for key in pairs(value) do
      if type(key)~='string' then reject('InvalidShape',path,'Mapping keys must be strings');return false end
    end
    return true
  end
  local function sequence(value,path)
    if type(value)~='table' or not vim.islist(value) and next(value)~=nil then
      reject('InvalidShape',path,'Expected a list');return false
    end
    return true
  end
  local function path(value,at)
    if type(value)~='string' or value=='' or value:find('%z') or value:match('^/') then
      reject('InvalidPath',at,'Expected a relative project path');return false
    end
    local depth=0
    for part in value:gmatch('[^/]+') do
      if part=='..' then depth=depth-1 elseif part~='.' then depth=depth+1 end
      if depth<0 then reject('InvalidPath',at,'Path escapes the project');return false end
    end
    if depth==0 then reject('InvalidPath',at,'Expected a project file path');return false end
    return true
  end
  local function voice_list(value,at)
    if not sequence(value,at) then return end
    for index,voice in ipairs(value) do
      local item_at=append(at,index)
      if mapping(voice,item_at) then
        for _,id in ipairs({'id','instrument','playback_voice'}) do
          if not absent(voice[id]) and type(voice[id])~='string' then
            reject('InvalidValue',append(item_at,id),'Voice '..id..' must be text')
          end
        end
      end
    end
  end
  local header=metadata._yaml or {}
  if header.kind~='lilypond-score' then reject('InvalidKind',{'kind'},'Expected a lilypond-score YAML document') end
  local version=absent(header.schema_version) and 1 or header.schema_version
  if version~=1 then reject('UnsupportedVersion',{'schema_version'},'Unsupported project schema version: '..tostring(version)) end
  local source=absent(metadata.source) and {} or metadata.source
  local normalized_source={main='main.ly',style='style.ily'}
  if mapping(source,{'source'}) then
    for _,id in ipairs({'main','style'}) do
      if not absent(source[id]) then normalized_source[id]=source[id] end
      path(normalized_source[id],{'source',id})
    end
  end
  local sections,ids={},{}
  local raw_sections=absent(metadata.sections) and {} or metadata.sections
  if sequence(raw_sections,{'sections'}) then
    for index,section in ipairs(raw_sections) do
      local at={'sections',index}
      if mapping(section,at) then
        local id=section.id
        if type(id)~='string' or id=='' then reject('InvalidValue',append(at,'id'),'Missing or duplicate section ID: expected a nonempty string')
        elseif ids[id] then reject('DuplicateId',append(at,'id'),'Missing or duplicate section ID: '..id)
        else ids[id]=true end
        if not absent(section.source) then path(section.source,append(at,'source')) end
        for _,field in ipairs({'name','type','staff_preset'}) do
          if not absent(section[field]) and type(section[field])~='string' then reject('InvalidValue',append(at,field),'Section '..field..' must be text') end
        end
        if not absent(section.verses) and not (type(section.verses)=='number' and section.verses>=0 and section.verses%1==0) then
          reject('InvalidValue',append(at,'verses'),'Lyric row count must be a nonnegative integer')
        end
        if not absent(section.voices) then voice_list(section.voices,append(at,'voices')) end
        local normalized=vim.deepcopy(section)
        for _,id in ipairs({'source','name','type','verses','staff_preset','voices'}) do
          if absent(normalized[id]) then normalized[id]=nil end
        end
        sections[#sections+1]=normalized
      end
    end
  end
  local outputs=absent(metadata.outputs) and {} or metadata.outputs
  local output={tag='inherited',declarations={}}
  if mapping(outputs,{'outputs'}) then
    output.declarations=vim.deepcopy(outputs)
    if not absent(outputs.location) then
      if outputs.location~='project' and outputs.location~='temporary' then
        reject('InvalidValue',{'outputs','location'},'build_location must be temporary or project')
      else output={tag='explicit',value=outputs.location,declarations=vim.deepcopy(outputs)} end
    end
  end
  local presentation={tag='absent'}
  if not absent(metadata.presentation) then
    local ok,value=pcall(model.read,metadata.presentation,normalized_source.style,ids)
    if not ok then
      if diagnostic.is(value) then diagnostics[#diagnostics+1]=diagnostic.at(value,locations)
      else reject('InvalidPresentation',{'presentation'},tostring(value)) end
    else
      presentation={tag='specified',value=value,metadata_cleanup=metadata.presentation.owner~=nil}
    end
  end
  local order=absent(metadata.printed_order) and {} or metadata.printed_order
  if sequence(order,{'printed_order'}) then
    for index,id in ipairs(order) do if type(id)~='string' then reject('InvalidValue',{'printed_order',index},'Printed section IDs must be strings') end end
  end
  local voices=absent(metadata.voices) and {} or metadata.voices
  voice_list(voices,{'voices'})
  local staff_preset=metadata.staff_preset
  if absent(staff_preset) then staff_preset=nil
  elseif type(staff_preset)~='string' then reject('InvalidValue',{'staff_preset'},'Staff preset must be text') end
  if #diagnostics>0 then return {tag='invalid',diagnostics=diagnostics} end
  return {tag='valid',document={tag='project_document',schema_version=version,text=text,locations=vim.deepcopy(locations),
    source=normalized_source,sections=sections,section_ids=ids,outputs=output,presentation=presentation,
    printed_order=vim.deepcopy(order),voices=vim.deepcopy(voices),staff_preset=staff_preset}}
end
function M.from_parse(metadata,text)
  if metadata._error then
    local raw=metadata._error
    local value=diagnostic.new(raw.kind,raw.path,raw.message)
    value.location=vim.deepcopy(raw.location)
    return {tag='invalid',diagnostics={value}}
  end
  return M.validate(metadata,text)
end
function M.assert_valid(value)
  assert(type(value)=='table' and value.tag=='project_document','Expected a validated project document')
  assert(value.schema_version==1 and type(value.text)=='string' and type(value.locations)=='table','Invalid document provenance')
  assert(type(value.source)=='table' and type(value.source.main)=='string' and type(value.source.style)=='string','Invalid document source')
  assert(type(value.sections)=='table' and type(value.section_ids)=='table','Invalid document sections')
  assert(type(value.outputs)=='table' and type(value.outputs.declarations)=='table','Invalid output declaration')
  assert(value.outputs.tag=='inherited' or value.outputs.tag=='explicit' and (value.outputs.value=='project' or value.outputs.value=='temporary'),'Invalid output contract')
  assert(type(value.presentation)=='table' and (value.presentation.tag=='absent' or value.presentation.tag=='specified' and type(value.presentation.value)=='table'),'Invalid presentation contract')
  return value
end
return M
