-- In-process YAML syntax through libyaml; construction, locations and scoped
-- preservation writes belong to Lua. No subprocess, project writes or defaults.
local M={}
local NULL=vim.NIL
local function failure(kind,message,path,mark)
  error({kind=kind,message=message,path=path or {},location={line=mark and mark.line or 1,column=mark and mark.column or 1}},0)
end
local function position(mark)
  return {index=tonumber(mark.index),line=tonumber(mark.line)+1,column=tonumber(mark.column)+1}
end
local function append(path,key)local p=vim.deepcopy(path);p[#p+1]=key;return p end
local function scalar(node)
  local value,tag=node.raw,node.tag
  local explicit=tag~=nil and tag~='!'
  if tag=='!' or tag=='tag:yaml.org,2002:str' or not explicit and node.style~=1 then return value end
  local kind=tag and tag:match('^tag:yaml.org,2002:(.+)$')
  if explicit and not kind then failure('Syntax','Unsupported YAML tag: '..tag,{},node.start) end
  local lower=value:lower()
  local caseword=value==lower or value==value:upper() or value==lower:gsub('^%l',string.upper)
  if kind=='null' or not explicit and (value=='' or value=='~' or lower=='null' and caseword) then return NULL end
  local booleans={yes=true,no=false,on=true,off=false,['true']=true,['false']=false}
  if kind=='bool' or not explicit and caseword and booleans[lower]~=nil then
    if booleans[lower]==nil then failure('Syntax','Invalid YAML boolean',{},node.start) end
    return booleans[lower]
  end
  local number=value:gsub('_','')
  local unsigned=number:gsub('^[+-]','')
  local sign=number:sub(1,1)=='-' and -1 or 1
  local integer=unsigned=='0' or unsigned:match('^[1-9]%d*$') or unsigned:match('^0[0-7]+$') or unsigned:match('^0x[%da-fA-F]+$') or unsigned:match('^0b[01]+$')
  local sexagesimal=unsigned:match('^[1-9]%d*:') and not unsigned:find('[^%d:%.]')
  if sexagesimal then
    local first=true
    for part in unsigned:gmatch('[^:]+') do
      if not first and (not tonumber(part) or tonumber(part)>=60) then sexagesimal=false end
      first=false
    end
    if unsigned:find('::',1,true) or unsigned:sub(-1)==':' then sexagesimal=false end
  end
  if kind=='int' or not explicit and (integer or sexagesimal and not number:find('%.')) then
    local result
    if sexagesimal then
      result=0;for part in unsigned:gmatch('[^:]+') do result=result*60+tonumber(part) end
    elseif unsigned:match('^0b') then result=tonumber(unsigned:sub(3),2)
    elseif unsigned:match('^0x') then result=tonumber(unsigned:sub(3),16)
    elseif #unsigned>1 and unsigned:sub(1,1)=='0' then result=tonumber(unsigned,8)
    else result=tonumber(unsigned) end
    if result then return sign*result end
    if explicit then failure('Syntax','Invalid YAML integer',{},node.start) end
  end
  local mantissa,exponent=number:match('^(.-)([eE].*)$')
  local decimal=mantissa or number
  local float=(decimal:match('^[+-]?%d+%.%d*$') or decimal:match('^%.%d+$')) and (not exponent or exponent:match('^[eE][+-]%d+$'))
    or sexagesimal and number:find('%.')
    or unsigned:match('^%.inf$') or unsigned:match('^%.Inf$') or unsigned:match('^%.INF$')
    or number=='.nan' or number=='.NaN' or number=='.NAN'
  if kind=='float' or not explicit and float then
    if lower=='.inf' or lower=='+.inf' then return math.huge end
    if lower=='-.inf' then return -math.huge end
    if lower=='.nan' then return 0/0 end
    local result=tonumber(number)
    if sexagesimal then result=0;for part in unsigned:gmatch('[^:]+') do result=result*60+tonumber(part) end;result=result*sign end
    if result then return result end
    if explicit then failure('Syntax','Invalid YAML float',{},node.start) end
  end
  if kind=='binary' then
    local ok,decoded=pcall(vim.base64.decode,value:gsub('%s',''))
    if not ok then failure('Syntax','Invalid YAML binary scalar',{},node.start) end
    return decoded
  end
  if kind and kind~='timestamp' then failure('Syntax','Unsupported YAML scalar tag: '..tag,{},node.start) end
  -- Dates and sets in unrelated metadata remain represented for semantic checks;
  -- only selected manifest fields cross the normalized project boundary.
  if kind=='timestamp' or not explicit and (value:match('^%d%d%d%d%-%d%d%-%d%d$') or value:match('^%d%d%d%d%-%d%d?%-%d%d?[Tt%s]%d%d?:%d%d:%d%d')) then
    return {yaml_tag='timestamp',value=value}
  end
  return value
end
function M.parse(text)
  local binding=require('lilyp.vendor.libyaml')
  local ffi,lib=binding.ffi,binding.lib
  local parser=ffi.new('yaml_parser_t[1]')
  assert(lib.yaml_parser_initialize(parser)==1,'Could not initialize libyaml')
  -- The Lua string remains strongly referenced until parser deletion.
  lib.yaml_parser_set_input_string(parser,text,#text)
  local event=ffi.new('yaml_event_t[1]')
  local function next_event()
    if lib.yaml_parser_parse(parser,event)==0 then
      failure('Syntax',parser[0].problem~=nil and ffi.string(parser[0].problem) or 'Invalid YAML',{},position(parser[0].problem_mark))
    end
    local e=event[0]
    local result={type=tonumber(e.type),start=position(e.start_mark),finish=position(e.end_mark)}
    local data=result.type==6 and e.data.scalar or result.type==7 and e.data.sequence_start or result.type==9 and e.data.mapping_start
    if data then
      result.anchor=data.anchor~=nil and ffi.string(data.anchor) or nil
      result.tag=data.tag~=nil and ffi.string(data.tag) or nil
      result.style=tonumber(data.style)
      if result.type==6 then result.raw=ffi.string(data.value,data.length) end
    elseif result.type==5 then result.alias=ffi.string(e.data.alias.anchor) end
    lib.yaml_event_delete(event)
    return result
  end
  local ok,result=xpcall(function()
    assert(next_event().type==1,'Missing YAML stream')
    local first=next_event()
    if first.type==2 then return {root=nil,data=NULL,locations={}} end
    assert(first.type==3,'Missing YAML document')
    local anchors={}
    local read
    read=function(e,depth)
      if depth>256 then failure('Syntax','YAML nesting exceeds 256 levels',{},e.start) end
      if e.type==5 then
        local target=anchors[e.alias]
        if not target then failure('Syntax','Unknown YAML alias: '..e.alias,{},e.start) end
        return {kind='alias',target=target,start=e.start,finish=e.finish}
      end
      local node={kind=({[6]='scalar',[7]='sequence',[9]='mapping'})[e.type],start=e.start,finish=e.finish,style=e.style,tag=e.tag,raw=e.raw}
      if not node.kind then failure('Syntax','Expected a YAML value',{},e.start) end
      if e.anchor then
        if anchors[e.anchor] then failure('Syntax','Duplicate YAML anchor: '..e.anchor,{},e.start) end
        anchors[e.anchor]=node
      end
      if e.type~=6 then
        node.children={}
        while true do
          local child=next_event()
          if child.type==(e.type==7 and 8 or 10) then node.finish=child.finish;break end
          local key=read(child,depth+1)
          if e.type==7 then node.children[#node.children+1]=key
          else node.children[#node.children+1]={key=key,value=read(next_event(),depth+1)} end
        end
      end
      return node
    end
    local root=read(next_event(),0)
    local ending=next_event()
    assert(ending.type==4,'Missing YAML document end')
    if next_event().type~=2 then failure('Syntax','Expected one YAML document',{},ending.finish) end
    local locations,active,constructed={},{},{}
    local construct
    local function target(node)return node.kind=='alias' and node.target or node end
    local function locate(node,path,keymark,ancestors)
      node=target(node)
      if #locations>=65536 then failure('Syntax','YAML exceeds 65536 expanded source locations',path,node.start) end
      locations[#locations+1]={path=vim.deepcopy(path),kind=node.kind,key=keymark or node.start,value=node.start,finish=node.finish}
      if ancestors[node] then return end
      ancestors[node]=true
      if node.kind=='mapping' then
        for _,pair in ipairs(node.children) do
          local key=target(pair.key)
          if key.kind=='scalar' then locate(pair.value,append(path,key.raw),pair.key.start,ancestors) end
        end
      elseif node.kind=='sequence' then
        for n,child in ipairs(node.children) do locate(child,append(path,n),nil,ancestors) end
      end
      ancestors[node]=nil
    end
    locate(root,{},nil,{})
    construct=function(node,path)
      node=target(node)
      if active[node] then failure('Syntax','Recursive YAML aliases are not supported',path,node.start) end
      if constructed[node]~=nil then return constructed[node] end
      active[node]=true
      local value
      if node.kind=='scalar' then value=scalar(node)
      elseif node.kind=='sequence' then
        local pairs_tag=node.tag=='tag:yaml.org,2002:omap' or node.tag=='tag:yaml.org,2002:pairs'
        if node.tag and node.tag~='tag:yaml.org,2002:seq' and node.tag~='!' and not pairs_tag then
          failure('Syntax','Unsupported YAML sequence tag: '..node.tag,path,node.start)
        end
        value={}
        for n,child in ipairs(node.children) do
          if pairs_tag then
            child=target(child)
            if child.kind~='mapping' or #child.children~=1 then failure('Syntax','YAML ordered pairs require singleton mappings',path,child.start) end
            local pair=child.children[1]
            value[n]={construct(pair.key,append(path,n)),construct(pair.value,append(path,n))}
          else value[n]=construct(child,append(path,n)) end
        end
      else
        if node.tag and node.tag~='tag:yaml.org,2002:map' and node.tag~='tag:yaml.org,2002:set' and node.tag~='!' then
          failure('Syntax','Unsupported YAML mapping tag: '..node.tag,path,node.start)
        end
        value=vim.empty_dict()
        local seen,merges={},{}
        for _,pair in ipairs(node.children) do
          local keynode=target(pair.key)
          local merge=keynode.raw=='<<' and keynode.style==1 and (keynode.tag==nil or keynode.tag=='tag:yaml.org,2002:merge')
          if merge then merges[#merges+1]=pair.value
          else
            local key=construct(pair.key,path)
            local pathkey=keynode.raw or tostring(key)
            if type(key)=='table' then failure('Syntax','Complex YAML mapping keys are not supported',path,pair.key.start) end
            if seen[key] then failure('DuplicateKey','Duplicate YAML key: '..tostring(key),append(path,pathkey),pair.key.start) end
            seen[key]=true
            value[key]=construct(pair.value,append(path,pathkey))
          end
        end
        local function merge(node)
          node=target(node)
          if node.kind=='sequence' then for _,child in ipairs(node.children) do merge(child) end
          elseif node.kind=='mapping' then
            for k,v in pairs(construct(node,path)) do if value[k]==nil then value[k]=v end end
          else failure('Syntax','YAML merge expects a mapping or list of mappings',path,node.start) end
        end
        for _,node in ipairs(merges) do merge(node) end
      end
      active[node]=nil;constructed[node]=value
      return value
    end
    local data=construct(root,{})
    return {root=root,data=data,locations=locations}
  end,function(err)return err end)
  lib.yaml_parser_delete(parser)
  if not ok then error(result,0) end
  return result
end
local function encode_scalar(value)
  if value==NULL then return 'null' end
  if type(value)=='boolean' then return tostring(value) end
  if type(value)=='number' then assert(value==value and math.abs(value)~=math.huge,'Cannot emit nonfinite YAML');return tostring(value) end
  assert(type(value)=='string','Unsupported YAML value')
  return vim.json.encode(value)
end
local function emit(value,indent)
  if type(value)~='table' then return encode_scalar(value) end
  if next(value)==nil then return vim.islist(value) and '[]' or '{}' end
  local lines,pad={},string.rep(' ',indent)
  local list=vim.islist(value)
  local keys=list and {} or vim.tbl_keys(value)
  if list then for n=1,#value do keys[n]=n end else table.sort(keys) end
  for _,key in ipairs(keys) do
    local item=value[key]
    local label=list and '-' or (key:match('^[%a_][%w_%-]*$') and key or encode_scalar(key))..':'
    if type(item)=='table' and next(item) then
      lines[#lines+1]=pad..label..'\n'..emit(item,indent+2)
    else lines[#lines+1]=pad..label..' '..emit(item,indent+2) end
  end
  return table.concat(lines,'\n')
end
function M.request(request)
  local ok,parsed=pcall(M.parse,request.text)
  if not ok then
    if request.action=='read' and type(parsed)=='table' and parsed.kind then return {_error=parsed} end
    error(type(parsed)=='table' and parsed.message or parsed,0)
  end
  local data,root=parsed.data,parsed.root
  if type(data)~='table' or not root or root.kind~='mapping' or data.kind~='lilypond-score' then
    local mark=root and root.start
    if root and root.kind=='mapping' then for _,pair in ipairs(root.children) do if pair.key.raw=='kind' then mark=pair.value.start end end end
    local err={kind='InvalidKind',path={'kind'},message='Expected a lilypond-score YAML document',location=mark or {line=1,column=1}}
    if request.action=='read' then return {_error=err} end
    error(err.message,0)
  end
  if request.action=='read' then
    local metadata={}
    for _,key in ipairs({'presentation','source','sections','printed_order','staff_preset','voices','outputs'}) do metadata[key]=data[key] end
    for key,default in pairs({source=vim.empty_dict(),sections={},printed_order={},voices={},presentation=NULL,outputs=NULL,staff_preset=NULL}) do
      if metadata[key]==nil then metadata[key]=default end
    end
    metadata._yaml={kind=data.kind,schema_version=data.schema_version==nil and 1 or data.schema_version,locations=parsed.locations}
    return metadata
  end
  assert(request.action=='write' or request.action=='write-outputs','Unknown YAML action')
  local key=request.action=='write-outputs' and 'outputs' or 'presentation'
  local value=assert(request[key],'Missing YAML block value')
  assert(key~='presentation' or value.owner==nil,'Presentation metadata contains specification only; owner is not supported')
  local text=request.text
  local newline=text:match('\r?\n') or '\n'
  local block=(key..':\n'..emit(value,2)..'\n'):gsub('\n',newline)
  -- Empty blocks must stay on the key's line.
  if next(value)==nil then block=key..': '..emit(value,0)..newline end
  assert(root.style~=2,key..' must use an ordinary top-level YAML key')
  local selected
  for n,pair in ipairs(root.children) do if pair.key.raw==key then selected=n end end
  local result
  if selected then
    local field=root.children[selected].key
    local start=vim.str_byteindex(text,'utf-32',field.start.index)
    assert(field.style==1 and field.start.column==1 and text:sub(start+1):match('^'..key..'[ \t]*:'),key..' must use an ordinary top-level YAML key')
    local following=root.children[selected+1]
    local boundary=following and following.key.start or root.finish
    assert(not following or boundary.column==1,'Following metadata must use an ordinary top-level YAML key')
    local finish=vim.str_byteindex(text,'utf-32',boundary.index)
    assert(finish>start,'Invalid YAML block boundary')
    local segment=text:sub(start+1,finish)
    local lines=vim.split(segment,'\n',{plain=true})
    if lines[#lines]=='' then table.remove(lines) end
    for n=#lines,1,-1 do
      local line=lines[n]
      if vim.trim(line)~='' and line:sub(1,1)~='#' then break end
      finish=finish-#line-1
    end
    result=text:sub(1,start)..block..text:sub(finish+1)
  else
    assert(data[key]==nil,key..' must use an ordinary top-level YAML key')
    for line in text:gmatch('[^\r\n]+') do assert(not line:match('^%-%-%-%s*$') and not line:match('^%.%.%.%s*$'),'Document markers need explicit migration before specification initialization') end
    result=text..(text:sub(-1)=='\n' and '' or newline)..newline..block
  end
  local expected=vim.deepcopy(data);expected[key]=value
  assert(vim.deep_equal(M.parse(result).data,expected),'YAML update would change unrelated metadata')
  return {text=result}
end
return M
