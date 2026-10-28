-- Capture compiler origins and bounded, read-only musical context against
-- compiled source hashes. These snapshots never grant edit capabilities.
local fs=require('lilyp.fs')
local M={}
local inspection=require('lilyp.inspection')
local structural={tuplet=true,key=true,time=true,tempo=true,alternative=true,
  relative=true,absolute=true,fixed=true,new=true,context=true,score=true,layout=true,midi=true,
  partial=true,clef=true,bar=true,slashedGrace=true,acciaccatura=true,grace=true}
structural['repeat']=true
local function path_label(path,root)
  if path:sub(1,#root+1)==root..'/' then return path:sub(#root+2) end
  return vim.fn.fnamemodify(path,':~')
end
function M.unavailable(entry,root)
  return {kind='unknown',available=false,path=path_label(entry.source,root),line=entry.line,column=entry.char+1,
    before='',focus='',after='',truncated_left=false,truncated_right=false,inspection=inspection.unsupported()}
end
local function describe(entry,root,line)
  local result=M.unavailable(entry,root)
  if not line then return result end
  line=line:gsub('\r$','')
  local length=vim.str_utfindex(line,'utf-32')
  if entry.char>length then return result end
  local start=vim.str_byteindex(line,'utf-32',entry.char)
  local rest=line:sub(start+1)
  local command=rest:match('^\\([%a_][%w_%-]*)')
  local token
  if command then
    token='\\'..command
    result.kind=structural[command] and 'structural' or 'macro'
  elseif rest:match('^[{}<>|%[%]()]') then token=rest:sub(1,1);result.kind='structural'
  else
    token=rest:match('^([^%s\\{}<>|%[%]()%%"]+)')
    result.kind=token and 'token' or 'unknown'
  end
  local token_length=token and vim.str_utfindex(token,'utf-32') or math.min(1,length-entry.char)
  local left=math.max(0,entry.char-60)
  local focus_end=math.min(length,entry.char+math.min(token_length,80))
  local right=math.min(length,focus_end+120)
  local function slice(a,b)return line:sub(vim.str_byteindex(line,'utf-32',a)+1,vim.str_byteindex(line,'utf-32',b))end
  result.available=true
  result.before,result.focus,result.after=slice(left,entry.char),slice(entry.char,focus_end),slice(focus_end,right)
  result.truncated_left,result.truncated_right=left>0,right<length
  return result
end
function M.capture(entries,sources,root)
  local files,raws,origins,analyzers,counts,seen,symbols={},{},{},{},{},{},{}
  for path,hash in pairs(sources) do
    if path:match('%.i?ly$') then
      local raw=fs.read(path)
      assert(vim.fn.sha256(raw)==hash,'Source changed before its compiled preview was captured: '..path)
      raws[path]=raw
    end
  end
  local music=require('lilyp.music_context')
  local guard=music.guard(raws)
  for _,entry in ipairs(entries) do
    local identity=vim.json.encode({entry.source,entry.line,entry.char})
    counts[identity]=(counts[identity] or 0)+1
  end
  for _,entry in ipairs(entries) do
    if not files[entry.source] then
      local raw=raws[entry.source] or fs.read(entry.source)
      assert(sources[entry.source] and vim.fn.sha256(raw)==sources[entry.source],
        'Source changed before its compiled preview was captured: '..entry.source)
      files[entry.source]=vim.split(raw,'\n',{plain=true})
      analyzers[entry.source]=music.analyzer(raw,guard)
      symbols[entry.source]=require('lilyp.symbol_context').analyzer(raw,guard)
    end
    local lines=files[entry.source]
    local origin=describe(entry,root,lines[entry.line])
    local identity=vim.json.encode({entry.source,entry.line,entry.char})
    origin.linked_objects=counts[identity]
    seen[identity]=(seen[identity] or 0)+1;origin.occurrence=seen[identity]
    if origin.available then
      local byte=vim.str_byteindex(lines[entry.line]:gsub('\r$',''),'utf-32',entry.char)+1
      for line=1,entry.line-1 do byte=byte+#lines[line]+1 end
      origin.inspection=inspection.choose(analyzers[entry.source](byte),symbols[entry.source](byte))
    end
    origins[#origins+1]=origin
  end
  return origins
end
return M
