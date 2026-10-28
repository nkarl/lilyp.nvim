-- Isolated editor host for the optional real-browser test; no Python dependency.
local root=vim.fn.fnamemodify(debug.getinfo(1,'S').source:sub(2),':p:h:h')
vim.opt.rtp:prepend(root)
local fs=require('lilyp.fs')
local directory=assert(arg[1])
local app=require('lilyp')
app.setup({python='/not-used/python',build_location='project'})
vim.cmd.edit(vim.fn.fnameescape(directory..'/main.ly'))
local context=require('lilyp.score_context').resolve()
local socket=vim.fn.serverstart(directory..'/editor.sock')
local done=false
local first,session,latest
local function error_report(message)
  fs.write(directory..'/error.txt',message);done=true
end
_G.lilyp_browser_rebuild=function()
  app.compile({context=context,on_error=error_report,on_done=function(artifact)latest=artifact end})
  return true
end
_G.lilyp_browser_forward=function()
  local buf=vim.fn.bufadd(first.source);vim.fn.bufload(buf);vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_win_set_cursor(0,{first.line,require('lilyp.source_index').byte_column(first)})
  app.forward_search({context=vim.tbl_extend('force',context,{buf=buf,source=first.source}),launch=false,on_error=error_report})
  return true
end
_G.lilyp_browser_reset=function()
  vim.api.nvim_set_current_buf(context.buf);vim.api.nvim_win_set_cursor(0,{1,0});return true
end
_G.lilyp_browser_clicked=function()
  local position=vim.api.nvim_win_get_cursor(0)
  return vim.api.nvim_buf_get_name(0)==first.source and position[1]==first.line and position[2]==require('lilyp.source_index').byte_column(first)
end
_G.lilyp_browser_editor_state=function()
  return vim.json.encode({source=vim.api.nvim_buf_get_name(0),cursor=vim.api.nvim_win_get_cursor(0),
    tick=vim.api.nvim_buf_get_changedtick(0),modified=vim.bo.modified})
end
_G.lilyp_browser_dirty=function()
  local buf=vim.fn.bufadd(first.source);vim.fn.bufload(buf);vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf,0,0,false,{'% unsaved overlay test'})
  return true
end
_G.lilyp_browser_discard=function()
  vim.api.nvim_buf_call(vim.fn.bufnr(first.source),function()vim.cmd('silent edit!')end)
  return true
end
_G.lilyp_browser_static_preview=function()
  local jobstart,arguments=vim.fn.jobstart,arg
  local url
  vim.fn.jobstart=function(command,opts)
    assert(opts.detach and command[#command]:match('^%-%-app=file://'))
    url=command[#command]:sub(7);return 123
  end
  arg=latest.pages
  local ok,err=pcall(dofile,root..'/scripts/svg_preview.lua')
  vim.fn.jobstart,arg=jobstart,arguments
  assert(ok,err);return assert(url)
end
_G.lilyp_browser_stop=function()done=true;return true end
app.compile({context=context,on_error=error_report,on_done=function(artifact)
  latest=artifact
  session=app.view({context=context,launch=false})
  local samples={}
  for position,entry in ipairs(session.manifest.entries) do
    local kind=session.origins[position].kind
    if not samples[kind] then samples[kind]=entry.key end
    local result=session.origins[position].inspection
    if result.tag=='supported' then
      local symbol=result.symbol
      if not samples['symbol_'..symbol.kind] then samples['symbol_'..symbol.kind]=entry.key end
      if not samples.resolved and symbol.kind=='note' then samples.resolved=entry.key;first=entry end
      if symbol.kind=='rest' then samples.rest=entry.key end
      if kind=='macro' and symbol.kind=='note' then samples.helper=entry.key end
      if symbol.kind=='note' and symbol.chord_size>1 then samples.chord=entry.key end
    end
    if not first and kind=='token' then first=entry end
  end
  assert(first,'Fixture has no source links')
  fs.write(directory..'/ready.json',vim.json.encode({url=session.server.url,socket=socket,artifact=artifact,revision=session.manifest.revision,first=first,samples=samples}))
end})
assert(vim.wait(120000,function()return done end,20),'Browser test host timed out')
require('lilyp.svg_navigation').close_all()
