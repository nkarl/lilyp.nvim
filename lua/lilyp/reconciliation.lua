-- Explicit draft decisions over immutable YAML/source observations.
local M={}
function M.key(id,section_id)return (section_id and ('section:'..section_id) or 'global')..'/'..id end
function M.find(session,id,section_id)
  for _,conflict in ipairs(session.conflicts) do
    if conflict.id==id and conflict.section_id==section_id then return conflict end
  end
end
function M.actionable(session,conflict)
  if conflict.status~='recognized' or conflict.id=='layout' then return false end
  return session:view(conflict.section_id).entries[conflict.id].tag=='recognized'
end
function M.unresolved(session)
  local result={}
  for _,conflict in ipairs(session.conflicts) do
    if not session.resolutions[M.key(conflict.id,conflict.section_id)] then result[#result+1]=conflict end
  end
  return result
end
function M.resolve(session,id,choice,section_id)
  local conflict=assert(M.find(session,id,section_id),'No YAML/source disagreement for this setting')
  assert(choice=='yaml' or choice=='source' or choice=='unresolved','Choose Use YAML, Keep source change, or Unresolved')
  local key=M.key(id,section_id)
  if choice=='unresolved' then
    if session.resolutions[key] then
      if section_id then session:keep_section_setting(section_id,id)
      else session.draft[id]=conflict.expected end
    end
    session.resolutions[key]=nil;return
  end
  assert(M.actionable(session,conflict),'Custom, missing, or ambiguous styling needs manual source correction; reload afterwards')
  local value=conflict.expected
  if choice=='source' then value=conflict.actual end
  session.reconciling=true
  local ok,err=pcall(session.set,session,id,value,section_id)
  session.reconciling=nil
  assert(ok,err)
  session.resolutions[key]=choice
end
function M.all(session,choice)
  assert(choice=='yaml' or choice=='source','Choose Use YAML or Keep source changes')
  local before={draft=vim.deepcopy(session.draft),sections=vim.deepcopy(session.section_drafts),resolutions=vim.deepcopy(session.resolutions)}
  local count=0
  local ok,err=pcall(function()
    for _,conflict in ipairs(session.conflicts) do
      if M.actionable(session,conflict) then M.resolve(session,conflict.id,choice,conflict.section_id);count=count+1 end
    end
  end)
  if not ok then session.draft=before.draft;session.section_drafts=before.sections;session.resolutions=before.resolutions;error(err) end
  return count
end
function M.changes(session,changes)
  for _,conflict in ipairs(session.conflicts) do
    local choice=session.resolutions[M.key(conflict.id,conflict.section_id)]
    if choice then
      local change
      for _,candidate in ipairs(changes) do
        if candidate.id==conflict.id and candidate.section_id==conflict.section_id then change=candidate;break end
      end
      if not change then
        local value=session.draft[conflict.id]
        if conflict.section_id then value=session:section_projection(conflict.section_id).settings[conflict.id] end
        change={id=conflict.id,section_id=conflict.section_id,scope=conflict.scope,
          label=require('lilyp.fields').by_id[conflict.id].label,before=conflict.expected,after=value}
        changes[#changes+1]=change
      end
      change.reconciliation=true;change.resolution=choice;change.observed=conflict.actual
    end
  end
  return changes
end
return M
