-- Test-only loopback client. Drive Neovim's event loop while awaiting a response.
local M={}
function M.raw(port,request,chunks)
  local socket=assert(vim.uv.new_tcp())
  local output,failure,finished='',nil,false
  assert(socket:connect('127.0.0.1',port,function(err)
    if err then failure=err;finished=true;return end
    socket:read_start(function(read_error,data)
      if read_error then failure=read_error;finished=true
      elseif data then output=output..data else finished=true end
    end)
    if chunks then
      local split=math.floor(#request/2)
      socket:write(request:sub(1,split),function()socket:write(request:sub(split+1))end)
    else socket:write(request) end
  end))
  local done=vim.wait(6000,function()return finished end,5)
  if not socket:is_closing() then socket:read_stop();socket:close() end
  assert(done and not failure,failure or 'HTTP request timed out')
  local header,body=output:match('^(.-)\r\n\r\n(.*)$')
  assert(header,'Missing HTTP response: '..output)
  return tonumber(header:match('^HTTP/1%.1 (%d+)')),body,header
end
function M.request(url,target,data,extra)
  local port,prefix=url:match('^http://127%.0%.0%.1:(%d+)(/.*)$')
  assert(port and prefix)
  local payload=data and vim.json.encode(data) or ''
  local headers={Host='127.0.0.1:'..port,Origin='http://127.0.0.1:'..port,['Content-Type']='application/json',['Content-Length']=tostring(#payload)}
  for name,value in pairs(extra or {}) do headers[name]=value end
  local lines={(data and 'POST' or 'GET')..' '..prefix..target..' HTTP/1.1'}
  for name,value in pairs(headers) do lines[#lines+1]=name..': '..value end
  local status,body,response=M.raw(tonumber(port),table.concat(lines,'\r\n')..'\r\n\r\n'..payload)
  return status,body,response
end
function M.json(url,target,data,extra)
  local status,body,response=M.request(url,target,data,extra)
  local value=vim.json.decode(body)
  assert(status==200,body)
  return value,response
end
return M
