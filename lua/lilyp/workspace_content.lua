-- Read-only center-pane models. No project writes, parsing guesses, or compilation.
local M={}
local observation=require('lilyp.source_observation')
local source_binding=require('lilyp.source_binding')
local function display(value)return (value==nil or value==vim.NIL) and 'Not declared' or tostring(value)end
local function split(text)return vim.split(text,'\n',{plain=true})end
local function cached(state,key,inputs,build)
  state.content_cache=state.content_cache or {}
  local previous=state.content_cache[key]
  if previous and vim.deep_equal(previous.inputs,inputs) then return previous.value end
  local value=build()
  state.content_cache[key]={inputs=vim.deepcopy(inputs),value=value}
  return value
end
local function diff(before,after,path)
  if before==after then return {} end
  local lines={'--- '..path,'+++ '..path..' (draft)'}
  vim.list_extend(lines,split(vim.diff(before or '',after or '',{result_type='unified',ctxlen=3})))
  return lines
end
local function section_by_id(sections,id)
  for _,section in ipairs(sections) do if section.id==id then return section end end
end
local function source(state,files,default,at,key)
  local selection_key=key..'/'..tostring(state.center_source_path)
  local path=state.center_source_path or default
  if not files[path] then path=default end
  local text=files[path] or ''
  local line=1
  if at and path==default then local _,count=text:sub(1,at-1):gsub('\n','');line=count+1 end
  return {title=path..' · read-only snapshot',lines=split(text),focus_line=at and path==default and line or nil,
    key=selection_key,source=true,files=vim.tbl_keys(files),selected=path}
end

function M.presentation(state,kind,field)
  local s=state.session
  local section=section_by_id(s.sections,state.scope)
  local name=section and (section.name or section.id) or 'Score defaults'
  local key=(state.scope or 'score')..'/'..kind
  if kind=='Source' then
    local path,entry=require('lilyp.learning').source(s,state.scope,field)
    local files={}
    for _,rel in ipairs({s.main_path,s.style_path,'score.yaml'}) do files[rel]=s.snapshot[rel] end
    if section and section.source then files[section.source]=s.snapshot[section.source] end
    if not section then
      for _,item in ipairs(s.sections) do if type(item.source)=='string' then files[item.source]=s.snapshot[item.source] end end
    end
    local setting_key=(state.scope or 'score')..'/'..field.id
    if state.center_setting_key~=setting_key then state.center_source_path=nil;state.center_setting_key=setting_key end
    return source(state,files,path or s.style_path,observation.locate(entry) and observation.locate(entry).first,key..'/'..field.id)
  end
  if kind=='Changes' and state.comparison=='yaml' then
    local lines={'YAML ↔ saved source','Enter a difference to choose its resolution.','b switches to Workspace → proposed result.',''}
    local targets={}
    for _,conflict in ipairs(s.conflicts) do
      local f=require('lilyp.fields').by_id[conflict.id]
      local scope=section_by_id(s.sections,conflict.section_id)
      local label=(scope and (scope.name or scope.id) or 'Score defaults')..' · '..(f and f.label or conflict.id)
      local choice=s.resolutions[require('lilyp.reconciliation').key(conflict.id,conflict.section_id)]
      local first=#lines+1
      lines[#lines+1]=label
      lines[#lines+1]='  YAML: '..display(conflict.expected)..' → saved source: '..display(conflict.actual)
      local supported=require('lilyp.reconciliation').actionable(s,conflict)
      lines[#lines+1]='  '..(not supported and 'Manual correction required: '..(conflict.reason or conflict.status or 'unavailable')
        or choice=='yaml' and 'Use YAML · staged' or choice=='source' and 'Keep source change · staged' or 'Unresolved')
      for row=first,#lines do targets[row]=conflict end
      lines[#lines+1]=''
    end
    if #s.conflicts==0 then lines[#lines+1]='No YAML/source disagreements.' end
    lines[#lines+1]=#s:unresolved()..' unresolved · y/v selected · Y/V all supported · x clear choice'
    return {title='YAML ↔ saved source · b switches',lines=lines,key='reconcile/'..tostring(state.scope),targets=targets,prose=true}
  end
  if kind=='Changes' then
    return cached(state,'changes',{scope=state.scope,session=s.snapshot,values=s.draft,sections=s.section_drafts,resolutions=s.resolutions},function()
      local lines={name..' · draft changes','Workspace → proposed result · b compares YAML/source',''}
      if not s.specified then
        lines[#lines+1]='Save spec imports recognized shared styling.'
        lines[#lines+1]='It must preserve rendered pages and MIDI.'
      end
      local count=0
      local changes=s:changes()
      for _,change in ipairs(changes) do
        if change.section_id==state.scope then
          count=count+1
          lines[#lines+1]=change.label..': '..display(change.before)..' → '..(change.after==nil and 'Inherited' or display(change.after))
        end
      end
      if count==0 and s.specified then lines[#lines+1]='No pending values in this scope.' end
      if s.specified and #changes==0 and not s.metadata_cleanup and #s:unresolved()==0 then
        lines[#lines+1]='';lines[#lines+1]='No pending project changes.'
        return {title=name,lines=lines,key=key,prose=true}
      end
      lines[#lines+1]='';lines[#lines+1]='Exact project plan · all pending scopes'
      local ok,plan=pcall(s.plan,s)
      if ok then
        for _,edit in ipairs(plan.sources) do vim.list_extend(lines,diff(edit.before,edit.after,edit.path));lines[#lines+1]='' end
        if #plan.sources==0 then lines[#lines+1]='No source changes.' end
      else lines[#lines+1]='Plan unavailable: '..tostring(plan) end
      return {title=name,lines=lines,key=key,diff=true}
    end)
  end
  local lines={name,'',section and 'Declared section' or 'Shared score presentation'}
  if section then
    lines[#lines+1]='ID: '..section.id
    lines[#lines+1]='Type: '..display(section.type)
    lines[#lines+1]='Source: '..display(section.source)
    lines[#lines+1]='Lyric rows: '..display(section.verses)
    lines[#lines+1]='Arrangement: '..display(section.staff_preset or s.staff_preset)
    for _,voice in ipairs(type(section.voices)=='table' and section.voices or {}) do
      local playback=voice.playback_voice==vim.NIL and 'printed only' or display(voice.playback_voice)
      lines[#lines+1]=display(voice.id)..' → '..playback..' · '..display(voice.instrument)
    end
    local binding=s.section_styles[section.id]
    lines[#lines+1]='';lines[#lines+1]='Layout: '..display(binding.layout)
    lines[#lines+1]=source_binding.available(binding) and (binding.tag=='named' and 'Explicit named layout binding.' or 'Inline layout · import on request.') or display(source_binding.reason(binding))
  else
    lines[#lines+1]='Entry: '..s.main_path
    lines[#lines+1]='Styling: '..s.style_path
    lines[#lines+1]='Sections: '..#s.sections
    lines[#lines+1]=s.specified and 'YAML presentation specification initialized.' or 'Save spec initializes presentation explicitly.'
  end
  local current=s:view(state.scope)
  local custom={}
  for _,f in ipairs(require('lilyp.fields').list) do
    local entry=current.entries[f.id]
    if entry.tag=='custom' and (not state.scope or vim.tbl_contains(f.scopes,'section')) then custom[#custom+1]=f.label..': '..display(observation.reason(entry)) end
  end
  lines[#lines+1]='';lines[#lines+1]='Handwritten / unavailable settings'
  if #custom==0 then lines[#lines+1]='No unsupported settings reported in this scope.' else vim.list_extend(lines,custom) end
  lines[#lines+1]='';lines[#lines+1]='Music, lyrics, ordering, and playback stay handwritten.'
  lines[#lines+1]='Select a control on the right to inspect its origin.'
  return {title=name,lines=lines,key=key,prose=true}
end

local function generated(options)
  local ok,text=pcall(require('lilyp.scaffold').prepare,options)
  if ok then return text end
  return nil,type(text)=='table' and text.message or tostring(text)
end
function M.creation(state,kind,field)
  local sections=require('lilyp.sections')
  local selected=section_by_id(sections.plan(state.options),state.outline_section)
  local name=selected and selected.name or 'Score defaults'
  local key=(state.outline_section or 'score')..'/'..kind
  if kind=='Source' then
    local result=cached(state,'generated',state.options,function()
      local text,err=generated(state.options);return {text=text,err=err}
    end)
    if not result.text then return {title='Generated source',lines={'Source unavailable: '..display(result.err)},key=key,prose=true} end
    local text=result.text
    local at
    if field.id then
      local scope=field.scope and field.scope~='score' and 'section' or 'global'
      local pattern=require('lilyp.style_bindings').for_scope(field.id,scope).pattern
      local first,last=1,#text
      if scope=='section' then
        for i,section in ipairs(sections.plan(state.options)) do if section.id==field.scope then
          local block=require('lilyp.source_regions').blocks(text,'score')[i]
          if block then first,last=block.first,block.close end
        end end
      end
      local found=text:sub(first,last):find(pattern)
      if found then at=first+found-1 end
    elseif selected then
      at=text:find('% curator-section-start '..selected.id,1,true)
    end
    local content=source(state,{['Generated LilyPond']=text},'Generated LilyPond',at,key..'/'..field.key)
    content.title='Generated LilyPond · draft · read-only'
    return content
  end
  if kind=='Changes' then
    return cached(state,'creation_changes',{scope=state.outline_section,options=state.options,baseline=state.creation_baseline},function()
      local before,old_error=generated(state.creation_baseline)
      local after,new_error=generated(state.options)
      local lines={'Creation draft · generated source changes','No project files have been written.',''}
      if before and after then
        vim.list_extend(lines,diff(before,after,'generated.ly'))
        if before==after then lines[#lines+1]='No generated-source changes from configured defaults.' end
      else lines[#lines+1]='Source comparison unavailable: '..display(new_error or old_error) end
      if not vim.deep_equal(state.options.project_directory,state.creation_baseline.project_directory) then
        lines[#lines+1]='Destination: '..require('lilyp.build').directory(state.options)
      end
      return {title=name,lines=lines,key=key,diff=true}
    end)
  end
  local lines={name,'','New score · initialization draft'}
  if selected then
    local arrangement=sections.staff_preset(state.options,selected)
    lines[#lines+1]='ID: '..selected.id
    lines[#lines+1]='Type: '..selected.type
    lines[#lines+1]='Source: '..sections.filename(selected)
    lines[#lines+1]='Arrangement: '..require('lilyp.scaffold').preset(arrangement).label
    local effective=sections.options(state.options,selected)
    lines[#lines+1]='Key: '..effective.key..' '..effective.mode
    lines[#lines+1]='Time signature: '..effective.meter
    lines[#lines+1]='Lyric rows: '..sections.lyric_rows(state.options,selected)
    if selected.lyrics~=nil then lines[#lines+1]='Section lyrics: '..(selected.lyrics and 'On' or 'Off') end
    lines[#lines+1]='';lines[#lines+1]='Section appearance overrides'
    local ids=vim.tbl_keys(selected.presentation or {});table.sort(ids)
    for _,id in ipairs(ids) do lines[#lines+1]=id..': '..display(selected.presentation[id]) end
    if #ids==0 then lines[#lines+1]='Inherits score defaults.' end
  else
    lines[#lines+1]='Title: '..state.options.title
    lines[#lines+1]='Arrangement: '..require('lilyp.scaffold').preset(state.options.preset).label
    lines[#lines+1]='Destination: '..(state.options.project_mode=='project' and require('lilyp.build').directory(state.options) or 'Unsaved standalone source')
    lines[#lines+1]='';lines[#lines+1]='Printed / playback plan'
    for i,section in ipairs(sections.plan(state.options)) do lines[#lines+1]=i..'. '..section.name..' · '..section.type end
  end
  lines[#lines+1]='';lines[#lines+1]='Configuration is on the right.'
  lines[#lines+1]='Source shows the draft before creation.'
  lines[#lines+1]='Creating a score initializes source; later music stays handwritten.'
  return {title=name,lines=lines,key=key,prose=true}
end
return M
