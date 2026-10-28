-- Bind declared sections to printed layouts through unique source-variable references.
-- This adapter never rewrites music or infers a section from its heading/order.
local regions=require('lilyp.source_regions')
local style=require('lilyp.style')
local model=require('lilyp.presentation_model')
local M={}
local binding=require('lilyp.source_binding')
local observation=require('lilyp.source_observation')
local function check(value,kind,detail)if not value then error(binding.cause(kind,detail),0) end end
local function references(text)
  local result,code,cursor={},regions.code_positions(text),1
  while true do
    local a,b,name=text:find('\\([%a][%w_%-]*)',cursor)
    if not a then break end
    if code[a] then result[name]=(result[name] or 0)+1 end
    cursor=b+1
  end
  return result
end
local function definitions(text)
  local result,code,cursor={},regions.code_positions(text),1
  local depths,depth={},0
  for at=1,#text do
    depths[at]=depth
    if code[at] then
      local c=text:sub(at,at)
      if c=='{' then depth=depth+1 elseif c=='}' then depth=math.max(0,depth-1) end
    end
  end
  while true do
    local a,b,name=text:find('([%a][%w_%-]*)%s*=',cursor)
    if not a then break end
    local line=(text:sub(1,a-1):match('.*()\n') or 0)+1
    if code[a] and depths[a]==0 and text:sub(line,a-1):match('^%s*$') then result[name]=true end
    cursor=b+1
  end
  return result
end
local function binding_name(id)
  return id:gsub('_([%a])',string.upper):gsub('[^%a]',function(c)
    return 'X'..string.char(65+math.floor(c:byte()/26))..string.char(65+c:byte()%26)
  end)..'Layout'
end
local function inherited(body)
  local refs=references(body)
  check(refs.scoreLayout==1,'MissingInheritance')
end
function M.discover(snapshot,sections,specification,style_path)
  local result,spans={},{}
  local printed,unparsed={},{}
  for path,text in pairs(snapshot) do
    if path:match('%.i?ly$') then
      local ok,scores=pcall(function()
        local found={}
        for _,score in ipairs(regions.blocks(text,'score')) do
          local layouts={}
          for _,layout in ipairs(regions.blocks(text:sub(score.body_first,score.body_last),'layout')) do
            for _,key in ipairs({'first','open','close','body_first','body_last'}) do layout[key]=layout[key]+score.body_first-1 end
            layouts[#layouts+1]=layout
          end
          if #layouts==1 then
            found[#found+1]={path=path,score=score,layout=layouts[1],refs=references(text:sub(score.body_first,score.body_last))}
          end
        end
        return found
      end)
      if ok then vim.list_extend(printed,scores)
      else unparsed[#unparsed+1]=path..': '..tostring(scores) end
    end
  end
  table.sort(unparsed)
  local claims={}
  for _,section in ipairs(sections) do
    local id=section.id
    local name=section.name or id
    local entry={}
    local ok,value=pcall(function()
      -- Incomplete music is normal while transcribing. Keep global inspection
      -- available, but do not guess section bindings from a partial source scan.
      check(#unparsed==0,'UnparsedSources',table.concat(unparsed,'; '))
      check(type(section.source)=='string' and snapshot[section.source],'MissingSource')
      local declared=definitions(snapshot[section.source])
      local saved=specification and specification.sections and specification.sections[id]
      local candidates={}
      for _,score in ipairs(printed) do
        if saved then
          if score.refs[saved.layout] then candidates[#candidates+1]=score end
        else
          for name in pairs(declared) do
            if score.refs[name] then candidates[#candidates+1]=score;break end
          end
        end
      end
      check(#candidates==1,'PrintedScoreAmbiguous')
      local candidate=candidates[1]
      entry.printed=candidate
      claims[candidate]=claims[candidate] or {};claims[candidate][#claims[candidate]+1]=id
      local text=snapshot[candidate.path]
      local body=text:sub(candidate.layout.body_first,candidate.layout.body_last)
      local refs=references(body)
      local name=saved and saved.layout
      if not name and not refs.scoreLayout then
        local clean=body
        local code=regions.code_positions(clean)
        local words={}
        for at=1,#clean do if code[at] then words[#words+1]=clean:sub(at,at) end end
        name=table.concat(words):match('^%s*\\([%a][%a%-]*)%s*$')
      end
      if name then
        -- The printed layout must be exactly one reference, allowing comments and whitespace.
        local code=regions.code_positions(body);local visible={}
        for at=1,#body do if code[at] then visible[#visible+1]=body:sub(at,at) end end
        check(table.concat(visible):match('^%s*\\'..vim.pesc(name)..'%s*$'),'AdditionalPrintedStyling')
        local uses=0
        for path,source in pairs(snapshot) do
          if path:match('%.i?ly$') then uses=uses+(references(source)[name] or 0) end
        end
        check(uses==1,'ExtraReferences')
        local observed=style.inspect_layout(snapshot[style_path],name)
        inherited(snapshot[style_path]:sub(observed.region.body_first,observed.region.body_last))
        entry.layout=name;entry.path=style_path;entry.observed=observed;entry.tag='named'
      else
        inherited(body)
        -- Inspect the exact existing body through a temporary name; restore source offsets.
        local prefix='temporaryLayout = '
        local observed=style.inspect_layout(prefix..text:sub(candidate.layout.first,candidate.layout.close),'temporaryLayout')
        local delta=candidate.layout.first-#prefix-1
        for setting,item in pairs(observed.entries) do observed.entries[setting]=observation.with_context(item,{},delta,candidate.layout.close) end
        observed.source=text;observed.region=candidate.layout
        entry.layout=binding_name(id);entry.path=candidate.path;entry.observed=observed;entry.tag='inline'
        for path,source in pairs(snapshot) do
          if path:match('%.i?ly$') then check(not definitions(source)[entry.layout],'NameCollision',entry.layout) end
        end
      end
      for setting,item in pairs(entry.observed.entries) do
        entry.observed.entries[setting]=observation.with_context(item,{path=entry.path,binding=entry.layout})
      end
      entry.import_candidate=model.import(entry.observed.entries)
      local tag=entry.tag;entry.tag=nil
      return binding.bound(tag,id,section.name or id,entry)
    end)
    if ok then result[id]=value
    else
      local cause=type(value)=='table' and value or binding.cause('InvalidLayout',tostring(value))
      result[id]=binding.unavailable(id,name,cause,{path=entry.path,layout=entry.layout,printed=entry.printed})
    end
  end
  for _,entries in pairs(claims) do
    if #entries>1 then for _,id in ipairs(entries) do result[id]=binding.reject(result[id],binding.cause('SharedPrintedScore')) end end
  end
  local names={}
  for id,entry in pairs(result) do
    if binding.available(entry) then
      if names[entry.layout] then
        local other=names[entry.layout]
        result[other]=binding.reject(result[other],binding.cause('SharedLayout'))
        result[id]=binding.reject(entry,binding.cause('SharedLayout'))
      else names[entry.layout]=id end
    end
  end
  for _,entry in pairs(result) do
    if binding.available(entry) then
      spans[entry.path]=spans[entry.path] or {};spans[entry.path][#spans[entry.path]+1]=entry.observed.region
    end
  end
  return result,spans
end
function M.render(snapshot,sections,projections,style_path)
  local output=vim.deepcopy(snapshot)
  local patches,new_layouts={},{}
  local ids={};for id in pairs(projections) do ids[#ids+1]=id end;table.sort(ids)
  for _,id in ipairs(ids) do
    local projection,entry=projections[id],assert(sections[id])
    assert(binding.available(entry),binding.reason(entry))
    local observed=entry.observed
    local rendered=style.render_layout(snapshot[entry.path],projection.settings,observed,projection.removed)
    local region=entry.tag=='named' and regions.layout(rendered,entry.layout)
      or regions.blocks(rendered:sub(entry.printed.layout.first),'layout')[1]
    if entry.tag=='inline' then
      -- render_layout edits only this block; its start is unchanged.
      local first=entry.printed.layout.first
      local body=rendered:sub(first+region.body_first-1,first+region.body_last-1)
      new_layouts[#new_layouts+1]=entry.layout..' = \\layout {'..body..'}\n'
      patches[entry.path]=patches[entry.path] or {}
      patches[entry.path][#patches[entry.path]+1]={first=entry.printed.layout.first,last=entry.printed.layout.close,text='\\layout { \\'..entry.layout..' }'}
    else
      patches[entry.path]=patches[entry.path] or {}
      patches[entry.path][#patches[entry.path]+1]={first=observed.region.first,last=observed.region.close,text=rendered:sub(region.first,region.close)}
    end
  end
  for path,edits in pairs(patches) do output[path]=regions.patch(snapshot[path],edits) end
  if #new_layouts>0 then output[style_path]=output[style_path]..'\n'..table.concat(new_layouts,'\n') end
  return output
end
return M
