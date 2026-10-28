-- Source navigation and cached viewer state live in Neovim. HTTP callbacks run
-- on the editor loop; the browser receives only passive SVG and indexed targets.
local fs=require('lilyp.fs')
local index=require('lilyp.source_index')
local M={}
local sessions={}
local attached_buffers={}
local dirty_pending=false
local function queue_dirty()
  if dirty_pending then return end
  dirty_pending=true
  vim.schedule(function()
    dirty_pending=false
    for _,session in pairs(sessions) do if not session.closed then session.update_dirty() end end
  end)
end
local function attach_dirty_buffers()
  for _,buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and not attached_buffers[buf] then
      local name=vim.api.nvim_buf_get_name(buf)
      local watched=false
      for _,session in pairs(sessions) do
        local context=session.context
        if session.manifest.sources[index.canonical(name)] or name==context.source or name==context.main
          or (vim.startswith(name,context.root..'/') and name:match('%.i?ly$')) then watched=true;break end
      end
      if watched then
        local function changed()
          if not next(sessions) then attached_buffers[buf]=nil;return true end
          queue_dirty()
        end
        attached_buffers[buf]=vim.api.nvim_buf_attach(buf,false,{on_lines=changed,on_reload=changed,
          on_detach=function()attached_buffers[buf]=nil;queue_dirty()end})
      end
    end
  end
end
local assets=vim.fn.fnamemodify(debug.getinfo(1,'S').source:sub(2),':p:h:h:h')..'/scripts/svg_viewer/'
local launch=require('lilyp.viewer_launch').open
local function create(context)
  local session={context=context,sequence=0,selected=vim.NIL,reveal=vim.NIL,reveal_sequence=0,
    cache={},watchers={},window=vim.api.nvim_get_current_win()}
  local timer=assert(vim.uv.new_timer());session.timer=timer
  function session.update_dirty()
    session.dirty=not pcall(require('lilyp.score_context').assert_clean,context)
    if not session.dirty then
      for _,buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified
          and session.manifest.sources[index.canonical(vim.api.nvim_buf_get_name(buf))] then session.dirty=true;break end
      end
    end
  end
  local function fresh()
    session.stale=not index.fresh(session.manifest.sources,session.cache)
    return not session.stale
  end
  function session.check()
    assert(fresh(),'Source changed since SVG compilation. Rebuild with F5.')
  end
  local load
  local function changed()
    if session.closed then return end
    timer:stop();timer:start(80,0,vim.schedule_wrap(function()
      if session.closed then return end
      local ok,err=pcall(function()load();fresh()end)
      if not ok then session.error=tostring(err) end
    end))
  end
  load=function()
    local signature=index.signature(context.manifest)
    if signature==session.signature then return end
    local pointer=vim.json.decode(fs.read(context.manifest))
    local manifest=vim.json.decode(fs.read(pointer.manifest))
    assert(type(manifest.pages)=='table' and type(manifest.entries)=='table' and type(manifest.sources)=='table','Invalid SVG build manifest; rebuild with F5')
    session.manifest,session.signature,session.cache,session.error=manifest,signature,{},nil
    session.selected=vim.NIL
    if session.selection then
      local count=0
      for _,entry in ipairs(manifest.entries) do
        local choice=session.selection
        if entry.source==choice.source and entry.line==choice.line and entry.char==choice.char then
          count=count+1;if count==choice.occurrence then session.selected=entry.key;break end
        end
      end
    end
    for _,watcher in ipairs(session.watchers) do watcher:stop();watcher:close() end
    session.watchers={}
    local directories={[vim.fs.dirname(context.manifest)]=true}
    for path in pairs(manifest.sources) do directories[vim.fs.dirname(path)]=true end
    for directory in pairs(directories) do
      local watcher=assert(vim.uv.new_fs_event())
      if watcher:start(directory,{},changed) then session.watchers[#session.watchers+1]=watcher else watcher:close() end
    end
    local current=fresh()
    session.origins=manifest.origins
    if type(session.origins)~='table' or #session.origins~=#manifest.entries then
      -- Legacy caches can be inspected without writes or an implicit build, but
      -- current source must never be presented as an older compiled snapshot.
      session.origins={}
      if current then
        local captured,value=pcall(require('lilyp.source_origin').capture,manifest.entries,manifest.sources,context.root)
        if captured then session.origins=value end
      end
    end
    local normalize=require('lilyp.inspection_legacy').origin
    for n,origin in ipairs(session.origins) do
      session.origins[n]=type(origin)=='table' and normalize(origin)
        or require('lilyp.source_origin').unavailable(manifest.entries[n],context.root)
    end
    session.update_dirty()
  end
  function session.reload()load()end
  function session.state(revision)
    assert(not session.error,session.error)
    local manifest=session.manifest
    return {revision=manifest.revision,pages=manifest.revision~=revision and manifest.pages or vim.NIL,
      selected=session.selected,sequence=session.sequence,reveal=session.reveal,stale=session.stale,dirty=session.dirty}
  end
  function session.close()
    if session.closed then return end
    session.closed=true
    timer:stop();timer:close()
    for _,watcher in ipairs(session.watchers) do watcher:stop();watcher:close() end
    if session.server then session.server.close() end
    sessions[context.manifest]=nil
  end
  local ok,err=pcall(function()
    load()
    local html,js=fs.read(assets..'index.html'),fs.read(assets..'viewer.js')
    local inspector_js=fs.read(assets..'inspector.js')
    local group_js=fs.read(assets..'group.js')
    local aliases=fs.read(assets..'fonts.css')
    local replacements
    html,replacements=html:gsub('/%* score%-font%-aliases %*/',function()return aliases end)
    assert(replacements==1,'Viewer template is missing its font aliases placeholder')
    session.server=require('lilyp.viewer_server').start(function(method,target,body)
      if method=='GET' then
        if target=='' then return 200,html,'text/html; charset=utf-8' end
        if target=='viewer.js' then return 200,js,'text/javascript; charset=utf-8' end
        if target=='group.js' then return 200,group_js,'text/javascript; charset=utf-8' end
        if target=='inspector.js' then return 200,inspector_js,'text/javascript; charset=utf-8' end
        local revision=target:match('^state%?revision=([%w_%-]*)$')
        if revision then return 200,session.state(revision) end
      elseif method=='POST' and (target=='click' or target=='inspect') then
        local request=vim.json.decode(body)
        load()
        assert(request.revision==session.manifest.revision,'Score refreshed; click the current score')
        assert(type(request.key)=='number' and request.key%1==0 and request.key>=0,'Invalid score location')
        local entry=assert(session.manifest.entries[request.key+1],'Invalid score location')
        if target=='inspect' then
          fresh();session.update_dirty()
          local origin=session.origins[request.key+1] or require('lilyp.source_origin').unavailable(entry,context.root)
          return 200,{revision=session.manifest.revision,key=request.key,origin=origin,stale=session.stale,dirty=session.dirty,read_only=true}
        end
        session.check()
        require('lilyp.score_context').assert_clean(context)
        local buf=vim.fn.bufadd(entry.source);vim.fn.bufload(buf)
        assert(not vim.bo[buf].modified,'Source buffer has unsaved edits; rebuild with F5')
        assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf,0,-1,false),vim.fn.readfile(entry.source)),
          'Source buffer differs from the compiled file; reload it and rebuild with F5')
        if vim.api.nvim_win_is_valid(session.window) then vim.api.nvim_set_current_win(session.window) end
        vim.api.nvim_set_current_buf(buf)
        vim.api.nvim_win_set_cursor(0,{entry.line,index.byte_column(entry)})
        local occurrence=0
        for i=1,request.key+1 do
          local other=session.manifest.entries[i]
          if other.source==entry.source and other.line==entry.line and other.char==entry.char then occurrence=occurrence+1 end
        end
        session.selection={source=entry.source,line=entry.line,char=entry.char,occurrence=occurrence}
        session.selected=request.key;session.sequence=session.sequence+1
        return 200,{}
      end
      return 404,{error='Unknown viewer route'}
    end)
  end)
  if not ok then session.close();error(err) end
  sessions[context.manifest]=session
  attach_dirty_buffers()
  return session
end
function M.open(opts)
  opts=opts or {}
  local context=opts.context or require('lilyp.score_context').resolve(opts.buf)
  assert(vim.fn.filereadable(context.manifest)==1,'SVG is missing. Compile with F5 first.')
  local tick,position
  if opts.forward then
    require('lilyp.score_context').assert_clean(context)
    assert(opts.position or context.buf==vim.api.nvim_get_current_buf(),'Supply a cursor position for a noncurrent source buffer')
    tick=vim.api.nvim_buf_get_changedtick(context.buf)
    position=opts.position or vim.api.nvim_win_get_cursor(0)
  end
  local session=sessions[context.manifest] or create(context)
  session.window=vim.api.nvim_get_current_win()
  if opts.launch~=false and (not opts.forward or not session.launched) then launch(session.server.url);session.launched=true end
  if opts.forward then
    vim.schedule(function()
      if session.closed then return end
      local ok,err=pcall(function()
        assert(vim.api.nvim_buf_is_valid(context.buf) and vim.api.nvim_buf_get_changedtick(context.buf)==tick,
          'Source changed during navigation. Rebuild with F5 and try again.')
        require('lilyp.score_context').assert_clean(context)
        session.reload();session.check()
        local entry=index.locate(session.manifest.entries,context.source,position[1],position[2],opts.occurrence)
        session.selection={source=entry.source,line=entry.line,char=entry.char,occurrence=opts.occurrence or 1}
        session.selected=entry.key
        session.sequence=session.sequence+1
        session.reveal_sequence=session.reveal_sequence+1
        session.reveal={sequence=session.reveal_sequence,key=entry.key,revision=session.manifest.revision}
      end)
      if ok then if opts.on_done then opts.on_done({format='svg',url=session.server.url}) end
      elseif opts.on_error then opts.on_error(tostring(err)) else vim.notify(tostring(err),vim.log.levels.ERROR) end
    end)
  elseif opts.on_done then opts.on_done({format='svg',url=session.server.url}) end
  return session
end
function M.forward(opts)return M.open(vim.tbl_extend('force',opts or {},{forward=true}))end
function M.refresh(root)
  for _,session in pairs(sessions) do
    if session.context.root==root then
      local ok,err=pcall(require('lilyp.compiler').compile,{context=session.context,save=false,
        on_error=function(message)vim.notify('SVG refresh failed; previous score retained: '..message,vim.log.levels.WARN)end})
      if not ok then vim.notify('SVG refresh deferred: '..tostring(err),vim.log.levels.WARN) end
    end
  end
end
function M.close_all()for _,session in pairs(sessions) do session.close() end end
vim.api.nvim_create_autocmd('User',{pattern='LylipBuildComplete',callback=function(event)
  if event.data and event.data.format=='svg' then
    local session=sessions[event.data.manifest]
    if session then session.reload() end
  end
end})
vim.api.nvim_create_autocmd('VimLeavePre',{callback=M.close_all})
vim.api.nvim_create_autocmd({'BufModifiedSet','BufWritePost','BufWipeout'},{callback=queue_dirty})
vim.api.nvim_create_autocmd('OptionSet',{pattern='modified',callback=queue_dirty})
vim.api.nvim_create_autocmd({'BufEnter','BufReadPost','BufNewFile','BufFilePost'},{callback=function()
  attach_dirty_buffers();queue_dirty()
end})
return M
