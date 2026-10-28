-- Format-independent source identity, freshness, and character/byte conversion.
local fs=require('lilyp.fs')
local M={}
function M.canonical(path) return vim.uv.fs_realpath(path) or vim.fs.normalize(path) end
function M.parse_uri(uri)
  local path,line,char=uri:match('^textedit://(.*):(%d+):(%d+):%d*$')
  if not path or tonumber(line)<1 then return nil end
  path=path:gsub('%%(%x%x)',function(hex)return string.char(tonumber(hex,16))end)
  if path:sub(1,1)~='/' or path:find('\0',1,true) then return nil end
  return {source=M.canonical(path),line=tonumber(line),char=tonumber(char)}
end
function M.signature(path)
  local stat=vim.uv.fs_stat(path)
  if not stat or stat.type~='file' then return nil end
  return table.concat({stat.dev,stat.ino,stat.size,stat.mtime.sec,stat.mtime.nsec,stat.ctime.sec,stat.ctime.nsec},':')
end
function M.snapshot(root,main,includes)
  local pending,hashes,signatures={M.canonical(main)},{},{}
  local function visit(directory)
    for name,kind in vim.fs.dir(directory) do
      local path=directory..'/'..name
      if kind=='directory' and name~='build' and name~='.git' and name~='backups' then visit(path)
      elseif kind=='file' and not name:match('%.otter%.scm$')
        and (name:match('%.i?ly$') or name:match('%.scm$') or name=='score.yaml') then pending[#pending+1]=M.canonical(path) end
    end
  end
  visit(root)
  while #pending>0 do
    local path=table.remove(pending)
    if not hashes[path] then
      local raw=fs.read(path)
      hashes[path]=vim.fn.sha256(raw);signatures[path]=M.signature(path)
      for name in raw:gmatch('\92include%s+"([^"\n]+)"') do
        for _,parent in ipairs(vim.list_extend({vim.fs.dirname(path),root},includes or {})) do
          local candidate=name:sub(1,1)=='/' and name or parent..'/'..name
          if vim.fn.filereadable(candidate)==1 then pending[#pending+1]=M.canonical(candidate);break end
        end
      end
    end
  end
  return hashes,signatures
end
-- Cache hashes by file identity/timestamps. Polling the viewer never calls this;
-- directory notifications and explicit navigation perform freshness checks.
function M.fresh(sources,cache)
  cache=cache or {}
  local fresh=true
  for path,expected in pairs(sources) do
    local signature=M.signature(path)
    local previous=cache[path]
    if not previous or previous.signature~=signature then
      local ok,raw=pcall(fs.read,path)
      previous={signature=signature,hash=ok and vim.fn.sha256(raw) or false}
      cache[path]=previous
    end
    if previous.hash~=expected then fresh=false end
  end
  return fresh
end
function M.assert_fresh(sources,cache)
  assert(M.fresh(sources,cache),'Source changed since SVG compilation. Rebuild with F5.')
end
function M.locate(entries,source,line,column,occurrence)
  source=M.canonical(source);occurrence=occurrence or 1
  assert(type(line)=='number' and line>=1 and line%1==0 and type(column)=='number' and column>=0 and column%1==0,'Invalid source cursor position')
  local text=vim.fn.readfile(source)[line]
  assert(text and column<=#text,'Cursor is outside the source line')
  local char=vim.str_utfindex(text,'utf-32',column)
  local position=-1
  for _,entry in ipairs(entries) do
    if entry.source==source and entry.line==line and entry.char<=char then position=math.max(position,entry.char) end
  end
  if position>=0 then
    local start=vim.str_byteindex(text,'utf-32',position)
    local segment=text:sub(start+1,column+1)
    if segment~='' and not segment:find('[%s\92{}<>|%%]') then
      local matches={}
      for _,entry in ipairs(entries) do
        if entry.source==source and entry.line==line and entry.char==position then matches[#matches+1]=entry end
      end
      assert(type(occurrence)=='number' and occurrence%1==0 and occurrence>=1 and occurrence<=#matches,'That printed occurrence does not exist (found '..#matches..')')
      return matches[occurrence],#matches
    end
  end
  error('No printed note at the cursor. Place it on a note/chord and rebuild with F5 if needed.')
end
function M.byte_column(entry)
  local line=assert(vim.fn.readfile(entry.source)[entry.line],'Source line no longer exists')
  return vim.str_byteindex(line,'utf-32',entry.char)
end
return M
