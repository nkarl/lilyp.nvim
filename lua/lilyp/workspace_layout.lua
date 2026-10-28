-- Three independent viewports in one application buffer. Coordinates are display
-- columns until final composition; editing receives byte offsets from that result.
local M={}
function M.render(state,view,form,ns)
  state.workspace_view=view
  state.focus=state.focus or 'settings'
  state.center_tab=state.center_tab or 'Overview'
  local width,height=vim.api.nvim_win_get_width(state.win),vim.api.nvim_win_get_height(state.win)
  local sidebar=width>=96 and 22 or 0
  local three=width>=116
  local body_left=sidebar>0 and sidebar+3 or 2
  local body_width=width-body_left-2
  local inspector=not state.inspector_closed
  local show_center=three or not inspector or state.focus=='center'
  local show_settings=inspector and (three or state.focus~='center')
  local settings_width=body_width
  local settings_left=body_left
  local center_width=body_width
  if three and inspector then
    settings_width=math.max(42,math.min(state.inspector_width or 52,width-sidebar-42))
    settings_left=width-settings_width-2
    center_width=settings_left-body_left-3
  end
  local key=(view.scope_key or '')..'/'..view.tab..'/'..view.selection
  if state.detail_key~=key then state.detail_offset=0;state.detail_key=key end
  local segments,marks,inline_marks={},{},{}
  for row=1,height do segments[row]={} end
  local function put(row,col,text,group,limit)
    if row<1 or row>height then return end
    text=form.short(text,math.max(1,math.min(limit or width,width-col-2)))
    segments[row][#segments[row]+1]={col=col,text=text,group=group}
  end
  local function rule(row,col,length)
    put(row,col,string.rep('─',math.max(1,length)),'LilyFormSeparator',length)
  end
  put(1,2,view.heading,'LilyFormHeading')
  put(2,2,view.context or '',view.error and 'LilyFormError' or 'LilyFormChanged')
  rule(3,2,width-4)
  local body_last=height-4
  local layout={sidebar=sidebar,three=three,show_center=show_center,show_settings=show_settings,
    settings_left=settings_left,settings_width=settings_width,center_left=body_left,center_width=center_width,
    count=#view.fields,selection=view.selection,value_bytes={},actions_row=height-2,body_last=body_last}
  state.layout=layout
  state.nav_rows={}
  if sidebar>0 then
    put(4,2,view.outline_title or 'PROJECT OUTLINE','LilyFormHeading',sidebar-3)
    local nav=view.outline or view.sidebar or {}
    if state.outline_key~=view.scope_key then
      state.outline_key=view.scope_key
      for index,item in ipairs(nav) do if item.active then state.nav_selection=index end end
    end
    local selected=math.max(1,math.min(state.nav_selection or 1,#nav))
    state.nav_selection=selected
    local capacity=body_last-5
    local offset=math.max(0,selected-capacity)
    for index=offset+1,math.min(#nav,offset+capacity) do
      local row=5+index-offset
      local item=nav[index]
      put(row,2,(item.active and '● ' or '  ')..item.label,
        state.focus=='navigation' and index==selected and 'LilyFormSelected' or item.active and 'LilyFormActiveTab' or 'LilyFormMuted',sidebar-6)
      if item.dirty then put(row,sidebar-3,'•','LilyFormChanged',1) end
      state.nav_rows[row]=index
    end
    for row=4,body_last do put(row,sidebar,'│','LilyFormSeparator',1) end
  end
  if show_center then
    local content=state.center_content(state.center_tab)
    state.center_content_view=content
    local at=body_left
    for _,name in ipairs({'Overview','Source','Changes'}) do
      put(4,at,name,state.center_tab==name and 'LilyFormActiveTab' or 'LilyFormTab',#name)
      at=at+#name+2
    end
    put(5,body_left,content.title or '', 'LilyFormMuted',center_width)
    local lines={}
    local source_rows={}
    for i,line in ipairs(content.lines) do
      local wrapped=content.prose and form.wrap(line,center_width) or {line}
      if #wrapped==0 then wrapped={''} end
      source_rows[i]=#lines+1
      for _,part in ipairs(wrapped) do lines[#lines+1]={text=part,original=i} end
    end
    local capacity=body_last-6
    local first=7
    if state.center_content_key~=content.key then
      state.center_content_key=content.key
      state.center_cursor=source_rows[content.focus_line or 1] or 1
      state.center_offset=math.max(0,state.center_cursor-math.floor(capacity/2))
      state.center_left=0
    end
    state.center_cursor=math.max(1,math.min(state.center_cursor or 1,math.max(1,#lines)))
    local offset=math.max(0,math.min(state.center_offset or 0,math.max(0,#lines-capacity)))
    if state.center_cursor<=offset then offset=state.center_cursor-1 end
    if state.center_cursor>offset+capacity then offset=state.center_cursor-capacity end
    state.center_offset=offset
    state.center_lines=lines
    layout.center_first,layout.center_last,layout.center_offset=first,body_last,offset
    for i=offset+1,math.min(#lines,offset+capacity) do
      local line=lines[i]
      local text=line.text
      local group='LilyFormLabel'
      if content.source then
        local chars=vim.fn.strcharpart(text,state.center_left or 0)
        text=string.format('%4d ',line.original)..chars
        group=line.original==content.focus_line and 'LilyFormSelected' or 'LilyFormSource'
      elseif content.diff then
        group=text:match('^%+') and 'DiffAdd' or text:match('^%-') and 'DiffDelete' or text:match('^@@') and 'DiffChange' or group
        text=vim.fn.strcharpart(text,state.center_left or 0)
      end
      if state.focus=='center' and i==state.center_cursor then group='LilyFormSelected' end
      local row=first+i-offset-1
      local visible=form.short(text,center_width):gsub('…$','')
      put(row,body_left,text,group,center_width)
      if content.highlights and content.highlights[line.original] then
        local original=line.text
        local hidden=#original-#vim.fn.strcharpart(original,state.center_left or 0)
        for _,span in ipairs(content.highlights[line.original]) do
          local a,b=math.max(0,span[1]-hidden),math.min(#visible,span[2]-hidden)
          if b>a then inline_marks[#inline_marks+1]={'DiffText',row-1,body_left+a,body_left+b,display=true} end
        end
      end
    end
    if three and inspector then
      for row=4,body_last do put(row,settings_left-2,'│','LilyFormSeparator',1) end
    end
  end
  if show_settings then
    put(4,settings_left,view.inspector_title or 'CONFIGURATION · I hides','LilyFormHeading',settings_width)
    put(5,settings_left,view.scope_label or 'Score defaults','LilyFormChanged',settings_width)
    local row,col=6,settings_left
    for i,name in ipairs(view.tabs) do
      local label=i..' '..name
      if col+#label>settings_left+settings_width then row=row+1;col=settings_left end
      put(row,col,label,i==view.tab and 'LilyFormActiveTab' or 'LilyFormTab',#label)
      col=col+#label+2
    end
    local stride=settings_width<64 and 2 or 1
    local first=row+2+(stride==2 and 1 or 0)
    local detail_height=state.expanded and math.min(12,math.floor(height/3)) or 5
    local detail_row=height-detail_height-4
    local last=detail_row-2
    local capacity=math.max(1,math.floor((last-first)/stride)+1)
    local offset=state.field_offset or 0
    if view.selection<=offset then offset=view.selection-1 end
    if view.selection>offset+capacity then offset=view.selection-capacity end
    offset=math.max(0,math.min(offset,math.max(0,#view.fields-capacity)))
    state.field_offset=offset
    layout.first,layout.last,layout.offset,layout.stride=first,last,offset,stride
    layout.detail_row=detail_row
    local label_width=math.min(26,math.floor(settings_width*0.43))
    for index=offset+1,math.min(#view.fields,offset+capacity) do
      local f=view.fields[index]
      local value_row=first+(index-offset-1)*stride
      local marker=index==view.selection and '› ' or '  '
      local prefix
      if stride==2 then
        put(value_row-1,settings_left,marker..f.label,'LilyFormLabel',settings_width)
        prefix='  '
      else
        local label=form.short(f.label,label_width)
        prefix=marker..label..string.rep(' ',math.max(0,label_width-vim.fn.strdisplaywidth(label)))..'  '
      end
      local badge=f.badge or ''
      local available=settings_width-vim.fn.strdisplaywidth(prefix)-(badge~='' and vim.fn.strdisplaywidth(badge)+2 or 0)
      local value=form.short(f.value=='' and '—' or f.value,math.max(1,available))
      put(value_row,settings_left,prefix..value,
        f.error and 'LilyFormError' or index==view.selection and state.focus=='settings' and 'LilyFormSelected'
          or f.changed and 'LilyFormChanged' or 'LilyFormValue',settings_width)
      if badge~='' then put(value_row,settings_left+settings_width-vim.fn.strdisplaywidth(badge),badge,'LilyFormMuted',vim.fn.strdisplaywidth(badge)) end
      layout.value_bytes[value_row]={column=settings_left,prefix=prefix,color=f.color,value=value}
    end
    rule(detail_row-1,settings_left,settings_width)
    local f=view.fields[view.selection]
    put(detail_row,settings_left,f.label..' · L '..(state.expanded and 'less' or 'syntax'),'LilyFormHeading',settings_width)
    local detail={}
    local function explain(text,group)
      for _,line in ipairs(form.wrap(text,settings_width)) do detail[#detail+1]={line,group} end
    end
    explain(view.help,'LilyFormMuted');explain(view.detail,'LilyFormMuted')
    if state.expanded then
      for _,line in ipairs(view.learning or {}) do explain(line,'LilyFormSource') end
      for _,line in ipairs(view.summary or {}) do explain(line,'LilyFormMuted') end
    end
    state.detail_lines=detail
    local count=detail_height-1
    state.detail_offset=math.max(0,math.min(state.detail_offset or 0,math.max(0,#detail-count)))
    for i=1,count do
      local line=detail[state.detail_offset+i]
      if line then put(detail_row+i,settings_left,line[1],line[2],settings_width) end
    end
  else
    -- Logical positions remain available to controllers; editing reopens the inspector.
    layout.first,layout.last,layout.offset,layout.stride=7,body_last,state.field_offset or 0,1
    layout.detail_row=body_last
  end
  rule(height-3,2,width-4)
  put(height-2,2,view.actions,'LilyFormAction')
  put(height-1,2,sidebar==0 and 'Tab Pane  N Outline  O/S/D Views  I Inspector  Enter Edit'
    or 'Tab Pane  Enter Edit  O/S/D Views  I Inspector  / Find  ? Help','LilyFormMuted')
  put(height,2,view.status or '',view.error and 'LilyFormError' or 'LilyFormChanged')
  local lines={}
  for row,items in ipairs(segments) do
    table.sort(items,function(a,b)return a.col<b.col end)
    local text=''
    for _,item in ipairs(items) do
      text=text..string.rep(' ',math.max(0,item.col-vim.fn.strdisplaywidth(text)))
      local start=#text;text=text..item.text
      if item.group then marks[#marks+1]={item.group,row-1,start,#text} end
      local edit=layout.value_bytes[row]
      if type(edit)=='table' and edit.column==item.col then
        local at=start+#edit.prefix
        layout.value_bytes[row]=at
        if edit.color and edit.value:match('^#%x%x%x%x%x%x$') then
          local hex=edit.value
          local group='LilyFormColor'..hex:sub(2)
          local r,g,b=tonumber(hex:sub(2,3),16),tonumber(hex:sub(4,5),16),tonumber(hex:sub(6,7),16)
          vim.api.nvim_set_hl(0,group,{bg=hex,fg=(r*0.299+g*0.587+b*0.114)>140 and '#000000' or '#ffffff'})
          marks[#marks+1]={group,row-1,at,at+7}
        end
      end
    end
    lines[row]=text
  end
  vim.bo[state.buf].modifiable=true
  vim.api.nvim_buf_set_lines(state.buf,0,-1,false,lines)
  vim.bo[state.buf].modifiable=false
  vim.api.nvim_buf_clear_namespace(state.buf,ns,0,-1)
  vim.list_extend(marks,inline_marks)
  for _,mark in ipairs(marks) do
    if mark.display then
      local base=form.byte_column(lines[mark[2]+1],body_left)
      mark[3],mark[4]=base+mark[3]-body_left,base+mark[4]-body_left
    end
    vim.api.nvim_buf_add_highlight(state.buf,ns,mark[1],mark[2],mark[3],mark[4])
  end
  if state.focus=='navigation' and sidebar>0 then
    for row,index in pairs(state.nav_rows) do if index==state.nav_selection then vim.api.nvim_win_set_cursor(state.win,{row,2});break end end
  elseif state.focus=='center' or not show_settings then
    local row=math.max(7,math.min(body_last,7+(state.center_cursor or 1)-(state.center_offset or 0)-1))
    local line=lines[row]
    vim.api.nvim_win_set_cursor(state.win,{row,form.byte_column(line,body_left)})
  else
    local row=form.row(state,view.selection)
    vim.api.nvim_win_set_cursor(state.win,{row,layout.value_bytes[row]})
  end
  vim.api.nvim_win_call(state.win,function()vim.fn.winrestview({leftcol=0,topline=1})end)
end
return M
