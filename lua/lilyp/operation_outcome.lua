-- Completion facts, independent of UI wording and process exit status.
local M={}
local meta={__tostring=function(value)return M.message(value)end}
local function issues(value)
  assert(type(value)=='table','Cleanup issues must be a list')
  for key,item in pairs(value) do assert(type(key)=='number' and key>=1 and key%1==0 and key<=#value and type(item)=='string','Invalid cleanup issue') end
  return value
end
function M.assert_valid(value)
  assert(type(value)=='table','Expected an operation outcome')
  assert(value.tag=='succeeded' or value.tag=='cancelled' or value.tag=='failed','Unknown operation outcome')
  issues(value.cleanup)
  local allowed={tag=true,cleanup=true}
  if value.tag~='cancelled' then
    allowed.publication=true
    assert(value.publication=='unchanged' or value.publication=='published' or value.publication=='restored' or value.publication=='partial','Unknown publication effect')
  end
  if value.tag=='succeeded' then
    allowed.value=true
    assert(value.publication=='unchanged' or value.publication=='published','Success cannot describe rollback')
  elseif value.tag=='failed' then
    allowed.error=true;assert(type(value.error)=='string' and value.error~='','Failure needs an error')
  end
  for key in pairs(value) do assert(allowed[key],'Unexpected outcome payload: '..tostring(key)) end
  return value
end
local function make(value)return setmetatable(M.assert_valid(value),meta)end
function M.succeeded(value,publication,cleanup)return make({tag='succeeded',value=value,publication=publication or 'unchanged',cleanup=cleanup or {}})end
function M.cancelled(cleanup)return make({tag='cancelled',cleanup=cleanup or {}})end
function M.failed(err,publication,cleanup)return make({tag='failed',error=tostring(err),publication=publication or 'unchanged',cleanup=cleanup or {}})end
function M.is(value)return type(value)=='table' and getmetatable(value)==meta end
function M.from_error(err)
  if M.is(err) then return M.assert_valid(err) end
  return M.failed(err)
end
function M.message(value)
  M.assert_valid(value)
  local message
  if value.tag=='cancelled' then message='Operation cancelled; nothing was published.'
  elseif value.tag=='failed' then message=(value.publication=='published' and 'Published, but follow-up failed: ' or '')..value.error
  else message=type(value.value)=='string' and value.value or (value.publication=='published' and 'Published.' or 'Done') end
  if #value.cleanup>0 then message=message..'\nCleanup needs attention:\n'..table.concat(value.cleanup,'\n') end
  return message
end
return M
