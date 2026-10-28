local M={}

function M.location(root,standalone,metadata)
  local location=require('lilyp').options().build_location or 'temporary'
  if root then
    local stat=vim.uv.fs_lstat(vim.fs.joinpath(root,'build'))
    if stat and stat.type=='directory' then return 'project' end
    if not standalone then
      if not metadata and vim.fn.filereadable(root..'/score.yaml')==1 then
        metadata=require('lilyp.spec').read(require('lilyp.fs').read(root..'/score.yaml'))
      end
      if metadata then
        require('lilyp.project_document').assert_valid(metadata)
        if metadata.outputs.tag=='explicit' then location=metadata.outputs.value end
      end
    end
  end
  assert(location=='temporary' or location=='project','build_location must be temporary or project')
  return location
end

-- Resolution is read-only. Use a canonical identity so included files and aliases agree.
function M.directory(root,standalone)
  if M.location(root,standalone)=='project' then return vim.fs.joinpath(root,'build') end
  local identity=vim.uv.fs_realpath(standalone or root) or vim.fs.normalize(standalone or root)
  return '/tmp/lilyp-'..vim.uv.getuid()..'/'..vim.fn.sha256(identity)
end

local function private_directory(path)
  local stat=vim.uv.fs_lstat(path)
  if not stat then
    local ok,err=vim.uv.fs_mkdir(path,448)
    stat=vim.uv.fs_lstat(path)
    assert(ok or stat,err)
  end
  assert(stat.type=='directory' and stat.uid==vim.uv.getuid()
    and bit.band(stat.mode,63)==0,'Unsafe temporary build directory: '..path)
end

function M.ensure(root,standalone)
  local directory=M.directory(root,standalone)
  local build=vim.fs.joinpath(root,'build')
  local stat=vim.uv.fs_lstat(build)
  assert(not stat or stat.type=='directory' or stat.type=='link','build must be a directory or symlink: '..build)
  if directory~=build then
    private_directory(vim.fs.dirname(directory))
    private_directory(directory)
    if not standalone then
      -- Replace the link only, never its previous target. This also repairs links
      -- after moving a project, or after the target was cleaned from /tmp.
      if stat and stat.type=='link' and vim.uv.fs_readlink(build)~=directory then
        assert(vim.uv.fs_unlink(build));stat=nil
      end
      if not stat then assert(vim.uv.fs_symlink(directory,build)) end
    end
  else
    if stat and stat.type=='link' then assert(vim.uv.fs_unlink(build)) end
    require('lilyp.fs').inside(root,'build')
    assert(vim.fn.mkdir(directory,'p')==1 or vim.fn.isdirectory(directory)==1,
      'Could not create build directory: '..directory)
  end
  return directory
end

-- Read-only planning; existing real build directories become an explicit local
-- preference. Only an explicit rebuild or Apply publishes the revised YAML.
function M.specification(root,text)
  local spec=require('lilyp.spec')
  local metadata=spec.read(text)
  if M.location(root,nil,metadata)~='project' then return text end
  local outputs=vim.deepcopy(metadata.outputs.declarations)
  if outputs.location=='project' and outputs.directory=='build/' then return text end
  outputs.location='project';outputs.directory='build/'
  return spec.call({action='write-outputs',text=text,outputs=outputs}).text
end

function M.ignore(root,text)
  if not text or M.location(root)~='temporary' then return text end
  -- The old directory-only rule would leave the new build symlink unignored.
  return (text:gsub('[^\n]+',function(line)
    if line=='/build/' then return '/build' end
    if line=='/build/\r' then return '/build\r' end
    return line
  end))
end

function M.record(root)
  local fs=require('lilyp.fs')
  local writes={}
  for _,relative in ipairs({'score.yaml','.gitignore'}) do
    local path=fs.inside(root,relative)
    if vim.fn.filereadable(path)==1 then
      local text=fs.read(path)
      local revised=relative=='score.yaml' and M.specification(root,text) or M.ignore(root,text)
      if revised~=text then writes[#writes+1]={path=path,before=text,after=revised} end
    end
  end
  if #writes==0 then return end
  assert(not vim.uv.fs_lstat(root..'/.lilypond-curator.lock'),'An Apply operation lock exists; resolve it before updating the build preference')
  for _,item in ipairs(writes) do
    item.buffers={}
    for _,buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(buf)==item.path and vim.api.nvim_buf_is_loaded(buf) then
        assert(not vim.bo[buf].modified,'Save '..vim.fs.basename(item.path)..' before rebuilding')
        item.buffers[#item.buffers+1]=buf
      end
    end
    assert(fs.read(item.path)==item.before,'File changed while resolving the build location: '..item.path)
  end
  for _,item in ipairs(writes) do
    fs.atomic(item.path,item.after)
    for _,buf in ipairs(item.buffers) do vim.api.nvim_buf_call(buf,function()vim.cmd('silent edit')end) end
  end
end

return M
