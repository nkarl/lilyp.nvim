-- Deliberate project-local source records. No save/build/Apply hooks.
local fs=require('lilyp.fs')
local M={}
local function canonical(path)
  if path=='' then return path end
  local real=vim.uv.fs_realpath(path)
  if real then return real end
  local parent=vim.uv.fs_realpath(vim.fs.dirname(path))
  return parent and vim.fs.joinpath(parent,vim.fs.basename(path)) or path
end
local function run(root,args,options,optional)
  options=options or {}
  local env=vim.fn.environ()
  for key in pairs(env) do if key:match('^GIT_') then env[key]=nil end end
  for key,value in pairs(options.env or {}) do env[key]=value end
  local command={'git','-C',root}
  vim.list_extend(command,args)
  local result=vim.system(command,{env=env,clear_env=true,stdin=options.stdin,text=false}):wait(10000)
  if not optional then assert(result.code==0,'Git: '..(result.stderr or result.stdout or 'operation failed')) end
  return result
end
local function git(root,args,options) return run(root,args,options).stdout end
local function oid(root,ref)
  local r=run(root,{'rev-parse','--verify','--quiet',ref..'^{commit}'},nil,true)
  return r.code==0 and vim.trim(r.stdout) or nil
end
function M.inspect(root)
  root=assert(vim.uv.fs_realpath(root),'Project does not exist')
  local r=run(root,{'rev-parse','--show-toplevel'},nil,true)
  if r.code~=0 then return {root=root,enabled=false} end
  local top=vim.uv.fs_realpath(vim.trim(r.stdout))
  if top~=root then return {root=root,enabled=false,parent=top} end
  local branch=run(root,{'symbolic-ref','--quiet','HEAD'},nil,true)
  return {root=root,enabled=true,branch=branch.code==0 and vim.trim(branch.stdout):gsub('^refs/heads/','') or '(detached)',
    head=oid(root,'HEAD'),milestone=oid(root,'refs/heads/backup')}
end
function M.enable(root)
  local repo=M.inspect(root)
  root=repo.root
  local ignore=fs.inside(root,'.gitignore')
  for _,buf in ipairs(vim.api.nvim_list_bufs()) do
    if canonical(vim.api.nvim_buf_get_name(buf))==ignore and vim.api.nvim_buf_is_loaded(buf) then
      assert(not vim.bo[buf].modified,'Save .gitignore before enabling Git')
    end
  end
  if not repo.enabled then git(root,{'init','--initial-branch=main','.'}) end
  local text=vim.fn.filereadable(ignore)==1 and fs.read(ignore) or ''
  local revised=text
  local existing={}
  for line in text:gmatch('[^\r\n]+') do existing[line]=true end
  for _,rule in ipairs({'/build','/backups/','/.lilypond-curator.lock','*.otter.scm'}) do
    if not existing[rule] then
      revised=revised..(revised~='' and revised:sub(-1)~='\n' and '\n' or '')..rule..'\n'
    end
  end
  if revised~=text then fs.atomic(ignore,revised) end
  for _,buf in ipairs(vim.api.nvim_list_bufs()) do
    if canonical(vim.api.nvim_buf_get_name(buf))==ignore and vim.api.nvim_buf_is_loaded(buf) then
      vim.api.nvim_buf_call(buf,function()vim.cmd('silent edit')end)
    end
  end
  return M.inspect(root)
end
local excluded={build=true,backups=true,['.git']=true,['.lilypond-curator.lock']=true}
local function source(path)
  for part in path:gmatch('[^/]+') do if excluded[part] then return false end end
  if path:match('%.otter%.scm$') then return false end
  return path:match('%.i?ly$') or path:match('%.ya?ml$') or path:match('%.scm$')
    or path=='.gitignore' or path=='.gitattributes' or path=='.editorconfig'
end
M.is_source=source
function M.snapshot(root)
  local files={}
  local function visit(directory,prefix)
    for name,kind in vim.fs.dir(directory) do
      local path=prefix..name
      if not excluded[name] then
        if kind=='directory' then
          assert(not vim.uv.fs_lstat(directory..'/'..name..'/.git'),'Nested repository is outside the score snapshot: '..path)
          visit(directory..'/'..name,path..'/')
        elseif source(path) then
          assert(kind=='file','Source symlinks/special files are unsupported: '..path)
          local full=fs.inside(root,path)
          files[path]={text=fs.read(full),mode=bit.band(vim.uv.fs_stat(full).mode,73)~=0 and '100755' or '100644'}
        end
      end
    end
  end
  visit(root,'');return files
end
local function committed(root,commit)
  local files={}
  if not commit then return files end
  for entry in git(root,{'ls-tree','-rz',commit}):gmatch('([^%z]+)%z') do
    local mode,kind,hash,path=entry:match('^(%d+) (%w+) (%x+)\t(.*)$')
    if path and source(path) then
      assert(kind=='blob' and (mode=='100644' or mode=='100755'),'Unsupported historical source entry: '..path)
      fs.inside(root,path)
      files[path]={text=git(root,{'cat-file','blob',hash}),mode=mode}
    end
  end
  return files
end
local function changes(before,after,selected)
  local paths={}
  for path in pairs(before) do paths[path]=true end
  for path in pairs(after) do paths[path]=true end
  local result={}
  for _,path in ipairs(vim.fn.sort(vim.tbl_keys(paths))) do
    if (not selected or vim.tbl_contains(selected,path)) and not vim.deep_equal(before[path],after[path]) then
      result[#result+1]={path=path,before=before[path],after=after[path]}
    end
  end
  return result
end
function M.compare(root,commit)
  return changes(committed(root,commit),M.snapshot(root))
end
function M.history(root,kind)
  local ref=kind=='milestone' and 'refs/heads/backup' or 'HEAD'
  if not oid(root,ref) then return {} end
  local result={}
  for row in git(root,{'log','-100','--format=%H%x09%cs%x09%s%x09%D',ref,'--'}):gmatch('[^\n]+') do
    local hash,date,message,labels=row:match('^(%x+)\t([^\t]+)\t([^\t]*)\t(.*)$')
    if hash then result[#result+1]={oid=hash,date=date,message=message,labels=labels} end
  end
  return result
end
function M.plan(root,kind,selected)
  assert(kind=='record' or kind=='milestone','Unknown Git action')
  local repo=M.inspect(root)
  assert(repo.enabled,repo.parent and 'Enable Git in this project; the parent repository will not be used' or 'Enable Git for this project first')
  if kind=='record' then assert(repo.branch~='backup' and repo.branch~='(detached)','Choose a workbench branch before recording') end
  assert(kind~='milestone' or not selected,'Milestones snapshot the complete saved score')
  local base=repo.head
  if kind=='milestone' then base=repo.milestone end
  local saved=M.snapshot(root)
  return {root=repo.root,kind=kind,branch=repo.branch,head=repo.head,base=base,saved=saved,
    changes=changes(committed(root,base),saved,selected)}
end
local function clean_buffers(root)
  for _,buf in ipairs(vim.api.nvim_list_bufs()) do
    local name=canonical(vim.api.nvim_buf_get_name(buf))
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified and vim.startswith(name,root..'/')
      and source(name:sub(#root+2)) then error('Save or discard source buffer edits before this Git action: '..name) end
  end
end
local function verify(plan)
  clean_buffers(plan.root)
  assert(not vim.uv.fs_lstat(plan.root..'/.lilypond-curator.lock'),'An Apply is active or its lock needs attention')
  assert(vim.deep_equal(plan.saved,M.snapshot(plan.root)),'Saved source changed; refresh and review again')
  local repo=M.inspect(plan.root)
  assert(repo.enabled and repo.branch==plan.branch and repo.head==plan.head,'Workbench branch changed; refresh and review again')
  local base=repo.head
  if plan.kind=='milestone' then base=repo.milestone end
  assert(base==plan.base,'History changed; refresh and review again')
end
local function has_staging(root)
  local r=run(root,{'diff','--cached','--quiet','--exit-code'},nil,true)
  assert(r.code==0 or r.code==1,'Cannot inspect staging: '..(r.stderr or ''))
  return r.code==1
end
local function idle_repository(root)
  for _,name in ipairs({'MERGE_HEAD','CHERRY_PICK_HEAD','REVERT_HEAD','rebase-merge','rebase-apply','sequencer'}) do
    local path=vim.trim(git(root,{'rev-parse','--git-path',name}))
    if not vim.startswith(path,'/') then path=root..'/'..path end
    assert(not vim.uv.fs_lstat(path),'Finish the active Git operation before recording')
  end
end
local function write_all(fd,text)
  local offset=0
  while offset<#text do
    local n=assert(vim.uv.fs_write(fd,text:sub(offset+1),offset));assert(n>0);offset=offset+n
  end
  assert(vim.uv.fs_fsync(fd))
end
function M.save(plan,message,tag)
  message=vim.trim(message or '');tag=vim.trim(tag or '')
  assert(message~='' and not message:find('%c'),'Enter a single-line commit message')
  assert(tag=='' or plan.kind=='milestone','Tags belong to stable milestones')
  assert(#plan.changes>0,'No saved source changes to record')
  verify(plan)
  local root=plan.root
  idle_repository(root)
  if plan.kind=='milestone' then
    assert(not git(root,{'worktree','list','--porcelain'}):find('branch refs/heads/backup\n',1,true),
      'The backup branch is checked out in a worktree; switch that worktree first')
  else assert(not has_staging(root),'Staged changes exist; commit or unstage them before recording. Milestones leave staging untouched.') end
  if tag~='' then
    git(root,{'check-ref-format','refs/tags/'..tag})
    local r=run(root,{'show-ref','--verify','--quiet','refs/tags/'..tag},nil,true)
    assert(r.code==1,'Tag already exists: '..tag)
  end
  local index=vim.fn.tempname()
  local options={env={GIT_INDEX_FILE=index}}
  local lock_path,lock_fd,published
  local ok,result=pcall(function()
    if plan.kind=='record' and plan.head then git(root,{'read-tree',plan.head},options)
    else git(root,{'read-tree','--empty'},options) end
    local entries={}
    local selected=plan.kind=='milestone' and changes({},plan.saved) or plan.changes
    local empty=vim.trim(git(root,{'hash-object','--stdin'},{stdin=''}))
    for _,item in ipairs(selected) do
      if item.after then
        local hash=vim.trim(git(root,{'hash-object','-w','--stdin'},{stdin=item.after.text}))
        entries[#entries+1]=item.after.mode..' '..hash..'\t'..item.path..'\0'
      else entries[#entries+1]='0 '..string.rep('0',#empty)..'\t'..item.path..'\0' end
    end
    git(root,{'update-index','-z','--index-info'},{env=options.env,stdin=table.concat(entries)})
    local tree=vim.trim(git(root,{'write-tree'},options))
    local args={'commit-tree',tree}
    if plan.base then vim.list_extend(args,{'-p',plan.base}) end
    local hash=vim.trim(git(root,args,{stdin=message..'\n'}))
    local tag_hash
    if tag~='' then
      local identity=vim.trim(git(root,{'var','GIT_COMMITTER_IDENT'}))
      tag_hash=vim.trim(git(root,{'mktag'},{stdin='object '..hash..'\ntype commit\ntag '..tag..'\ntagger '..identity..'\n\n'..message..'\n'}))
    end
    if plan.kind=='record' then
      lock_path=vim.trim(git(root,{'rev-parse','--git-path','index'}))
      if not vim.startswith(lock_path,'/') then lock_path=root..'/'..lock_path end
      local index_path=lock_path;lock_path=lock_path..'.lock'
      lock_fd=assert(vim.uv.fs_open(lock_path,'wx',384),'Another Git operation holds the index lock')
      assert(not has_staging(root),'Staging changed while recording; review again')
      write_all(lock_fd,fs.read(index))
      assert(vim.uv.fs_close(lock_fd));lock_fd=nil
      options.index_path=index_path
    end
    verify(plan)
    local ref=plan.kind=='milestone' and 'refs/heads/backup' or 'refs/heads/'..plan.branch
    local command='start\noption no-deref\nupdate '..ref..' '..hash..' '..(plan.base or string.rep('0',#hash))..'\n'
    if tag_hash then command=command..'create refs/tags/'..tag..' '..tag_hash..'\n' end
    git(root,{'update-ref','--create-reflog','-m',message,'--stdin'},{stdin=command..'prepare\ncommit\n'})
    published=hash
    if lock_path then
      assert(vim.uv.fs_rename(lock_path,options.index_path),'Commit '..hash..' was created, but refreshing the index failed')
      lock_path=nil
    end
    return hash
  end)
  if lock_fd then vim.uv.fs_close(lock_fd) end
  if lock_path then vim.uv.fs_unlink(lock_path) end
  vim.uv.fs_unlink(index)
  if not ok then error((published and ('Commit created: '..published..'\n') or '')..tostring(result),0) end
  return result
end
function M.restore_plan(root,commit,selected)
  local repo=M.inspect(root);assert(repo.enabled,'Enable project Git first')
  assert(type(commit)=='string' and commit:match('^%x+$') and oid(root,commit)==commit,'Choose a commit from project history')
  local saved=M.snapshot(root)
  return {root=repo.root,commit=commit,saved=saved,changes=changes(saved,committed(root,commit),selected)}
end
local function restore(plan)
  clean_buffers(plan.root)
  assert(vim.deep_equal(plan.saved,M.snapshot(plan.root)),'Saved source changed; review restore again')
  local done={}
  local function put(item,value,track)
    local path=fs.inside(plan.root,item.path)
    if value then
      vim.fn.mkdir(vim.fs.dirname(path),'p');fs.atomic(path,value.text)
      if track then done[#done+1]=item end
      assert(vim.uv.fs_chmod(path,tonumber(value.mode:sub(-3),8)))
    else
      assert(vim.uv.fs_unlink(path))
      if track then done[#done+1]=item end
    end
  end
  local ok,err=pcall(function()
    for _,item in ipairs(plan.changes) do
      local path=fs.inside(plan.root,item.path)
      assert((vim.fn.filereadable(path)==1 and fs.read(path) or nil)==(item.before and item.before.text),'Source changed during restore: '..item.path)
      put(item,item.after,true)
    end
  end)
  if not ok then
    local failures={}
    for i=#done,1,-1 do
      local item=done[i]
      local restored,failure=pcall(function()
        local path=fs.inside(plan.root,item.path)
        assert((vim.fn.filereadable(path)==1 and fs.read(path) or nil)==(item.after and item.after.text),'Newer edit preserved: '..item.path)
        put(item,item.before)
      end)
      if not restored then failures[#failures+1]=tostring(failure) end
    end
    error('Restore failed: '..tostring(err)..(#failures>0 and '\n'..table.concat(failures,'\n') or '\nOriginal sources restored'),0)
  end
  for _,buf in ipairs(vim.api.nvim_list_bufs()) do
    local name=canonical(vim.api.nvim_buf_get_name(buf))
    for _,item in ipairs(plan.changes) do
      if name==plan.root..'/'..item.path and vim.api.nvim_buf_is_loaded(buf) then
        if item.after then vim.api.nvim_buf_call(buf,function()vim.cmd('silent edit')end)
        else vim.api.nvim_buf_delete(buf,{force=false}) end
      end
    end
  end
  return #plan.changes
end
function M.restore(plan)
  local path=fs.inside(plan.root,'.lilypond-curator.lock')
  local fd=assert(vim.uv.fs_open(path,'wx',384),'Another Apply/restore is active or its operation lock needs attention')
  local written,write_error=pcall(write_all,fd,vim.json.encode({pid=vim.fn.getpid(),action='restore'}))
  vim.uv.fs_close(fd)
  if not written then vim.uv.fs_unlink(path);error(write_error,0) end
  local ok,result=pcall(restore,plan)
  local removed=vim.uv.fs_unlink(path)
  if not ok then error(result,0) end
  assert(removed,'Restored sources, but the operation lock could not be removed')
  return result
end
return M
