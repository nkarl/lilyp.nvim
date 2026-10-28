-- One application owns the window and all creation/presentation drafts.
local M = {}
local form = require('lilyp.form')
local active

local function live()
  return active and not active.closed and vim.api.nvim_win_is_valid(active.win)
end

local function current_root()
  local root=require('lilyp').project_root(vim.api.nvim_buf_get_name(0))
  if not root and live() then root=active.current.root or active.current.session and active.current.session.root end
  if not root and live() and vim.api.nvim_win_is_valid(active.origin_win) then
    root=require('lilyp').project_root(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(active.origin_win)))
  end
  return root
end

local function entry_path(opts)
  opts=opts or {}
  if opts.path or opts.cwd then return vim.fn.expand(opts.path or opts.cwd) end
  if live() and active.current and vim.api.nvim_get_current_buf()==active.current.buf then
    return current_root() or vim.fn.getcwd()
  end
  local name=vim.api.nvim_buf_get_name(0)
  if name~='' and require('lilyp').project_root(name) then return name end
  return vim.fn.getcwd()
end

function M.current() return live() and active.current or nil end

local function finish_current()
  local state = M.current()
  if state and state.busy then return false end
  return not state or not state.finish_edit or state.finish_edit(false)
end

local function application()
  if live() then return active end
  local frame = form.open('Lylip')
  if not frame then return end
  local app = {win=frame.win, spare_buf=frame.buf, views={}}
  active = app
  function app.close()
    if app.current and app.current.busy then
      -- A manually closed float cannot keep an invisible validation draft alive.
      -- Let cancellation/any in-progress publication settle before disposal.
      if not vim.api.nvim_win_is_valid(app.win) and app.current.cancel then app.current.cancel() end
      return
    end
    if app.closed then return end
    app.closed=true
    if active==app then active=nil end
    for _, state in pairs(app.views) do state.closed=true;state.editing=nil end
    vim.cmd('stopinsert')
    for _, state in pairs(app.views) do
      if state.dispose then state.dispose() end
      if vim.api.nvim_buf_is_valid(state.buf) then vim.api.nvim_buf_delete(state.buf,{force=true}) end
    end
    if vim.api.nvim_win_is_valid(app.win) then vim.api.nvim_win_close(app.win,true) end
    if app.origin_win and vim.api.nvim_win_is_valid(app.origin_win) then vim.api.nvim_set_current_win(app.origin_win) end
  end
  vim.api.nvim_create_autocmd('WinClosed',{pattern=tostring(app.win),once=true,callback=function()
    -- Only active operations need to observe the window after it becomes
    -- invalid. Idle closes retain their immediate draft/buffer disposal.
    if app.current and app.current.busy then vim.schedule(app.close) else app.close() end
  end})
  vim.api.nvim_create_autocmd('VimResized',{group=vim.api.nvim_create_augroup('LilyCuratorResize',{clear=true}),callback=function()
    if active~=app or app.closed then return end
    if app.current and app.current.editing then app.current.finish_edit(false) end
    form.resize(app)
    if app.current then app.current.redraw() end
  end})
  return app
end

local function show(app,state)
  if app.current and app.current.close_preview then app.current.close_preview() end
  require('lilyp.audition').stop()
  app.current=state
  vim.api.nvim_win_set_buf(app.win,state.buf)
  vim.api.nvim_set_current_win(app.win)
  if state.redraw then state.redraw() end
  return state
end

local function mount(key,mode,data)
  if not finish_current() then
    if data.session then data.session:close() end
    return M.current()
  end
  local origin = live() and active.origin_win or vim.api.nvim_get_current_win()
  local app = application()
  if not app then
    if data.session then data.session:close() end
    return
  end
  app.origin_win=origin
  if app.views[key] then
    if data.session then data.session:close() end
    return show(app,app.views[key])
  end
  local buf = app.spare_buf or vim.api.nvim_create_buf(false,true)
  local previous=app.current
  app.spare_buf=nil
  vim.bo[buf].bufhidden, vim.bo[buf].swapfile='hide',false
  local state=vim.tbl_extend('force',data,{buf=buf,win=app.win,origin_win=app.origin_win,mode=mode,close=app.close})
  state.is_current=function()return active==app and app.current==state and not app.closed and not state.closed end
  state.on_idle=function()if not vim.api.nvim_win_is_valid(app.win) then app.close() end end
  state.home=M.home
  state.created=function(source,path)
    if state.close_preview then state.close_preview() end
    if not path then
      app.close()
      return require('lilyp.scaffold').create(source)
    end
    -- Source opens in the editing window; the curator float stays alive.
    if not vim.api.nvim_win_is_valid(app.origin_win) then
      for _,win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(win).relative=='' then app.origin_win=win;break end
      end
    end
    vim.api.nvim_set_current_win(app.origin_win)
    local created=require('lilyp.scaffold').create(source,path)
    M.open(path)
    if app.current~=state then
      app.views[key]=nil
      state.dispose()
      vim.api.nvim_buf_delete(state.buf,{force=true})
    end
    return created
  end
  app.views[key]=state
  show(app,state)
  local controller=mode=='new' and 'creation' or mode=='history' and 'history' or 'presentation'
  local ok,err=pcall(require('lilyp.'..controller).mount,state)
  if not ok then
    app.views[key]=nil
    state.closed=true
    state.editing=nil
    if state.dispose then state.dispose() elseif state.session then state.session:close() end
    if previous then show(app,previous) else app.close() end
    if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf,{force=true}) end
    error(err,0)
  end
  vim.keymap.set('n','H',M.home,{buffer=buf,silent=true,nowait=true,desc='Lylip home'})
  return state
end

function M.new()
  if live() and active.views.new then
    if not finish_current() then return M.current() end
    return show(active,active.views.new)
  end
  return mount('new','new',{options=require('lilyp.scaffold').defaults()})
end

function M.open(path)
  if path==nil then return M.home() end
  local root=require('lilyp.project').validate(path).root
  if live() and active.views[root] then
    if not finish_current() then return M.current() end
    return show(active,active.views[root])
  end
  return mount(root,'project',{session=require('lilyp.session').open(path)})
end

function M.review(path)
  path=path or entry_path()
  local root=require('lilyp.project').validate(path).root
  local key=root..'\0history'
  if live() and active.views[key] then
    if not finish_current() then return M.current() end
    local state=show(active,active.views[key]);state.refresh();return state
  end
  local file=path and vim.fn.fnamemodify(path,':p') or vim.api.nvim_buf_get_name(0)
  local relative=vim.startswith(file,root..'/') and file:sub(#root+2) or nil
  return mount(key,'history',{root=root,path=relative})
end

function M.configure(opts)
  return M.open(entry_path(opts))
end

function M.review_picker(opts)
  -- Keep the earlier helper name for callers; project entry no longer uses a picker.
  return M.review(entry_path(opts))
end

function M.browse(opts)
  opts=opts or {}
  local open=opts.view=='review' and M.review or M.open
  local title=opts.view=='review' and 'Review project' or opts.view=='configure' and 'Configure project' or 'Open project'
  local ok,pickers=pcall(require,'telescope.pickers')
  if not ok then
    vim.ui.input({prompt=title..' path: ',completion='file'},function(path)
      if path and path~='' then
        local opened,err=pcall(open,vim.fn.expand(path))
        if not opened then vim.notify(tostring(err),vim.log.levels.ERROR) end
      end
    end)
    return
  end
  local actions=require('telescope.actions')
  local action_state=require('telescope.actions.state')
  local cwd=vim.fn.fnamemodify(vim.fn.expand(opts.cwd or vim.fn.getcwd()),':p')
  return pickers.new(opts,{
    prompt_title='Lylip · '..title,
    finder=require('telescope.finders').new_oneshot_job(
      {'rg','--files','--hidden','-g','score.yaml','-g','!.git','-g','!node_modules'},
      {cwd=cwd,entry_maker=function(path)
        local full=vim.fs.normalize(cwd..'/'..path)
        return {value=full,display=vim.fs.dirname(path),ordinal=path,path=full}
      end}),
    sorter=require('telescope.config').values.generic_sorter(opts),
    previewer=false,
    attach_mappings=function(prompt_bufnr)
      actions.select_default:replace(function()
        local selected=action_state.get_selected_entry()
        if not selected then return end
        actions.close(prompt_bufnr)
        vim.schedule(function()
          local opened,err=pcall(open,selected.value)
          if not opened then vim.notify(tostring(err),vim.log.levels.ERROR) end
        end)
      end)
      return true
    end,
  }):find()
end

function M.home(opts)
  opts=opts or {}
  if not finish_current() then return M.current() end
  local root=current_root()
  local configure=opts.view=='configure'
  local title=configure and 'Lylip · Configure' or 'Lylip'
  local entries={}
  if live() then
    for key,state in pairs(active.views) do
      if not configure or state.mode=='project' then
        local label=state.mode=='new' and 'Resume new score draft'
          or state.mode=='history' and 'Resume notation review · '..state.root or 'Resume project · '..state.session.root
        entries[#entries+1]={label=label,run=function()
          if state.mode=='new' then return M.new() end
          if state.mode=='history' then return M.review(state.root) end
          return M.open(key)
        end}
      end
    end
    table.sort(entries,function(a,b)return a.label<b.label end)
  end
  if root and (not live() or not active.views[vim.fs.normalize(root)]) then
    entries[#entries+1]={label='Current project · '..root,run=function()return M.open(root)end}
  end
  if root and not configure then entries[#entries+1]={label='Notation review / milestones · '..root,run=function()return M.review(root)end} end
  if not configure and (not live() or not active.views.new) then entries[#entries+1]={label='New score',run=M.new} end
  entries[#entries+1]={label='Open project…',run=function()return M.browse(opts)end}
  local function run(entry)
    local ok,err=pcall(entry.run)
    if not ok then vim.notify(tostring(err),vim.log.levels.ERROR) end
  end
  local ok,pickers=pcall(require,'telescope.pickers')
  if not ok then
    return vim.ui.select(entries,{prompt=title,format_item=function(entry)return entry.label end},
      function(entry)if entry then run(entry)end end)
  end
  local actions=require('telescope.actions')
  local action_state=require('telescope.actions.state')
  return pickers.new(opts,{
    prompt_title=title,
    finder=require('telescope.finders').new_table({results=entries,entry_maker=function(entry)
      return {value=entry,display=entry.label,ordinal=entry.label}
    end}),
    sorter=require('telescope.config').values.generic_sorter(opts),previewer=false,
    attach_mappings=function(prompt_bufnr)
      actions.select_default:replace(function()
        local selected=action_state.get_selected_entry()
        if not selected then return end
        actions.close(prompt_bufnr)
        vim.schedule(function()run(selected.value)end)
      end)
      return true
    end,
  }):find()
end

return M
