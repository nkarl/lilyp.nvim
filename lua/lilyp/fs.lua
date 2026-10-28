local M={}
function M.read(path)
  local f=assert(io.open(path,'rb'));local text=f:read('*a');f:close();return text
end
function M.write(path,text)
  local f=assert(io.open(path,'wb'));assert(f:write(text));assert(f:close())
end
function M.inside(root,relative)
  assert(type(relative)=='string' and relative~='' and not relative:match('^/'),'Expected a relative project path')
  local path=vim.fs.normalize(root..'/'..relative)
  assert(vim.startswith(path,root..'/'),'Path escapes the project')
  local part=root
  for name in path:sub(#root+2):gmatch('[^/]+') do
    part=part..'/'..name
    local stat=vim.uv.fs_lstat(part)
    assert(not stat or stat.type~='link','Symlink paths require explicit migration: '..relative)
  end
  return path
end
local skip={build=true,backups=true,['.git']=true,['.lilypond-curator.lock']=true}
function M.snapshot(root)
  local files={}
  local function visit(folder,prefix)
    for name,kind in vim.fs.dir(folder) do
      if not skip[name] and not name:match('%.otter%.scm$') then
        local rel=prefix..name
        if kind=='directory' then visit(folder..'/'..name,rel..'/')
        elseif kind=='file' then files[rel]=M.read(folder..'/'..name)
        else error('Unsupported project entry (symlink/special file): '..rel) end
      end
    end
  end
  visit(root,'');return files
end
function M.assert_clean(root,snapshot)
  for _,buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified
      and vim.startswith(vim.api.nvim_buf_get_name(buf),root..'/') then
      error('Save or discard unsaved project edits before preview/apply: '..vim.api.nvim_buf_get_name(buf))
    end
  end
  assert(vim.deep_equal(snapshot,M.snapshot(root)),'Project changed outside the curator; close and reload the project')
end
function M.stage(snapshot)
  local root=vim.fn.tempname()
  local made,failure=vim.uv.fs_mkdir(root,448)
  assert(made,'Could not create a new staging directory: '..root..' ('..tostring(failure)..')')
  local ok,err=pcall(function()
    for rel,text in pairs(snapshot) do
      local path=M.inside(root,rel);vim.fn.mkdir(vim.fs.dirname(path),'p');M.write(path,text)
    end
  end)
  if not ok then vim.fn.delete(root,'rf');error(err,0) end
  return root
end
function M.atomic(path,text)
  local temp=path..'.curator-'..vim.fn.getpid()..'-'..vim.uv.hrtime()
  local previous=vim.uv.fs_stat(path)
  local mode=previous and bit.band(previous.mode,511) or 420
  local fd=assert(vim.uv.fs_open(temp,'wx',mode))
  local offset=0
  local ok,err=pcall(function()
    while offset<#text do
      local n=assert(vim.uv.fs_write(fd,text:sub(offset+1),offset));assert(n>0);offset=offset+n
    end
    assert(vim.uv.fs_fsync(fd))
  end)
  vim.uv.fs_close(fd)
  if not ok then vim.uv.fs_unlink(temp);error(err) end
  local moved,failure=vim.uv.fs_rename(temp,path)
  if not moved then vim.uv.fs_unlink(temp);error(failure) end
end
return M
