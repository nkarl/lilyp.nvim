-- One read-only resolver for navigation, compilation, curation, and LSP.
local fs=require('lilyp.fs')
local M={}
local entries={}
function M.root(path)
  path=path or vim.api.nvim_buf_get_name(0)
  if path=='' then return nil end
  local absolute=vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(path),':p')):gsub('/$','')
  return vim.fs.root(absolute=='' and '/' or absolute,'score.yaml')
end
function M.describe(root,metadata)
  root=vim.fs.normalize(root)
  require('lilyp.project_document').assert_valid(metadata)
  local source=metadata.source
  local main=fs.inside(root,source.main)
  assert(vim.fn.filereadable(main)==1,'Main score does not exist: '..main)
  return {root=root,metadata=metadata,main=main,main_relative=main:sub(#root+2),
    style_relative=source.style}
end
function M.resolve(path)
  local root=M.root(path)
  if not root then return nil end
  local text=fs.read(fs.inside(root,'score.yaml'))
  local entry=entries[root]
  if not entry or entry.text~=text or entry.waiters then
    entry={text=text,metadata=require('lilyp.spec').read(text)}
    entries[root]=entry
  end
  assert(not entry.err,entry.err)
  return M.describe(root,vim.deepcopy(entry.metadata))
end

-- Validate entry-point structure before allocating an application window. Build,
-- Git, and presentation initialization are optional; declared source files are not.
function M.validate(path)
  path=vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(path),':p')):gsub('/$','')
  if path=='' then path='/' end
  local ok,result=pcall(function()
    assert(vim.uv.fs_stat(path),'The selected path does not exist')
    local root=assert(M.root(path),'No score.yaml was found in this directory or its parents')
    local metadata=require('lilyp.spec').read(fs.read(fs.inside(root,'score.yaml')))
    local project=M.describe(root,metadata)
    local function required(relative,label)
      local full=fs.inside(root,relative)
      local stat=vim.uv.fs_stat(full)
      assert(stat and stat.type=='file' and vim.fn.filereadable(full)==1,label..' does not exist or is not a readable file: '..relative)
    end
    required(project.main_relative,'Main score')
    required(project.style_relative,'Style include')
    for _,section in ipairs(metadata.sections) do
      if section.source and section.source~=vim.NIL then required(section.source,'Section source') end
    end
    return project
  end)
  if not ok then error('Not a LilyPond project: '..path..'\nExpected score.yaml (kind: lilypond-score) and its main/style/declared section sources.\n'..tostring(result),0) end
  return result
end
-- Interactive entry resolution reads only source metadata. Cache by exact YAML
-- bytes, coalesce concurrent parses, and revalidate main paths on every lookup.
function M.resolve_async(path, done)
  local root=M.root(path)
  if not root then return done(nil) end
  local ok,text=pcall(function()return fs.read(fs.inside(root,'score.yaml'))end)
  if not ok then return done(nil,tostring(text)) end
  local entry=entries[root]
  local function deliver(metadata,err)
    if err then return done(nil,err) end
    local valid,result=pcall(M.describe,root,vim.deepcopy(metadata))
    done(valid and result or nil,not valid and tostring(result) or nil)
  end
  if entry and entry.text==text then
    if entry.waiters then entry.waiters[#entry.waiters+1]=done
    else deliver(entry.metadata,entry.err) end
    return
  end
  entry={text=text,waiters={done}};entries[root]=entry
  require('lilyp.spec').read_async(text,function(metadata,err)
    if err then err=tostring(err) end
    local waiters=entry.waiters;entry.waiters=nil
    entry.metadata,entry.err=metadata,err
    local read,current=pcall(function()return fs.read(fs.inside(root,'score.yaml'))end)
    for _,callback in ipairs(waiters) do
      -- Diagnostics and LSP can share this parse. An error in one consumer must
      -- remain visible without preventing delivery to the remaining consumers.
      local delivered,failure=pcall(function()
        if not read then callback(nil,tostring(current))
        elseif current~=text then M.resolve_async(path,callback)
        elseif err then callback(nil,err)
        else
          local valid,result=pcall(M.describe,root,vim.deepcopy(metadata))
          callback(valid and result or nil,not valid and tostring(result) or nil)
        end
      end)
      if not delivered then
        vim.schedule(function()vim.notify('Project resolution callback failed: '..tostring(failure),vim.log.levels.ERROR)end)
      end
    end
  end)
end
return M
