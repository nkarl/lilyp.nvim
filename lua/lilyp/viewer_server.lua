-- Bounded HTTP/1.x transport for a private, loopback-only viewer. One request per
-- connection; chunked bodies, duplicate headers, and arbitrary routes are rejected.
local M={}
local uv=vim.uv
local CSP="default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; connect-src 'self'; font-src 'self'; img-src data:; frame-ancestors 'none'; base-uri 'none'"
function M.start(route)
  local listener=assert(uv.new_tcp())
  local clients={}
  local stopped=false
  local random=assert(uv.random(32))
  local token=random:gsub('.',function(char)return string.format('%02x',char:byte())end)
  local ok,err=listener:bind('127.0.0.1',0)
  if not ok then listener:close();error(err) end
  local port=listener:getsockname().port
  local host='127.0.0.1:'..port
  local origin='http://'..host
  local prefix='/'..token..'/'
  local function close(client)
    local state=clients[client]
    if not state then return end
    clients[client]=nil
    state.timer:stop();state.timer:close()
    if not client:is_closing() then client:read_stop();client:close() end
  end
  local function respond(client,status,body,mime)
    local state=clients[client]
    if not state or state.responded then return end
    state.responded=true
    client:read_stop()
    local reasons={[200]='OK',[400]='Bad Request',[403]='Forbidden',[404]='Not Found',[408]='Request Timeout',[413]='Payload Too Large',[431]='Request Header Fields Too Large',[500]='Internal Server Error',[503]='Service Unavailable'}
    local headers={'HTTP/1.1 '..status..' '..(reasons[status] or 'Error'),
      'Content-Type: '..(mime or 'application/json'), 'Content-Length: '..#body,
      'Connection: close','Cache-Control: no-store','X-Content-Type-Options: nosniff',
      'Referrer-Policy: no-referrer','Content-Security-Policy: '..CSP,'',''}
    local written=client:write(table.concat(headers,'\r\n')..body,function()close(client)end)
    if not written then close(client) end
  end
  local listening,failure=listener:listen(32,function(accept_error)
    if accept_error or stopped then return end
    local client=assert(uv.new_tcp())
    if not listener:accept(client) then client:close();return end
    local count=0;for _ in pairs(clients) do count=count+1 end
    if count>=32 then client:close();return end
    local state={buffer='',timer=assert(uv.new_timer())}
    clients[client]=state
    state.timer:start(5000,0,function()close(client)end)
    client:read_start(function(read_error,chunk)
      if read_error or not chunk then close(client);return end
      if state.dispatched then return end
      state.buffer=state.buffer..chunk
      if #state.buffer>20480 then respond(client,413,'{"error":"Request too large"}');return end
      if not state.headers then
        local boundary=state.buffer:find('\r\n\r\n',1,true)
        if not boundary then
          if #state.buffer>16384 then respond(client,431,'{}') end
          return
        end
        if boundary>16384 then respond(client,431,'{}');return end
        local lines=vim.split(state.buffer:sub(1,boundary-1),'\r\n',{plain=true})
        local method,target,version=lines[1]:match('^(%u+) ([^%s]+) HTTP/(1%.[01])$')
        if not method or (method~='GET' and method~='POST') then respond(client,400,'{}');return end
        local headers={}
        for i=2,#lines do
          local name,value=lines[i]:match('^([%w%-]+):[ \t]*(.-)[ \t]*$')
          if not name or headers[name:lower()] then respond(client,400,'{}');return end
          headers[name:lower()]=value
        end
        if headers.host~=host or target:sub(1,#prefix)~=prefix then respond(client,403,'{}');return end
        if headers['transfer-encoding'] or (headers.origin and headers.origin~=origin)
          or (method=='POST' and headers.origin~=origin) then respond(client,403,'{}');return end
        local size=headers['content-length'] or '0'
        if not size:match('^%d+$') or #size>5 then respond(client,400,'{}');return end
        size=tonumber(size)
        if size>4096 or (method=='GET' and size~=0) then respond(client,413,'{}');return end
        if method=='POST' and (size==0 or headers['content-type']~='application/json') then respond(client,400,'{}');return end
        state.headers,state.size,state.offset=headers,size,boundary+4
        state.method,state.target=method,target:sub(#prefix+1)
      end
      if #state.buffer<state.offset+state.size-1 then return end
      if #state.buffer~=state.offset+state.size-1 then respond(client,400,'{}');return end
      state.dispatched=true;client:read_stop()
      local body=state.buffer:sub(state.offset)
      vim.schedule(function()
        if stopped or not clients[client] then return end
        local success,status,response,mime=pcall(route,state.method,state.target,body)
        if not success then
          respond(client,400,vim.json.encode({error=tostring(status)}))
        else
          respond(client,status,type(response)=='string' and response or vim.json.encode(response),mime)
        end
      end)
    end)
  end)
  if not listening then listener:close();error(failure) end
  local server={url=origin..prefix}
  function server.close()
    if stopped then return end
    stopped=true
    for client in pairs(clients) do close(client) end
    if not listener:is_closing() then listener:close() end
  end
  return server
end
return M
