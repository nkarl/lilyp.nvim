-- Workspace layout only. Controllers own fields, drafts, and domain actions.
local M = {}
local ns = vim.api.nvim_create_namespace('LilyPondForm')

function M.short(value, width)
  width=math.max(1,width)
  value=tostring(value or ''):gsub('[\r\n\t]',' ')
  if vim.fn.strdisplaywidth(value)<=width then return value end
  local result=''
  for _,char in ipairs(vim.fn.split(value,'\\zs')) do
    if vim.fn.strdisplaywidth(result..char)>width-1 then break end
    result=result..char
  end
  return result..'…'
end

-- Wrap explanatory prose without cutting Unicode characters or long paths.
function M.wrap(text,width)
  local lines,line={},''
  for word in tostring(text or ''):gmatch('%S+') do
    if line~='' and vim.fn.strdisplaywidth(line..' '..word)>width then
      lines[#lines+1]=line;line=''
    end
    while vim.fn.strdisplaywidth(word)>width do
      local chunk=M.short(word,width+1):gsub('…$','')
      lines[#lines+1]=chunk;word=word:sub(#chunk+1)
    end
    line=line=='' and word or line..' '..word
  end
  if line~='' then lines[#lines+1]=line end
  return lines
end

local function geometry()
  local width,height=math.min(190,vim.o.columns-4),math.min(50,vim.o.lines-4)
  return {relative='editor',row=math.floor((vim.o.lines-height-2)/2),
    col=math.floor((vim.o.columns-width-2)/2),width=width,height=height}
end

function M.open(title)
  if vim.o.columns<72 or vim.o.lines<27 then
    vim.notify('Lylip needs at least 72 columns and 27 terminal rows.',vim.log.levels.WARN)
    return
  end
  for name,link in pairs({Heading='Title',Tab='Comment',ActiveTab='TabLineSel',Label='NormalFloat',
    Value='String',Muted='Comment',Selected='Visual',Action='Special',Error='DiagnosticError',
    Changed='DiagnosticWarn',Source='Special',Separator='FloatBorder'}) do
    vim.api.nvim_set_hl(0,'LilyForm'..name,{default=true,link=link})
  end
  local buf=vim.api.nvim_create_buf(false,true)
  vim.bo[buf].bufhidden,vim.bo[buf].swapfile='wipe',false
  local win=vim.api.nvim_open_win(buf,true,vim.tbl_extend('force',geometry(),{
    style='minimal',border='rounded',title=' '..title..' ',title_pos='center'}))
  vim.wo[win].wrap,vim.wo[win].cursorline=false,false
  vim.wo[win].scrolloff,vim.wo[win].sidescrolloff=0,0
  vim.wo[win].winhighlight='Normal:NormalFloat,FloatBorder:FloatBorder'
  return {buf=buf,win=win}
end

function M.resize(state)
  if vim.api.nvim_win_is_valid(state.win) and vim.o.columns>=72 and vim.o.lines>=27 then
    vim.api.nvim_win_set_config(state.win,geometry())
  end
end

function M.row(state,index) return state.layout.first+(index-state.layout.offset-1)*(state.layout.stride or 1) end
function M.index(state,row)
  local l=state.layout
  return math.max(1,math.min(l.count,math.floor((row-l.first+(l.stride or 1)-1)/(l.stride or 1))+l.offset+1))
end
function M.cursor_index(state)
  local cursor=vim.api.nvim_win_get_cursor(state.win)
  local row,col=unpack(cursor)
  local text=vim.api.nvim_buf_get_lines(state.buf,row-1,row,false)[1] or ''
  col=vim.fn.strdisplaywidth(text:sub(1,col))
  if state.layout.sidebar>0 and col<state.layout.sidebar then
    if state.nav_rows[row] then
      state.focus='navigation';state.nav_selection=state.nav_rows[row];state.redraw()
    end
    return
  end
  if state.layout.show_center and (not state.layout.show_settings or col<state.layout.settings_left) then
    if row>=7 and row<=state.layout.body_last then
      state.focus='center';state.center_cursor=row-7+(state.center_offset or 0)+1;state.redraw()
    end
    return
  end
  local index=M.index(state,row)
  if state.layout.show_settings and col>=state.layout.settings_left and state.focus~='settings' then
    state.focus='settings';state.redraw()
  end
  if state.focus~='settings' then return end
  return index
end
function M.byte_column(text,column)
  local width,byte=0,0
  for _,char in ipairs(vim.fn.split(text,'\\zs')) do
    local next_width=width+vim.fn.strdisplaywidth(char)
    if next_width>column then break end
    width=next_width;byte=byte+#char
  end
  return byte
end
function M.prefix(field,state)
  local l=state.layout
  local row=M.row(state,l.selection)
  local line=vim.api.nvim_buf_get_lines(state.buf,row-1,row,false)[1]
  return line:sub(1,l.value_bytes[row])
end

function M.render(state,view)
  return require('lilyp.workspace_layout').render(state,view,M,ns)
end

-- Optional Telescope selection, with a working native fallback.
function M.search(state,entries)
  local function choose(item)
    if item and not state.closed then state.focus='settings';item.run() end
  end
  local ok,pickers=pcall(require,'telescope.pickers')
  if not ok then
    return vim.ui.select(entries,{prompt='Find a setting',format_item=function(item)return item.label end},choose)
  end
  return pickers.new({}, {prompt_title='Lylip · Find a setting',previewer=false,
    finder=require('telescope.finders').new_table({results=entries,entry_maker=function(item)
      return {value=item,display=item.label,ordinal=item.label}
    end}),sorter=require('telescope.config').values.generic_sorter({}),
    attach_mappings=function(buf)
      require('telescope.actions').select_default:replace(function()
        local selected=require('telescope.actions.state').get_selected_entry()
        require('telescope.actions').close(buf)
        if selected then vim.schedule(function()choose(selected.value)end) end
      end)
      return true
    end}):find()
end

function M.attach(state)
  local original={}
  for _,mapping in ipairs(vim.api.nvim_buf_get_keymap(state.buf,'n')) do original[mapping.lhs]=mapping.callback end
  local function map(key,fn)
    vim.keymap.set('n',key,function()
      if state.busy or (state.finish_edit and not state.finish_edit(false)) then return end
      fn()
    end,{buffer=state.buf,silent=true,nowait=true})
  end
  function state.show_center(kind)
    assert(vim.tbl_contains({'Overview','Source','Changes'},kind),'Unknown center view')
    if state.finish_edit and not state.finish_edit(false) then return end
    state.center_tab=kind;state.focus='center';state.redraw()
  end
  function state.toggle_inspector()
    state.inspector_closed=not state.inspector_closed
    state.focus=state.inspector_closed and 'center' or 'settings';state.redraw()
  end
  function state.resize_inspector(delta)
    state.inspector_width=math.max(42,math.min(96,(state.inspector_width or 52)+delta))
    state.redraw()
  end
  local function pane(delta)
    local panes={}
    if state.layout.sidebar>0 then panes[#panes+1]='navigation' end
    panes[#panes+1]='center'
    if not state.inspector_closed then panes[#panes+1]='settings' end
    local index=1
    for i,name in ipairs(panes) do if name==state.focus then index=i end end
    state.focus=panes[(index-1+delta)%#panes+1];state.redraw()
  end
  map('<Tab>',function()pane(1)end);map('<S-Tab>',function()pane(-1)end)
  local function scroll(delta)
    if state.focus=='center' then
      state.center_cursor=math.max(1,math.min(#(state.center_lines or {}),(state.center_cursor or 1)+delta))
    else state.detail_offset=math.max(0,(state.detail_offset or 0)+delta) end
    state.redraw()
  end
  for _,pair in ipairs({{'j',1},{'<Down>',1},{'k',-1},{'<Up>',-1}}) do
    local key,delta=unpack(pair)
    map(key,function()
      if state.focus=='navigation' and state.layout.sidebar>0 then
        local count=#state.workspace_view.outline
        state.nav_selection=((state.nav_selection or 1)-1+delta)%count+1;state.redraw()
      elseif state.focus=='center' then scroll(delta)
      else original[key]() end
    end)
  end
  local function inspect()
    state.focus='settings';state.inspector_closed=false;state.redraw()
  end
  map('<CR>',function()
    if state.focus=='navigation' and state.layout.sidebar>0 then
      local item=state.workspace_view.outline[state.nav_selection or 1]
      if item then state.focus='settings';state.inspector_closed=false;item.run() end
    elseif state.focus=='center' then
      if state.open_center then state.open_center() else inspect() end
    else original['<CR>']() end
  end)
  for _,key in ipairs({'i','a'}) do
    if original[key] and state.mode=='new' then
      map(key,function()if state.focus=='settings' then original[key]() end end)
    end
  end
  for _,key in ipairs({'h','l','<Left>','<Right>','<Space>'}) do
    map(key,function()
      if state.focus=='settings' then original[key]()
      elseif state.focus=='center' then
        local delta=(key=='h' or key=='<Left>') and -4 or 4
        state.center_left=math.max(0,(state.center_left or 0)+delta);state.redraw()
      end
    end)
  end
  for _,key in ipairs({'1','2','3','4','5','[',']'}) do
    map(key,function()state.focus='settings';state.inspector_closed=false;if original[key] then original[key]() end end)
  end
  map('/',function()state.inspector_closed=false;state.search()end)
  if state.mode~='history' then
    map('R',function()require('lilyp.readability').choose(state)end)
    map('A',function()
      state.advanced=not state.advanced
      if state.mode=='new' then state.selections[state.tab]=1 else state.selection=1 end
      state.status=state.advanced and 'Advanced spacing controls shown.' or 'Advanced spacing controls hidden.';state.redraw()
    end)
  end
  map('N',state.choose_navigation)
  map('O',function()state.show_center('Overview')end)
  map('S',function()state.show_center('Source')end)
  map('D',function()state.show_center('Changes')end)
  map('d',function()state.show_center('Changes')end)
  map('I',state.toggle_inspector)
  map('{',function()state.resize_inspector(-4)end)
  map('}',function()state.resize_inspector(4)end)
  map('f',function()
    if state.choose_source then return state.choose_source() end
    if state.focus~='center' or state.center_tab~='Source' then return end
    local content=state.center_content_view
    local files=content and content.files
    if not files then return end
    table.sort(files)
    vim.ui.select(files,{prompt='Inspect source snapshot'},function(path)
      if path and not state.closed and state.is_current() then state.center_source_path=path;state.redraw() end
    end)
  end)
  map('L',function()state.expanded=not state.expanded;state.detail_offset=0;inspect()end)
  map('<C-d>',function()scroll(3)end)
  map('<C-u>',function()scroll(-3)end)
  map('?',function()
    local lines={'Lylip workspace','',
      'Tab / Shift+Tab: cycle outline, center, and configuration. N opens the outline picker.',
      'j/k or arrows: move in the focused pane. Enter selects an outline item or edits a control.',
      'h/l: adjust a control, or scroll source horizontally. 1–5 or [ / ]: configuration categories.',
      '/: search all settings. L: expand explanation and source details.',
      'R: stage a readability trial profile. A: show/hide advanced spacing controls.',
      'O / S / D: Overview / Source / Changes in the center. f chooses a source file.',
      'I: toggle configuration. { / }: resize it on wide screens.',
      'Ctrl+D / Ctrl+U: scroll the focused center or configuration explanation.',
      'While editing: Enter saves to draft; Escape cancels; Ctrl+U clears.',
      '',state.workspace_view.navigation,
      state.mode=='project' and 'c Scope · u Inherit · U Undo selected setting · i Import section · o Style source · s Sections · r Revert all'
        or 'v Audition · x Stop · r Reset · Engraving: u Reset/inherit · Sections: + Add, - Remove, K/J Reorder',
      'H: home (retains drafts). q: close application (discards retained drafts).',
      state.mode=='project' and 'b Switch comparison · y/v Use YAML/keep source · Y/V All supported · x Clear choice · e Reload (discards drafts)' or '',
      'Draft edits do not write project files. Inspect Changes before Apply.'}
    M.popover(state,lines,' Help ')
  end)
end

function M.popover(state,lines,title,filetype)
  if state.close_preview then state.close_preview() end
  local buf=vim.api.nvim_create_buf(false,true)
  vim.bo[buf].bufhidden,vim.bo[buf].swapfile='wipe',false
  vim.api.nvim_buf_set_lines(buf,0,-1,false,lines)
  vim.bo[buf].modifiable=false
  if filetype then vim.bo[buf].filetype=filetype end
  local width=math.min(140,vim.o.columns-6)
  state.preview_win=vim.api.nvim_open_win(buf,true,{relative='editor',row=2,
    col=math.floor((vim.o.columns-width-2)/2),width=width,height=math.min(#lines+1,vim.o.lines-6),
    style='minimal',border='rounded',title=title..' · q returns '})
  vim.wo[state.preview_win].wrap=true
  for _,key in ipairs({'q','<Esc>'}) do vim.keymap.set('n',key,state.close_preview,{buffer=buf,silent=true}) end
  return buf
end
return M
