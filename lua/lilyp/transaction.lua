local outcome=require('lilyp.operation_outcome')
local resources=require('lilyp.operation_resources')
local fs=require('lilyp.fs')
local plans=require('lilyp.edit_plan')
local M={}
local function run(args,job,message)
  local result
  if job then result=job:run(args,message)
  else result=vim.system(args,{text=true}):wait(30000) end
  local log=(result.stdout or '')..(result.stderr or '')
  local failure=require('lilyp.process').failure(args,result,30000)
  assert(not failure,failure)
  return log
end
local function compile(root,settings,output,main_path,job,message)
  output=output or root..'/build';vim.fn.mkdir(output,'p')
  local args={settings.lilypond or 'lilypond','-I',root,'-o',output..'/main'}
  if require('lilyp.integrations.nvls').enabled then
    args[#args+1]='-dinclude-settings='..require('nvls.utils').ensure_midi_helper()
  end
  args[#args+1]=fs.inside(root,main_path or 'main.ly')
  local log=run(args,job,message)
  assert(not log:lower():find('warning:',1,true),'Compilation warnings:\n'..log)
  assert(vim.fn.filereadable(output..'/main.pdf')==1,'Compiler did not produce '..output..'/main.pdf')
  return output
end
local function midi_files(dir)
  local result={}
  for name,kind in vim.fs.dir(dir) do
    if kind=='file' and (name:match('%.midi$') or name:match('%.mid$')) then result[name]=fs.read(dir..'/'..name) end
  end
  return result
end
function M.validate(session,plan,job)
  if job then job:check() end
  plans.validate(session,plan)
  fs.assert_clean(session.root,session.snapshot)
  local opts=require('lilyp').options()
  local before=fs.stage(session.snapshot)
  session.temporary[#session.temporary+1]=before
  local after=fs.stage(session.snapshot)
  session.temporary[#session.temporary+1]=after
  for _,edit in ipairs(plan.sources) do
    local target=fs.inside(after,edit.path);vim.fn.mkdir(vim.fs.dirname(target),'p');fs.write(target,edit.after)
  end
  local first=compile(before,opts,nil,session.main_path,job,'Checking saved score playback…')
  local second=compile(after,opts,nil,session.main_path,job,'Checking draft score playback…')
  assert(vim.deep_equal(midi_files(first),midi_files(second)),'Cosmetic change altered MIDI; nothing was applied')
  if plan.compare_pages then
    -- Initial specification import or metadata cleanup must preserve every rendered page, not just syntax/MIDI.
    for _,dir in ipairs({first,second}) do
      run({'pdftoppm','-r','100','-png',dir..'/main.pdf',dir..'/page'},job,'Comparing rendered pages…')
    end
    local function pages(dir)
      local p={}
      for name,kind in vim.fs.dir(dir) do if kind=='file' and name:match('^page%-%d+%.png$') then p[name]=fs.read(dir..'/'..name) end end
      assert(next(p),'No rasterized PDF pages');return p
    end
    assert(vim.deep_equal(pages(first),pages(second)),'Specification import changed the rendered pages; nothing was applied')
  end
  return {directory=after,output=second,pdf=second..'/main.pdf',plan=vim.deepcopy(plan)}
end
local function publish(session,plan,validated,job,effects)
  fs.assert_clean(session.root,session.snapshot)
  local output=require('lilyp.output').ensure(session.root)
  local writes={}
  for _,edit in ipairs(plan.sources) do writes[#writes+1]={path=edit.path,text=edit.after} end
  local source_count=#writes
  for name,kind in vim.fs.dir(validated.output) do
    if kind=='file' and (name:match('%.pdf$') or name:match('%.midi$') or name:match('%.mid$')) then
      writes[#writes+1]={path=name,artifact=true,text=fs.read(validated.output..'/'..name)}
    end
  end
  -- Originals live only for this operation. Caught errors roll back; process
  -- crashes have no persistent journal or automatic source backup.
  local function destination(item)
    return item.artifact and fs.inside(output,item.path) or fs.inside(session.root,item.path)
  end
  for _,item in ipairs(writes) do
    local path=destination(item)
    item.existed=vim.fn.filereadable(path)==1
    item.original=item.existed and fs.read(path) or nil
  end
  local done={}
  local ok,err=pcall(function()
    -- Publish specification and styling, then compile from its real path so PDF source links
    -- point to editable project files rather than the temporary validation tree.
    for i=1,source_count do
      local item=writes[i]
      local target=fs.inside(session.root,item.path)
      vim.fn.mkdir(vim.fs.dirname(target),'p')
      fs.atomic(target,item.text);done[#done+1]=item
    end
    local actual=compile(session.root,require('lilyp').options(),validated.directory..'/published-output',session.main_path,
      job,'Publishing verified sources and rebuilding project links…')
    assert(vim.deep_equal(midi_files(actual),midi_files(validated.output)),
      'Project playback changed during publication')
    local expected=plans.snapshot(session,plan)
    fs.assert_clean(session.root,expected)
    for i=source_count+1,#writes do
      local item=writes[i]
      item.text=fs.read(actual..'/'..vim.fs.basename(item.path))
      fs.atomic(destination(item),item.text);done[#done+1]=item
    end
  end)
  if not ok then
    if job then job:recovering() end
    local failures={}
    for i=#done,1,-1 do
      local item=done[i]
      local restored,failure=pcall(function()
        local path=destination(item)
        assert(vim.fn.filereadable(path)==1 and fs.read(path)==item.text,
          'Destination changed after publication; preserve newer work and recover manually: '..item.path)
        if item.existed then fs.atomic(path,item.original) else assert(vim.uv.fs_unlink(path)) end
      end)
      if not restored then failures[#failures+1]=tostring(failure) end
    end
    error(outcome.failed('Apply failed: '..tostring(err)..(#failures==0 and '\nOriginal files restored.'
      or '\nSome files need manual correction:\n'..table.concat(failures,'\n')),
      #failures>0 and 'partial' or (#done>0 and 'restored' or 'unchanged')),0)
  end
  effects.publication='published'
  -- Clean loaded style/spec buffers follow the published files; never force dirty buffers.
  for _,buf in ipairs(vim.api.nvim_list_bufs()) do
    local name=vim.api.nvim_buf_get_name(buf)
    if vim.api.nvim_buf_is_loaded(buf) and not vim.bo[buf].modified then
      for _,item in ipairs(writes) do
        if not item.artifact and name==session.root..'/'..item.path then
          local modifiable=vim.bo[buf].modifiable
          local refreshed,failure=pcall(function()
            vim.bo[buf].modifiable=true
            -- Reload through Neovim so boundary blank lines, file encoding,
            -- line endings, and the on-disk timestamp follow the published file.
            vim.api.nvim_buf_call(buf,function()vim.cmd('silent edit')end)
          end)
          vim.bo[buf].modifiable=modifiable
          if not refreshed then vim.notify('Applied; reload this buffer manually: '..name..' ('..tostring(failure)..')',vim.log.levels.WARN) end
        end
      end
    end
  end
  return true
end
function M.publish(session,plan,validated,job)
  assert(not require('lilyp.compiler').running(session.root..'/'..session.main_path),'A working score build is running; wait before Apply')
  plans.validate(session,plan)
  assert(vim.deep_equal(plan,validated.plan),'Edit plan differs from the validated preview')
  if job then job:phase('Publishing verified sources…',true) end
  local path=session.root..'/.lilypond-curator.lock'
  local fd,err=vim.uv.fs_open(path,'wx',420)
  assert(fd,'Another Apply or a stale operation lock exists: '..path..' ('..tostring(err)..')')
  local tasks={
    {label='Apply lock removal',run=function()local ok,failure=vim.uv.fs_unlink(path);assert(ok,failure)end},
    {label='Apply lock descriptor',run=function()if fd then local ok,failure=vim.uv.fs_close(fd);assert(ok,failure);fd=nil end end},
  }
  local effects={publication='unchanged'}
  local ok,result=pcall(function()
    local metadata=vim.json.encode({pid=vim.fn.getpid(),created=os.date('!%Y-%m-%dT%H:%M:%SZ')})
    local written,failure=vim.uv.fs_write(fd,metadata)
    assert(written==#metadata,failure or 'Could not write Apply lock')
    local closed,close_error=vim.uv.fs_close(fd);assert(closed,close_error);fd=nil
    return publish(session,plan,validated,job,effects)
  end)
  local completion
  if ok then completion=outcome.succeeded(result,'published')
  elseif outcome.is(result) then completion=outcome.from_error(result)
  else completion=outcome.failed(result,effects.publication) end
  resources.clean(tasks,completion)
  if job then job:publication(completion) end
  if completion.tag=='failed' then error(completion,0) end
  if package.loaded['lilyp.svg_navigation'] then
    vim.schedule(function()require('lilyp.svg_navigation').refresh(session.root)end)
  end
  return result,completion
end
return M
