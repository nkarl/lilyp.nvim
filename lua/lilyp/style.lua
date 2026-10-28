local fields = require('lilyp.fields')
local M = {}

local regions=require('lilyp.source_regions')
local bindings=require('lilyp.style_bindings')
local settings=require('lilyp.settings')
local observation=require('lilyp.source_observation')
M.code_positions=regions.code_positions

local function positioned(pattern)
  local first,last,i= nil,nil,1
  while i<=#pattern do
    local c=pattern:sub(i,i)
    if c=='%' then i=i+1
    elseif c=='(' and not first then first=i
    elseif c==')' and first then last=i;break end
    i=i+1
  end
  assert(first and last,'Expected one capture in field pattern')
  return pattern:sub(1,first-1)..'()'..pattern:sub(first,last)..'()'..pattern:sub(last+1)
end

local function inspect(text,scope)
  local result,positions={},regions.code_positions(text)
  local contexts=regions.blocks(text,'context')
  local function code_start(at) return positions[at] and not text:sub(at-1,at-1):match('[%w_%-]') end
  for _,base in ipairs(fields.list) do
    local f=vim.tbl_extend('force',base,bindings.for_scope(base.id,scope or 'global'))
    local function applicable(at)
      if not f.inspect_context then return true end
      for _,context in ipairs(contexts) do
        if at>=context.body_first and at<=context.body_last then
          local name=text:sub(context.body_first,context.body_last):match('^%s*\\([%a]+)')
          if name=='Lyrics' or name=='ChordNames' then return name==f.context end
        end
      end
      return true -- Unbound/custom assignments remain conservative observations.
    end
    local matches,start={},1
    local pattern=positioned(f.pattern)
    while true do
      local a,b,left,raw,right=text:find(pattern,start)
      if not a then break end
      if code_start(a) and applicable(a) then matches[#matches+1]={first=left,last=right-1,raw=raw} end
      start=b+1
    end
    local eq=f.pattern:find('%s*=',1,true)
    local anchor=eq and (f.pattern:sub(1,eq-1)..'%s*=')
      or f.anchor
      or (f.id=='staff_size' and '#%(set%-global%-staff%-size')
      or (f.id=='paper' and '#%(set%-paper%-size')
    local assignments=0
    if anchor then
      start=1
      while true do
        local a,b=text:find(anchor,start);if not a then break end
        if code_start(a) and applicable(a) then assignments=assignments+1 end
        start=b+1
      end
    end
    local cause=observation.cause('Nonliteral')
    local value,location,insertion
    local evidence={assignments=assignments}
    if #matches==1 and assignments==1 then
      location=matches[1]
      local ok,parsed=pcall(function()
        if f.kind=='boolean' then
          local v=location.raw=='##t';fields.validate(f,v);return v
        end
        local v=f.kind=='string' and vim.json.decode(location.raw) or (f.kind=='number' and tonumber(location.raw) or location.raw)
        fields.validate(f,v);return v
      end)
      if ok then value=parsed;cause=nil
      else cause=observation.cause('InvalidLiteral',{detail=tostring(parsed)}) end
    elseif assignments==0 and (f.id:match('_margin$') or f.paper or f.layout or f.setting or f.layout_function) then
      if scope=='section' or not (f.layout or f.setting) or text:find('scoreLayout%s*=%s*\\layout%s*{') then
        insertion={kind=scope=='section' and 'section_layout' or (f.layout or f.setting) and 'score_layout' or 'paper'}
        cause=nil
      end
    end
    if f.spacing_parent then
      local cursor=1
      while true do
        local a,b=text:find(f.spacing_parent..'%s*=',cursor);if not a then break end
        if code_start(a) and applicable(a) then cause=observation.cause('CompoundSpacing');break end
        cursor=b+1
      end
    end
    local grob=(f.id=='lyric_font' or f.id=='lyric_shape' or f.id=='lyric_weight') and 'LyricText'
      or (f.id=='stanza_shape' and 'StanzaNumber')
    if grob then
      local cursor=1
      while true do
        local a,b=text:find(grob..'%.font%-name%s*=',cursor);if not a then break end
        if code_start(a) then
          evidence.font_override={first=a,last=b};cause=observation.cause('ExplicitFontFace');break
        end
        cursor=b+1
      end
    end
    if scope=='section' then
      local supported=false
      for _,allowed in ipairs(settings.by_id[f.id].scopes) do if allowed=='section' then supported=true end end
      if not supported then cause=observation.cause('UnsupportedScope') end
    end
    local entry
    local context={scope=scope}
    if cause then
      if location then
        evidence.location=vim.deepcopy(location)
        if value~=nil then evidence.location.display=tostring(value) end
      end
      entry=observation.custom(f.id,cause,evidence,context)
    elseif insertion then entry=observation.available(f.id,insertion,evidence,context)
    else entry=observation.recognized(f.id,value,location,evidence,context) end
    result[f.id]=entry
  end
  return result
end

function M.inspect(text)return inspect(text,'global')end

function M.inspect_layout(text,binding)
  local region=regions.layout(text,binding)
  local entries=inspect(text:sub(region.body_first,region.body_last),'section')
  for id,entry in pairs(entries) do
    entries[id]=observation.with_context(entry,{scope='section',binding=binding},region.body_first-1,region.close)
  end
  return {entries=entries,region=region,source=text}
end

function M.render(text,settings,inspected,options)
  local function append(source,extra)
    if options and options.before_layout then
      local at=regions.layout(source,options.before_layout).first
      return source:sub(1,at-1)..extra..source:sub(at)
    end
    return source..extra
  end
  local patches,additions,contexts,layout_settings={},{},{},{}
  for id,value in pairs(settings) do
    local f=assert(fields.by_id[id],'Unknown presentation setting: '..id)
    fields.validate(f,value)
    local entry=observation.assert_valid(assert(inspected[id]));assert(entry.id==id,'Observation setting mismatch')
    if entry.tag=='recognized' then
      if entry.value~=value then patches[#patches+1]={first=entry.location.first,last=entry.location.last,text=fields.literal(f,value)} end
    elseif entry.tag=='available' then
      if f.layout then
        local context=f.context or 'Lyrics'
        contexts[context]=contexts[context] or {}
        local literal=fields.literal(f,value)
        if f.kind=='number' then literal='#'..literal
        elseif f.kind=='symbol' then literal="#'"..literal end
        contexts[context][#contexts[context]+1]=(f.property and '' or '\\override ')..f.layout..' = '..literal
      elseif f.setting then
        layout_settings[#layout_settings+1]=f.setting..' = '..fields.literal(f,value)..(f.unit or '')
      else
        additions[#additions+1]=(f.paper or id:gsub('_','-'))..' = '..fields.literal(f,value)..(f.paper and '' or '\\mm')
      end
    else error('Cannot manage custom setting: '..id) end
  end
  text=regions.patch(text,patches)
  if #additions>0 then
    table.sort(additions)
    text=append(text,'\n% Explicit presentation paper settings.\n\\paper {\n  '..table.concat(additions,'\n  ')..'\n}\n')
  end
  if #layout_settings>0 or next(contexts) then
    table.sort(layout_settings)
    local lines={'', '% Extend the existing layout without replacing its custom settings.',
      'scoreLayout = \\layout {', '  \\scoreLayout'}
    for _,line in ipairs(layout_settings) do lines[#lines+1]='  '..line end
    local names={};for name in pairs(contexts) do names[#names+1]=name end;table.sort(names)
    for _,name in ipairs(names) do
      table.sort(contexts[name])
      lines[#lines+1]='  \\context { \\'..name
      for _,line in ipairs(contexts[name]) do lines[#lines+1]='    '..line end
      lines[#lines+1]='  }'
    end
    lines[#lines+1]='}'
    text=append(text,table.concat(lines,'\n')..'\n')
  end
  return text
end
-- Edit only a named, explicitly bound layout. No assembly or music is inferred.
function M.render_layout(text,values,observed,removed)
  assert(observed.source==text,'Source changed since scoped inspection')
  require('lilyp.presentation_model').validate_values(values,'section')
  local patches,lines,contexts={},{},{}
  for id,value in pairs(values) do
    local f=vim.tbl_extend('force',settings.by_id[id],bindings.for_scope(id,'section'))
    local entry=observation.assert_valid(assert(observed.entries[id]));assert(entry.id==id,'Observation setting mismatch')
    if entry.tag=='recognized' then
      if entry.value~=value then patches[#patches+1]={first=entry.location.first,last=entry.location.last,text=fields.literal(f,value)} end
    elseif entry.tag=='available' then
      if f.layout_function then lines[#lines+1]='#('..f.layout_function..' '..tostring(value)..')'
      elseif f.setting then lines[#lines+1]=f.setting..' = '..fields.literal(f,value)..(f.unit or '')
      elseif f.layout then
        local context=f.context or 'Lyrics';contexts[context]=contexts[context] or {}
        local literal=fields.literal(f,value)
        if f.kind=='number' then literal='#'..literal elseif f.kind=='symbol' then literal="#'"..literal end
        contexts[context][#contexts[context]+1]=(f.property and '' or '\\override ')..f.layout..' = '..literal
      else error('No scoped rendering recipe: '..id) end
    else error('Cannot edit custom scoped setting: '..id) end
  end
  for id in pairs(removed or {}) do
    assert(values[id]==nil,'Cannot set and remove the same override')
    local f=vim.tbl_extend('force',settings.by_id[id],bindings.for_scope(id,'section'))
    local entry=observation.assert_valid(assert(observed.entries[id]));assert(entry.id==id,'Observation setting mismatch')
    assert(entry.tag=='recognized','Cannot remove custom scoped setting: '..id)
    local cursor,found=observed.region.body_first,false
    while true do
      local a,b=text:find(f.pattern,cursor);assert(a and b<=observed.region.body_last,'Missing override declaration: '..id)
      if a<=entry.location.first and b>=entry.location.last then
        if f.layout and not f.property then
          local prefix=text:sub(observed.region.body_first,a-1)
          local start=prefix:find('\\override%s*$')
          assert(start,'Unsupported qualified override: '..id)
          a=observed.region.body_first+start-1
        end
        patches[#patches+1]={first=a,last=b,text=''};found=true;break
      end
      cursor=b+1
    end
    assert(found,'Missing override: '..id)
  end
  table.sort(lines)
  local names={};for name in pairs(contexts) do names[#names+1]=name end;table.sort(names)
  for _,name in ipairs(names) do
    table.sort(contexts[name]);lines[#lines+1]='\\context { \\'..name
    for _,line in ipairs(contexts[name]) do lines[#lines+1]='  '..line end
    lines[#lines+1]='}'
  end
  if #lines>0 then
    local at=observed.region.close
    patches[#patches+1]={first=at,last=at-1,text='\n  '..table.concat(lines,'\n  ')..'\n'}
  end
  return regions.patch(text,patches)
end
return M
