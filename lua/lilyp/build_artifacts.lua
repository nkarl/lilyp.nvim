local outcome=require('lilyp.operation_outcome')
-- Generation storage and recoverable per-file publication, separate from jobs.
local fs=require('lilyp.fs')
local index=require('lilyp.source_index')
local M={}
function M.lock(directory)
  return require('lilyp.file_lock').acquire(directory..'/.score-build.lock')
end
function M.generation(directory,format)
  return assert(vim.uv.fs_mkdtemp(directory..'/'..format..'-XXXXXX'))
end
function M.publish(context,generation,format,before,signatures,log,started,recovering)
  for path,hash in pairs(before) do
    assert(index.signature(path)==signatures[path] and vim.fn.sha256(fs.read(path))==hash,'Source changed during compilation; rebuild: '..path)
  end
  assert(not vim.uv.fs_lstat(context.root..'/.lilypond-curator.lock'),'Apply is publishing; rebuild after it finishes')
  local artifact={format=format,log=log,directory=generation}
  if format=='svg' then
    local paths={}
    local single=generation..'/'..context.name..'.svg'
    if vim.fn.filereadable(single)==1 then paths={single}
    else
      local numbered={}
      for name,kind in vim.fs.dir(generation) do
        local number=name:sub(#context.name+1):match('^%-(%d+)%.svg$')
        if kind=='file' and name:sub(1,#context.name)==context.name and number then numbered[#numbered+1]={tonumber(number),generation..'/'..name} end
      end
      table.sort(numbered,function(a,b)return a[1]<b[1]end)
      for _,item in ipairs(numbered) do paths[#paths+1]=item[2] end
    end
    assert(#paths>0,'Compiler produced no SVG pages')
    local raw={};for _,path in ipairs(paths) do raw[#raw+1]=fs.read(path) end
    local pages,entries=require('lilyp.svg').index(raw)
    local sources=vim.deepcopy(before)
    for _,entry in ipairs(entries) do
      if not sources[entry.source] then
        local stat=assert(vim.uv.fs_stat(entry.source),'Missing linked source: '..entry.source)
        local created=started or assert(vim.uv.fs_stat(generation)).birthtime
        assert(stat.mtime.sec<created.sec or (stat.mtime.sec==created.sec and stat.mtime.nsec<=created.nsec),'Untracked include changed during build: '..entry.source)
        sources[entry.source]=vim.fn.sha256(fs.read(entry.source))
      end
    end
    local manifest={revision=vim.fs.basename(generation),pages=pages,entries=entries,sources=sources,main=context.main,root=context.root}
    manifest.origins=require('lilyp.source_origin').capture(entries,sources,context.root)
    local manifest_path=generation..'/manifest.json'
    fs.atomic(manifest_path,vim.json.encode(manifest))
    artifact.manifest,artifact.pages=context.manifest,paths
  else
    assert(vim.fn.filereadable(generation..'/'..context.name..'.pdf')==1,'Compiler produced no PDF')
    artifact.pdf=context.pdf
  end
  local writes={}
  if format=='svg' then
    for name,kind in vim.fs.dir(generation) do
      if kind=='file' and (name:match('%.midi$') or name:match('%.mid$')) then writes[#writes+1]={path=context.directory..'/'..name,text=fs.read(generation..'/'..name)} end
    end
    writes[#writes+1]={path=context.manifest,text=vim.json.encode({manifest=generation..'/manifest.json'})}
  else writes[#writes+1]={path=context.pdf,text=fs.read(generation..'/'..context.name..'.pdf')} end
  local published={}
  local ok,err=pcall(function()
    for _,write in ipairs(writes) do
      write.existed=vim.fn.filereadable(write.path)==1
      write.original=write.existed and fs.read(write.path) or nil
      fs.atomic(write.path,write.text);published[#published+1]=write
    end
  end)
  if not ok then
    if recovering then recovering() end
    local failures={}
    for i=#published,1,-1 do
      local write=published[i]
      local restored,failure=pcall(function()
        assert(fs.read(write.path)==write.text,'Output changed externally: '..write.path)
        if write.existed then fs.atomic(write.path,write.original) else assert(vim.uv.fs_unlink(write.path)) end
      end)
      if not restored then failures[#failures+1]=tostring(failure) end
    end
    error(outcome.failed(tostring(err)..(#failures>0 and '\nRollback needs attention: '..table.concat(failures,'\n') or '\nPrevious output restored.'),
      #failures>0 and 'partial' or (#published>0 and 'restored' or 'unchanged')),0)
  end
  return artifact
end
return M
