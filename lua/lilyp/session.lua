local section_draft=require('lilyp.section_draft')
local fs=require('lilyp.fs')
local style=require('lilyp.style')
local fields=require('lilyp.fields')
local spec=require('lilyp.spec')
local model=require('lilyp.presentation_model')
local plans=require('lilyp.edit_plan')
local scoped=require('lilyp.section_presentation')
local reconciliation=require('lilyp.reconciliation')
local regions=require('lilyp.source_regions')
local Session={};Session.__index=Session
local M={}
local observation=require('lilyp.source_observation')
local binding=require('lilyp.source_binding')
local function object(values) return next(values) and model.copy(values) or vim.empty_dict() end
function M.open(path)
  local root=assert(require('lilyp').project_root(path),'No score.yaml project found')
  root=vim.fs.normalize(root)
  local snapshot=fs.snapshot(root)
  local metadata=spec.read(assert(snapshot['score.yaml']))
  local project=require('lilyp.project').describe(root,metadata)
  assert(snapshot[project.main_relative],'Main score is outside the source snapshot')
  local style_path=project.style_relative
  fs.inside(root,style_path)
  assert(snapshot[style_path],'No style include found; extract presentation into '..style_path..' before initializing the specification')
  local sections=metadata.sections
  for _,section in ipairs(sections) do
    if type(section.source)=='string' then fs.inside(root,section.source) end
  end
  local presentation=metadata.presentation
  local specification=presentation.tag=='specified' and presentation.value or nil
  local section_styles,spans=scoped.discover(snapshot,sections,specification,style_path)
  local inspected=style.inspect(regions.mask(snapshot[style_path],spans[style_path] or {}))
  for id,entry in pairs(inspected) do inspected[id]=observation.with_context(entry,{path=style_path,scope='global'}) end
  for rel,text in pairs(snapshot) do
    if rel~=style_path and (rel:match('%.ily$') or rel:match('%.ly$')) then
      local overrides=style.inspect(regions.mask(text,spans[rel] or {}))
      for id,entry in pairs(inspected) do
        if overrides[id].evidence.assignments>0 or observation.font_override(overrides[id]) then
          inspected[id]=observation.block(entry,observation.cause('AdditionalAssignment',{path=rel}))
        end
      end
    end
  end
  local declared=specification and model.copy(specification.settings) or {}
  local import_candidate=not specification and model.import(inspected) or nil
  local resolved=model.resolve(declared)
  local values=specification and resolved.values or import_candidate
  local conflicts=specification and model.compare(declared,inspected) or {}
  local section_drafts={}
  for id,entry in pairs(section_styles) do
    local saved=specification and specification.sections[id]
    if saved then
      section_drafts[id]=section_draft.new(saved.layout,saved.settings)
      if not binding.available(entry) or entry.layout~=saved.layout then
        conflicts[#conflicts+1]={id='layout',scope='section',section_id=id,reason=binding.reason(entry) or 'Section layout binding differs'}
      else
        for _,conflict in ipairs(model.compare(saved.settings,entry.observed.entries)) do
          conflict.scope='section';conflict.section_id=id;conflicts[#conflicts+1]=conflict
        end
      end
    end
  end
  local drift={};for _,conflict in ipairs(conflicts) do drift[#drift+1]=(conflict.section_id and conflict.section_id..'.' or '')..conflict.id end
  return setmetatable({root=root,main_path=project.main_relative,snapshot=snapshot,style_path=style_path,
    observed={global=inspected},declared=declared,resolved=resolved,import_candidate=import_candidate,conflicts=conflicts,
    -- Flat views remain the score-default draft for compatibility with callers.
    inspected=inspected,values=values,draft=model.copy(values),drift=drift,
    sections=sections,section_styles=section_styles,section_drafts=section_drafts,
    printed_order=metadata.printed_order,staff_preset=metadata.staff_preset,
    specified=specification~=nil,specification=specification,resolutions={},metadata_cleanup=presentation.tag=='specified' and presentation.metadata_cleanup or false,temporary={}},Session)
end
function Session:conflict(id,section_id)return reconciliation.find(self,id,section_id)end
function Session:unresolved()return reconciliation.unresolved(self)end
function Session:resolve_conflict(id,choice,section_id)return reconciliation.resolve(self,id,choice,section_id)end
function Session:resolve_all(choice)return reconciliation.all(self,choice)end
function Session:assert_editable()
  assert(self.specified,'Initialize the YAML presentation specification before editing')
  assert(self.reconciling or #self:unresolved()==0,'Style differs from the YAML specification; reconcile source/specification first: '..table.concat(self.drift,', '))
end
function Session:enable_section(section_id)
  self:assert_editable()
  local entry=assert(self.section_styles[section_id],'Unknown section')
  assert(binding.available(entry),binding.reason(entry))
  if not self.section_drafts[section_id] then
    self.section_drafts[section_id]=section_draft.new(entry.layout,entry.import_candidate or {})
  end
  return self.section_drafts[section_id]
end
function Session:section_projection(section_id)
  local entry=assert(self.section_styles[section_id],'Unknown section')
  local saved=self.specification and self.specification.sections[section_id]
  return section_draft.resolve(self.section_drafts[section_id],entry.import_candidate,saved and saved.settings)
end
function Session:keep_section_setting(section_id,id)
  local draft=self.section_drafts[section_id]
  if draft then section_draft.set(draft,id,section_draft.keep()) end
end
function Session:view(section_id)
  if not section_id then return {values=self.draft,baseline=self.values,entries=self.inspected} end
  local entry=assert(self.section_styles[section_id],'Unknown section')
  local saved=self.specification and self.specification.sections[section_id]
  local draft=self.section_drafts[section_id]
  local projection=self:section_projection(section_id)
  local resolved=model.resolve(self.draft,projection.effective,section_id)
  local entries={}
  for _,f in ipairs(fields.list) do
    local local_entry=entry.observed and entry.observed.entries[f.id]
    if not binding.available(entry) then
      entries[f.id]=observation.custom(f.id,observation.cause('SectionUnavailable',{detail=binding.reason(entry)}),nil,{scope='section'})
    else
      entries[f.id]=model.copy(assert(local_entry))
      local shared=self.inspected[f.id]
      if observation.font_override(shared) or (shared.tag=='custom' and shared.cause.kind=='AdditionalAssignment') then
        entries[f.id]=observation.block(shared,shared.cause)
      end
    end
  end
  return {values=resolved.values,origins=resolved.origins,entries=entries,overrides=projection.settings,
    baseline=saved and saved.settings or {},changed=projection.changed,specified=draft~=nil,source=entry}
end
function Session:set(id,value,section_id)
  assert(value~=nil,'A value is required; use inherit to remove a section override')
  return self:set_many({[id]=value},section_id)
end
function Session:set_many(values,section_id)
  self:assert_editable()
  local view=self:view(section_id)
  for id in pairs(values) do
    local entry=assert(view.entries[id],'Unknown setting')
    assert(observation.editable(entry),observation.reason(entry))
  end
  model.validate_values(values,section_id and 'section' or 'global')
  local effective=vim.tbl_extend('force',view.values,values)
  require('lilyp.settings').validate_values(effective,'global')
  -- Unspecified source observations are used only for checking font availability.
  local before=vim.tbl_extend('force',model.import(self.inspected),view.values)
  if section_id and view.source.import_candidate then before=vim.tbl_extend('force',before,view.source.import_candidate,view.values) end
  require('lilyp.fonts').validate_change(before,vim.tbl_extend('force',before,values))
  if not section_id and (values.lyric_font or values.lyric_weight or values.lyric_shape) then
    for _,section in ipairs(self.sections) do
      local local_view=self:view(section.id)
      if binding.available(local_view.source) and not observation.font_override(local_view.entries.lyric_font) then
        local local_before=vim.tbl_extend('force',model.import(self.inspected),local_view.values)
        local local_after=vim.tbl_extend('force',local_before,values)
        for id,origin in pairs(local_view.origins) do
          if origin.scope=='section' then local_after[id]=local_view.values[id] end
        end
        require('lilyp.fonts').validate_change(local_before,local_after)
      end
    end
  end
  if section_id then
    local draft=self:enable_section(section_id)
    for id,value in pairs(values) do section_draft.set(draft,id,section_draft.explicit(id,value)) end
  else for id,value in pairs(values) do self.draft[id]=value end end
end
function Session:inherit(section_id,id)
  self:assert_editable()
  local view=self:view(section_id)
  local entry=assert(view.entries[id])
  assert(observation.editable(entry),observation.reason(entry))
  assert(vim.tbl_contains(fields.by_id[id].scopes,'section'),id..': unsupported scope section')
  local effective=model.copy(view.values)
  effective[id]=self.draft[id]
  require('lilyp.settings').validate_values(effective,'global')
  local observed=model.import(self.inspected)
  require('lilyp.fonts').validate_change(vim.tbl_extend('force',observed,view.values),vim.tbl_extend('force',observed,effective))
  local draft=self:enable_section(section_id)
  section_draft.set(draft,id,section_draft.inherit())
end
function Session:revert()
  self.resolutions={}
  self.draft=model.copy(self.values);self.section_drafts={}
  for id,saved in pairs(self.specification and self.specification.sections or {}) do
    self.section_drafts[id]=section_draft.new(saved.layout,saved.settings)
  end
end
function Session:changes()
  local changes={}
  for _,f in ipairs(fields.list) do
    if self.draft[f.id]~=self.values[f.id] then
      changes[#changes+1]={scope='global',id=f.id,label=f.label,before=self.values[f.id],after=self.draft[f.id]}
    end
  end
  for _,section in ipairs(self.sections) do
    local id=section.id;local draft=self.section_drafts[id]
    local saved=self.specification and self.specification.sections[id]
    if draft then
      if not saved then changes[#changes+1]={scope='section',section_id=id,id='layout',label='Section layout specification',after=draft.layout} end
      local projection=self:section_projection(id)
      for _,f in ipairs(fields.list) do
        local before=saved and saved.settings[f.id]
        local after=projection.settings[f.id]
        if projection.changed[f.id] then
          changes[#changes+1]={scope='section',section_id=id,id=f.id,label=f.label,before=before,after=after}
        end
      end
    end
  end
  return reconciliation.changes(self,changes)
end
function Session:render_sources()
  assert(#self:unresolved()==0,'Presentation drift must be reconciled before Apply; review YAML/source differences in Changes')
  if not self.specified then assert(vim.deep_equal(self.draft,self.import_candidate),'Initial specification import must preserve appearance') end
  model.validate_values(self.draft,'global')
  -- Render local edits first, then inspect bounded shared spans again: offsets may have moved.
  local projections={}
  for id in pairs(self.section_drafts) do projections[id]=self:section_projection(id) end
  local output=scoped.render(self.snapshot,self.section_styles,projections,self.style_path)
  local persisted={}
  for id,draft in pairs(self.section_drafts) do persisted[id]={layout=draft.layout,settings=object(projections[id].settings)} end
  local version=next(persisted) and 2 or self.specification and self.specification.schema_version or 1
  local specification={schema_version=version,id=self.specification and self.specification.id or 'presentation-default',
    style=self.style_path,settings=object(self.draft),custom_policy='preserve-in-place'}
  if version==2 then specification.sections=object(persisted) end
  -- Re-discover to mask named section layouts after migration.
  local migrated,spans=scoped.discover(output,self.sections,specification,self.style_path)
  local first_binding,first_at
  for id,entry in pairs(migrated) do
    if persisted[id] then assert(binding.available(entry),binding.reason(entry)) end
    if binding.available(entry) and entry.tag=='named' and (not first_at or entry.observed.region.first<first_at) then
      first_binding=entry.layout;first_at=entry.observed.region.first
    end
  end
  local observations=style.inspect(regions.mask(output[self.style_path],spans[self.style_path] or {}))
  output[self.style_path]=style.render(output[self.style_path],self.draft,observations,{before_layout=first_binding})
  output['score.yaml']=spec.call({action='write',text=self.snapshot['score.yaml'],presentation=specification}).text
  output['score.yaml']=require('lilyp.output').specification(self.root,output['score.yaml'])
  output['.gitignore']=require('lilyp.output').ignore(self.root,output['.gitignore'])
  return output
end
function Session:render()
  local output=self:render_sources();return output[self.style_path],output['score.yaml']
end
function Session:plan()
  local output=self:render_sources()
  local sources={}
  -- Keep shared style/spec first for existing clients and predictable rollback.
  local paths={self.style_path,'score.yaml'}
  for path in pairs(output) do if path~=self.style_path and path~='score.yaml' and output[path]~=self.snapshot[path] then paths[#paths+1]=path end end
  table.sort(paths, function(a,b)
    local function priority(path)return path==self.style_path and 0 or path=='score.yaml' and 1 or 2 end
    if priority(a)~=priority(b) then return priority(a)<priority(b) end;return a<b
  end)
  for _,path in ipairs(paths) do
    local reason=path=='score.yaml' and 'Presentation/output specification'
      or path=='.gitignore' and 'Build symlink ignore rule' or 'Presentation layout bindings/literals'
    sources[#sources+1]={path=path,after=output[path],reason=reason}
  end
  local appearance_changed=false
  for _,change in ipairs(self:changes()) do
    if change.id~='layout' then
      local before=change.before
      if change.section_id then
        local entry=self.section_styles[change.section_id].observed.entries[change.id]
        if entry.tag=='recognized' then before=entry.value else before=self.draft[change.id] end
      end
      if change.reconciliation then before=change.observed end
      if before~=change.after then appearance_changed=true end
    end
  end
  return plans.new(self,sources,{settings_changes=self:changes(),compare_pages=not self.specified or not appearance_changed})
end
function Session:validate_plan(plan,job)
  local transaction=require('lilyp.transaction')
  -- A first edit can change appearance as well as relocate an inline layout.
  -- Verify relocation independently before accepting the requested visual change.
  local migrating=false
  for id in pairs(self.section_drafts) do if self.section_styles[id].tag=='inline' then migrating=true end end
  if migrating and not plan.compare_pages then
    local baseline=setmetatable({},Session)
    for key,value in pairs(self) do baseline[key]=value end
    baseline.draft=model.copy(self.values);baseline.section_drafts={}
    for id,draft in pairs(self.section_drafts) do
      local saved=self.specification.sections[id]
      baseline.section_drafts[id]=section_draft.new(draft.layout,saved and saved.settings or self.section_styles[id].import_candidate or {})
    end
    -- Check layout relocation against the actual saved appearance, separately
    -- from requested YAML restoration or ordinary presentation edits.
    baseline.resolutions=vim.deepcopy(self.resolutions)
    for _,conflict in ipairs(self.conflicts) do
      baseline.resolutions[reconciliation.key(conflict.id,conflict.section_id)]='source'
      if conflict.section_id then section_draft.set(baseline.section_drafts[conflict.section_id],conflict.id,section_draft.explicit(conflict.id,conflict.actual))
      else baseline.draft[conflict.id]=conflict.actual end
    end
    local migration=baseline:plan();migration.compare_pages=true
    if not vim.deep_equal(self.validated_migration,migration) then
      transaction.validate(self,migration,job);self.validated_migration=vim.deepcopy(migration)
    end
  end
  return transaction.validate(self,plan,job)
end
function Session:preview(job) return self:validate_plan(self:plan(),job) end
function Session:apply(job)
  assert(#self:unresolved()==0,'Presentation drift must be reconciled before Apply; review YAML/source differences in Changes')
  if self.specified and not self.metadata_cleanup and #self:changes()==0 then return nil,'No changes' end
  local plan=self:plan()
  local result=self:validate_plan(plan,job)
  return require('lilyp.transaction').publish(self,plan,result,job)
end
function Session:close()
  local retained,failures={},{}
  for _,path in ipairs(self.temporary) do
    local ok,err=pcall(function()assert(vim.fn.delete(path,'rf')==0,'Could not remove '..path)end)
    if not ok then retained[#retained+1]=path;failures[#failures+1]=tostring(err) end
  end
  self.temporary=retained
  assert(#failures==0,table.concat(failures,'\n'))
end
return M
