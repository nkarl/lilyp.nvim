local M={}
-- Exact-byte in-memory cache shared by raw and normalized consumers.
local reads={}
local function call(request)
  if request.action=='read' then
    for index,entry in ipairs(reads) do
      if entry.text==request.text then
        table.remove(reads,index);table.insert(reads,1,entry)
        return vim.deepcopy(entry.value)
      end
    end
  end
  local value=require('lilyp.yaml').request(request)
  if request.action=='read' and not value._error then
    table.insert(reads,1,{text=request.text,value=vim.deepcopy(value)})
    if #reads>8 then reads[#reads]=nil end
  end
  return value
end
local function call_async(request,done)
  -- Preserve deferred delivery for hits, misses, and failures. Snapshot inputs
  -- before yielding so callers cannot redirect an outstanding request.
  request=vim.deepcopy(request)
  vim.schedule(function()
    local ok,value=pcall(call,request)
    if ok then done(value) else done(nil,tostring(value)) end
  end)
end
-- Compatibility transport for the preservation writer and raw metadata callers.
local function parse_error(value)
  if value and value._error then
    local result=require('lilyp.project_document').from_parse(value)
    return result.diagnostics[1]
  end
end
function M.call(request)
  local value=call(request)
  local err=parse_error(value)
  if err then error('YAML helper failed: '..tostring(err),0) end
  return value
end
function M.call_async(request,done)
  return call_async(request,function(value,err)
    local invalid=parse_error(value)
    if invalid then return done(nil,'YAML helper failed: '..tostring(invalid)) end
    done(value,err)
  end)
end
function M.inspect(text)
  return require('lilyp.project_document').from_parse(call({action='read',text=text}),text)
end
function M.read(text)
  local result=M.inspect(text)
  if result.tag=='invalid' then error(result.diagnostics[1],0) end
  return result.document
end
function M.inspect_async(text,done)
  return call_async({action='read',text=text},function(value,err)
    if err then return done(nil,err) end
    done(require('lilyp.project_document').from_parse(value,text))
  end)
end
function M.read_async(text,done)
  return M.inspect_async(text,function(result,err)
    if err then return done(nil,err) end
    if result.tag=='invalid' then return done(nil,result.diagnostics[1]) end
    done(result.document)
  end)
end
return M
