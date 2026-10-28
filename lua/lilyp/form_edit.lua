-- Shared inline editing; each view retains validation and domain navigation.
local form=require('lilyp.form')
local M={}
function M.attach(state,options)
  local editor={}
  function editor.begin(field,row,value)
    if not state.layout.show_settings or state.focus~='settings' then
      state.focus='settings';state.inspector_closed=false;options.redraw()
      row=form.row(state,state.layout.selection)
    end
    local prefix=form.prefix(field,state)
    local text=prefix..value
    state.editing={row=row,prefix=prefix,field=field}
    vim.bo[state.buf].modifiable=true
    vim.api.nvim_buf_set_lines(state.buf,row-1,row,false,{text})
    vim.api.nvim_win_set_cursor(state.win,{row,#text})
    vim.cmd('startinsert!')
  end
  function editor.finish(cancel)
    local editing=state.editing
    if not editing then return true end
    state.editing=nil
    vim.cmd('stopinsert')
    if cancel then state.status='Edit cancelled.';options.redraw();return true end
    local line=vim.api.nvim_buf_get_lines(state.buf,editing.row-1,editing.row,false)[1] or ''
    if line:sub(1,#editing.prefix)~=editing.prefix then
      options.invalid_prefix(editing.field);return false
    end
    return options.commit(editing.field,line:sub(#editing.prefix+1))
  end
  function editor.bind(move)
    local function map(key,fn,opts)
      vim.keymap.set('i',key,fn,vim.tbl_extend('force',{buffer=state.buf,silent=true,nowait=true},opts or {}))
    end
    map('<CR>',function()editor.finish(false)end)
    map('<Esc>',function()editor.finish(true)end)
    for _,key in ipairs({'<Tab>','<Down>'}) do map(key,function()move(1)end) end
    for _,key in ipairs({'<S-Tab>','<Up>'}) do map(key,function()move(-1)end) end
    map('<C-u>',function()
      local e=state.editing
      if e then
        vim.api.nvim_buf_set_lines(state.buf,e.row-1,e.row,false,{e.prefix})
        vim.api.nvim_win_set_cursor(state.win,{e.row,#e.prefix})
      end
    end)
    for _,key in ipairs({'<BS>','<Left>'}) do map(key,function()
      if state.editing and vim.api.nvim_win_get_cursor(state.win)[2]<=#state.editing.prefix then return '' end
      return key
    end,{expr=true}) end
    map('<Home>',function()
      if state.editing then vim.api.nvim_win_set_cursor(state.win,{state.editing.row,#state.editing.prefix}) end
    end)
    vim.api.nvim_create_autocmd('InsertLeave',{buffer=state.buf,callback=function()editor.finish(false)end})
  end
  return editor
end
return M
