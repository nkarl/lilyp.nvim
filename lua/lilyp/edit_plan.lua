-- Explicit source edits shared by preview, validation, publication, and recovery.
local fs=require('lilyp.fs')
local M={}
function M.validate(session,plan)
  assert(type(plan)=='table' and plan.version==1 and plan.root==session.root,'Invalid edit plan')
  assert(type(plan.sources)=='table','Edit plan requires source edits')
  assert(type(plan.compare_pages)=='boolean' and type(plan.settings_changes)=='table','Invalid plan validation requirements')
  for key in pairs(plan.sources) do
    assert(type(key)=='number' and key>=1 and key<=#plan.sources and key==math.floor(key),'Source edits must be an ordered list')
  end
  local seen={}
  for _,edit in ipairs(plan.sources) do
    local full=fs.inside(session.root,edit.path)
    assert(full:sub(#session.root+2)==edit.path,'Edit path must be canonical')
    local first=edit.path:match('^[^/]+')
    assert(first~='build' and first~='backups' and first~='.git' and first~='.lilypond-curator.lock','Not a source destination')
    assert(not seen[edit.path],'Duplicate edit destination: '..edit.path);seen[edit.path]=true
    assert(edit.before==session.snapshot[edit.path],'Edit baseline differs: '..edit.path)
    assert(type(edit.after)=='string' and type(edit.reason)=='string','Invalid source edit')
  end
  return plan
end
function M.new(session,sources,details)
  local plan={version=1,root=session.root,sources={},settings_changes=details and details.settings_changes or {},
    compare_pages=details and details.compare_pages or false}
  for _,edit in ipairs(sources) do
    plan.sources[#plan.sources+1]={path=edit.path,before=session.snapshot[edit.path],after=edit.after,reason=edit.reason}
  end
  M.validate(session,plan)
  local changed={}
  for _,edit in ipairs(plan.sources) do if edit.before~=edit.after then changed[#changed+1]=edit end end
  plan.sources=changed
  return M.validate(session,plan)
end
function M.snapshot(session,plan)
  M.validate(session,plan)
  local result=vim.deepcopy(session.snapshot)
  for _,edit in ipairs(plan.sources) do result[edit.path]=edit.after end
  return result
end
return M
