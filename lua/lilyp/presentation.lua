local outcome=require('lilyp.operation_outcome')
local fields=require('lilyp.fields')
local form=require('lilyp.form')
local M={}
local observation=require('lilyp.source_observation')
local binding=require('lilyp.source_binding')
local function display(value) return value==nil and 'Not declared' or tostring(value) end
function M.mount(state)
  state.tab,state.selection,state.status,state.busy=1,1,'',false
  state.comparison=#state.session.conflicts>0 and 'yaml' or 'proposed'
  if #state.session.conflicts>0 then state.center_tab='Changes' end
  local function close_preview()
    if state.preview_win and vim.api.nvim_win_is_valid(state.preview_win) then
      vim.api.nvim_win_close(state.preview_win,true)
    end
    state.preview_win=nil
    if state.is_current() then vim.api.nvim_set_current_win(state.win) end
  end
  state.close_preview=close_preview
  local function current_fields()
    local result={}
    for _,f in ipairs(fields.list) do
      if f.tab==state.tab and (not f.advanced or state.advanced) then
        result[#result+1]=f
        if state.session:conflict(f.id,state.scope) then
          result[#result+1]={id=f.id,tab=f.tab,label='Resolution',resolution=true,kind='resolution'}
        end
      end
    end
    return result
  end
  local function view() return state.session:view(state.scope) end
  local function scope_name()
    if not state.scope then return 'Score defaults' end
    local entry=state.session.section_styles[state.scope]
    return entry.name..' ['..state.scope..']'
  end
  local function redraw()
    if state.editing or not state.is_current() then return end
    if not vim.api.nvim_buf_is_valid(state.buf) or not vim.api.nvim_win_is_valid(state.win) then return end
    local list=current_fields();state.selection=math.min(state.selection,#list)
    local s=state.session
    local rows={}
    local current=view()
    for _,f in ipairs(list) do
      local entry=current.entries[f.id]
      local changed=state.scope and current.specified and current.changed[f.id]
        or not state.scope and not vim.deep_equal(s.draft[f.id],s.values[f.id])
      local badge=changed and '• draft' or entry.tag=='recognized' and (s.specified and 'specified' or 'recognized')
        or entry.tag=='available' and 'available' or 'custom'
      if state.scope and entry.tag~='custom' and not changed then
        badge=current.origins[f.id] and current.origins[f.id].scope=='section'
          and (current.specified and current.overrides[f.id]~=nil and 'section override' or 'source override') or 'inherited'
      end
      if changed and state.scope then badge=current.overrides[f.id]~=nil and '• override' or '• inherited' end
      local value=current.values[f.id]
      local text=f.kind=='boolean' and value~=nil and (value and 'On' or 'Off') or display(value)
      if f.choice_labels and value~=nil then text=f.choice_labels[value] or text end
      if state.scope and entry.tag=='custom' then text='Custom / unavailable' end
      if state.scope and entry.tag~='custom' and value==nil and current.overrides[f.id]==nil then
        local shared=s.inspected[f.id]
        text=shared.tag=='recognized' and ('Source default: '..display(shared.value)) or 'Source default'
      end
      local conflict=s:conflict(f.id,state.scope)
      if conflict then
        local choice=s.resolutions[require('lilyp.reconciliation').key(f.id,state.scope)]
        if f.resolution then
          text=choice=='yaml' and 'Use YAML' or choice=='source' and 'Keep source change' or 'Unresolved'
          if not require('lilyp.reconciliation').actionable(s,conflict) then text='Manual correction needed' end
          badge='';changed=choice~=nil
        else badge=choice and 'resolved' or 'differs' end
      end
      rows[#rows+1]={label=f.label,value=text,changed=changed,badge=badge,color=f.color}
    end
    local f=list[state.selection]
    local entry=current.entries[f.id]
    local status=entry.tag=='recognized' and (s.specified and 'Specified' or 'Recognized')
      or entry.tag=='available' and 'Available' or 'Custom / unavailable'
    local detail=status..' · '..(observation.reason(entry) or 'Enter edits; h/l cycles choices or adjusts numbers.')
    if state.scope and not current.specified then detail='i imports local styling; editing also stages import. '..detail end
    local summary={'Scope: '..scope_name()..' · c selects scope',s.specified and 'YAML presentation specification · '..#s:changes()..' draft changes'
      or 'Initialize YAML specification from current styling'}
    local conflict=s:conflict(f.id,state.scope)
    local help=f.help or require('lilyp.learning').explanations[f.id]
    if conflict then
      help='YAML: '..display(conflict.expected)..' · Saved source: '..display(conflict.actual)
      detail='y Use YAML · v Keep source change · x Clear choice. Enter Resolution to choose.'
      if not require('lilyp.reconciliation').actionable(s,conflict) then detail='Custom or ambiguous styling requires manual correction, then e Reload.' end
    end
    local unresolved=s:unresolved()
    local message=state.status
    if #unresolved>0 then message=#unresolved..' unresolved YAML/source differences · '..(message~='' and message or 'b switches comparisons; Enter a difference to resolve')
    elseif s.metadata_cleanup then message='Apply will also remove legacy owner metadata.' end
    state.drawing=true
    local sidebar={{label='Score defaults',active=not state.scope,run=function()state.select_scope(nil)end}}
    for _,section in ipairs(s.sections) do
      sidebar[#sidebar+1]={label='  '..(section.name or section.id),active=state.scope==section.id,
        run=function()state.select_scope(section.id)end}
    end
    local pending={}
    for _,change in ipairs(s:changes()) do pending[change.section_id or 'score']=true end
    for index,item in ipairs(sidebar) do
      local section=index>1 and s.sections[index-1]
      local id=section and section.id or nil
      local count=0;for _,difference in ipairs(unresolved) do if difference.section_id==id then count=count+1 end end
      if count>0 then item.label='('..count..') '..item.label end
      item.dirty=pending[id or 'score'] or false
    end
    form.render(state,{
      heading='LYLIP · PRESENTATION  /  '..vim.fs.basename(s.root),
      context=scope_name()..' · '..(s.specified and #s:changes()..' draft changes' or 'Specification not initialized'),
      scope_label=scope_name(),scope_key=state.scope or 'score',outline=sidebar,
      sidebar=sidebar,learning=state.expanded and require('lilyp.learning').presentation(s,state.scope,f) or nil,
      tabs=fields.tabs,tab=state.tab,fields=rows,selection=state.selection,summary=summary,
      help=help,detail=detail,status=message,error=#unresolved>0,
      actions=state.busy and (state.operation and not state.operation:cancellable() and 'Finishing publication…' or 'Ctrl+C Cancel validation')
        or s.specified and 'p Preview   d Changes   a Apply   g Git review   H Home   q Close'
        or 'd Import plan   a Save spec   o Source   H Home   q Close',
      navigation='b Comparison · y/v Resolve selected · Y/V All supported · x Clear · e Reload (discards drafts) · r Revert',
    })
    state.drawing=false
  end
  function state.dispose()
    state.closed=true
    state.editing=nil
    close_preview()
    state.session:close()
  end
  local function report(action)
    if state.busy then return end
    state.busy=true;state.status='Compiling staged copies and checking playback…';redraw();vim.cmd('redraw')
    local ok,result=pcall(action)
    state.busy=false
    state.status=ok and (result or 'Done') or tostring(result)
    redraw()
    if not ok then vim.notify(tostring(result),vim.log.levels.ERROR) end
    return ok,result
  end
  local function report_async(action)
    if state.busy then return end
    state.busy=true
    state.status='Preparing staged validation…';redraw()
    local session=state.session
    local retained=#session.temporary
    local operation=require('lilyp.validation_job').start(action,function(result)
      state.operation=nil;state.busy=false
      if not state.closed then
        state.status=outcome.message(result)
        if result.tag=='cancelled' and #result.cleanup==0 then state.status='Validation cancelled; draft retained and nothing applied.' end
        redraw()
        if result.tag=='failed' or #result.cleanup>0 then
          vim.notify(outcome.message(result),result.tag=='failed' and vim.log.levels.ERROR or vim.log.levels.WARN)
        end
      end
      if state.on_idle then state.on_idle() end
    end,function(message,cancellable)
      state.status=message..(cancellable and ' Ctrl+C cancels.' or '')
      redraw()
    end)
    operation:defer('Discard attempt temporary copies',function(result)
      if result.tag=='succeeded' then return end
      local failures={}
      for i=#session.temporary,retained+1,-1 do
        local path=session.temporary[i]
        local ok,err=pcall(function()assert(vim.fn.delete(path,'rf')==0,'Could not remove '..path)end)
        if ok then table.remove(session.temporary,i) else failures[#failures+1]=tostring(err) end
      end
      assert(#failures==0,table.concat(failures,'\n'))
    end)
    state.operation=operation
    return state.operation
  end
  function state.cancel()
    if not state.operation then return false end
    local cancelled=state.operation:cancel()
    if cancelled then state.status='Cancelling validation…';redraw() end
    return cancelled
  end
  local finish_edit
  local positions={}
  local function position_key()return (state.scope or 'score')..'/'..state.tab end
  function state.switch_tab(tab)
    if finish_edit and not finish_edit(false) then return end
    positions[position_key()]=state.selection
    state.tab=(tab-1)%#fields.tabs+1;state.selection=positions[position_key()] or 1;redraw()
  end
  function state.set(id,value)
    if state.busy then return false end
    local ok,err=pcall(state.session.set,state.session,id,value,state.scope)
    state.status=ok and 'Draft updated; Preview or Apply when ready.' or tostring(err);redraw();return ok
  end
  local function apply(job)
    local applied,message=state.session:apply(job)
    if not applied then return message end
    local root=state.session.root
    local ok,err=pcall(state.session.close,state.session)
    local opened,fresh=pcall(require('lilyp.session').open,root)
    if opened then state.session=fresh end
    local issues={}
    if not ok then issues[#issues+1]='Previous session cleanup: '..tostring(err) end
    if not opened then issues[#issues+1]='Reload project: '..tostring(fresh) end
    if job then
      for _,issue in ipairs(issues) do job:issue(issue) end
      return 'Applied.'
    end
    for _,issue in ipairs(type(message)=='table' and message.cleanup or {}) do issues[#issues+1]=issue end
    return outcome.message(outcome.succeeded('Applied.','published',issues))
  end
  function state.apply()
    return report(function()return apply()end)
  end
  function state.apply_async()return report_async(apply)end
  local function preview(job)
    local preview=state.session:preview(job)
    local viewer=require('lilyp').options().viewer
    if viewer then viewer(preview.pdf)
    elseif require('lilyp.integrations.nvls').enabled then require('nvls.viewer').open(preview.pdf)
    else vim.ui.open(preview.pdf) end
    return 'Draft PDF opened; working files and build outputs are unchanged.'
  end
  function state.preview()
    if not state.session.specified then state.status='Initialize the YAML specification first.';redraw();return end
    return report(function()return preview()end)
  end
  function state.preview_async()
    if not state.session.specified then state.status='Initialize the YAML specification first.';redraw();return end
    return report_async(preview)
  end
  function state.changes()
    state.show_center('Changes')
    return state.center_content_view.lines
  end
  local editor=require('lilyp.form_edit').attach(state,{
    redraw=redraw,
    commit=function(field,text)
      return state.set(field.id,field.kind=='number' and tonumber(text) or text)
    end,
    invalid_prefix=function()
      state.status='Field label changed; edit discarded.';redraw()
    end,
  })
  finish_edit=editor.finish
  function state.sections()
    close_preview()
    local lines={'Declared section plan','Read-only · edit musical source by hand.',''}
    local plan=state.session.sections
    if type(plan)~='table' or #plan==0 then lines[#lines+1]='No section plan declared in score.yaml.'
    else
      for index,section in ipairs(plan) do
        if type(section)=='table' then
          lines[#lines+1]=index..'. '..display(section.name or section.id)..' · '..display(section.type)..' · '..display(section.verses)..' lyric rows'
          lines[#lines+1]='   '..display(section.source)..'  ['..display(section.id)..']'
          local override=section.staff_preset~=vim.NIL and section.staff_preset or nil
          local layout=override or state.session.staff_preset
          if layout and layout~=vim.NIL then lines[#lines+1]='   Staff arrangement: '..display(layout)..(override and '' or ' (score default)') end
          for _,voice in ipairs(type(section.voices)=='table' and section.voices or {}) do
            lines[#lines+1]='   '..display(voice.id)..' → '..display(voice.playback_voice)..' · '..display(voice.instrument)
          end
        end
      end
    end
    if type(state.session.printed_order)=='table' and #state.session.printed_order>0 then
      local order={};for _,id in ipairs(state.session.printed_order) do order[#order+1]=tostring(id) end
      lines[#lines+1]='';lines[#lines+1]='Declared printed order: '..table.concat(order,' → ')
    end
    local buf=vim.api.nvim_create_buf(false,true);vim.bo[buf].bufhidden='wipe'
    vim.api.nvim_buf_set_lines(buf,0,-1,false,lines);vim.bo[buf].modifiable=false
    state.preview_win=vim.api.nvim_open_win(buf,true,{relative='editor',row=2,col=3,width=math.min(108,vim.o.columns-6),
      height=math.min(#lines+1,vim.o.lines-6),style='minimal',border='rounded',title=' Sections · read-only · q returns '})
    for _,key in ipairs({'q','<Esc>'}) do vim.keymap.set('n',key,close_preview,{buffer=buf}) end
    return lines
  end
  local function edit()
    local f=current_fields()[state.selection]
    if f.resolution then
      local scope=state.scope
      local conflict=state.session:conflict(f.id,scope)
      if not require('lilyp.reconciliation').actionable(state.session,conflict) then
        state.status='Correct custom/ambiguous source manually, then e Reload.';redraw();return
      end
      local labels={unresolved='Unresolved',yaml='Use YAML',source='Keep source change'}
      vim.ui.select({'unresolved','yaml','source'},{prompt='Resolve '..fields.by_id[f.id].label,format_item=function(choice)return labels[choice]end},function(choice)
        if choice and not state.closed and state.is_current() and state.scope==scope then state.resolve(choice,f.id,scope) end
      end)
      return
    end
    local entry=view().entries[f.id]
    if not state.session.specified or (entry.tag~='recognized' and entry.tag~='available') then
      state.status=not state.session.specified and 'Initialize the YAML specification before editing presentation.' or observation.reason(entry)
      redraw();return
    end
    if f.id=='lyric_font' then
      local values=vim.tbl_extend('force',require('lilyp.presentation_model').import(state.session.inspected),view().values)
      local ok,fonts=pcall(require('lilyp.fonts').families,values)
      if not ok then state.status=tostring(fonts);redraw();return end
      local scope=state.scope
      vim.ui.select(fonts,{prompt='Compatible static lyric font family'},function(value)if value and not state.closed and state.is_current() and state.scope==scope then state.set(f.id,value) end end)
    elseif f.kind=='boolean' then state.set(f.id,not view().values[f.id])
    elseif f.choices then
      local values=vim.tbl_extend('force',require('lilyp.presentation_model').import(state.session.inspected),view().values)
      local choices=require('lilyp.fonts').choices(f.id,values,f.choices)
      local scope=state.scope
      vim.ui.select(choices,{prompt=f.label,format_item=function(value)return f.choice_labels and f.choice_labels[value] or tostring(value)end},function(value)
        if value~=nil and not state.closed and state.is_current() and state.scope==scope then state.set(f.id,value) end
      end)
    else
      local row=form.row(state,state.selection)
      local value=view().values[f.id]
      editor.begin(f,row,value~=nil and tostring(value) or '')
    end
  end
  local function adjust(delta)
    local f=current_fields()[state.selection];local value=view().values[f.id]
    if f.resolution then
      local choices={'unresolved','yaml','source'}
      local selected=state.session.resolutions[require('lilyp.reconciliation').key(f.id,state.scope)] or 'unresolved'
      local index=1;for i,choice in ipairs(choices) do if choice==selected then index=i end end
      state.resolve(choices[(index-1+delta)%#choices+1],f.id,state.scope)
    elseif f.choices then
      local values=vim.tbl_extend('force',require('lilyp.presentation_model').import(state.session.inspected),view().values)
      local choices=require('lilyp.fonts').choices(f.id,values,f.choices)
      if #choices==0 then state.status='No compatible font face; choose another family or reset weight/shape.';redraw();return end
      local index=0;for i,item in ipairs(choices) do if item==value then index=i end end
      state.set(f.id,choices[(index-1+delta)%#choices+1])
    elseif f.kind=='number' then state.set(f.id,require('lilyp.settings').adjust(f.id,value,delta))
    else edit() end
  end
  local function map(key,fn)
    vim.keymap.set('n',key,function()if not state.busy then fn()end end,{buffer=state.buf,silent=true,nowait=true})
  end
  local function move(delta)
    if not finish_edit(false) then return end
    state.selection=(state.selection-1+delta)%#current_fields()+1;redraw()
  end
  for _,key in ipairs({'j','<Tab>','<Down>'}) do map(key,function()move(1)end) end
  for _,key in ipairs({'k','<S-Tab>','<Up>'}) do map(key,function()move(-1)end) end
  editor.bind(move)
  vim.api.nvim_create_autocmd('CursorMoved',{buffer=state.buf,callback=function()
    if state.drawing or state.editing or not state.is_current() then return end
    local row=vim.api.nvim_win_get_cursor(state.win)[1]
    local index=form.cursor_index(state)
    if not index then return end
    if index~=state.selection or row<state.layout.first or row>state.layout.last then
      state.selection=index;redraw()
    end
  end})
  for i=1,#fields.tabs do map(tostring(i),function()state.switch_tab(i)end) end
  map('[',function()state.switch_tab(state.tab-1)end);map(']',function()state.switch_tab(state.tab+1)end)
  map('<CR>',edit)
  for _,key in ipairs({'h','<Left>'}) do map(key,function()adjust(-1)end) end
  for _,key in ipairs({'l','<Right>','<Space>'}) do map(key,function()adjust(1)end) end
  map('p',state.preview_async);map('d',state.changes);map('a',state.apply_async);map('s',state.sections)
  vim.keymap.set('n','<C-c>',state.cancel,{buffer=state.buf,silent=true,nowait=true,desc='Cancel staged validation'})
  map('g',function()require('lilyp.ui').review(state.session.root)end)
  function state.select_scope(id)
    if state.busy then return false end
    if not finish_edit(false) then return end
    assert(id==nil or state.session.section_styles[id],'Unknown section')
    positions[position_key()]=state.selection
    close_preview();state.scope=id;state.selection=positions[position_key()] or 1;state.status='';redraw()
  end
  function state.choose_scope()
    local choices={{name='Score defaults'}}
    for _,section in ipairs(state.session.sections) do
      local entry=state.session.section_styles[section.id]
      choices[#choices+1]={id=section.id,name=(section.name or section.id)..' ['..section.id..']'..(binding.available(entry) and '' or ' · unavailable')}
    end
    vim.ui.select(choices,{prompt='Presentation scope',format_item=function(item)return item.name end},function(item)
      if item and not state.closed then state.select_scope(item.id) end
    end)
  end
  function state.inherit(id)
    if state.busy then return false end
    if not state.scope then state.status='Select a section to reset an override.';redraw();return false end
    local ok,err=pcall(state.session.inherit,state.session,state.scope,id or current_fields()[state.selection].id)
    state.status=ok and 'Section override removed; inherits the score default.' or tostring(err);redraw();return ok
  end
  function state.import_section()
    if state.busy then return false end
    if not state.scope then state.status='Select a section first.';redraw();return false end
    local ok,err=pcall(state.session.enable_section,state.session,state.scope)
    state.status=ok and 'Section import staged; inspect Changes or Preview before Apply.' or tostring(err);redraw();return ok
  end
  map('c',state.choose_scope);map('u',state.inherit);map('i',state.import_section)
  function state.undo_setting()
    if state.busy then return false end
    local id=current_fields()[state.selection].id
    if state.session:conflict(id,state.scope) then return state.resolve('unresolved',id,state.scope) end
    local saved={draft=vim.deepcopy(state.session.draft),sections=vim.deepcopy(state.session.section_drafts)}
    local before=vim.deepcopy(view().values)
    local section_fonts={}
    if not state.scope then
      for _,section in ipairs(state.session.sections) do
        if binding.available(state.session.section_styles[section.id]) then
          section_fonts[section.id]=vim.deepcopy(state.session:view(section.id).values)
        end
      end
    end
    local ok,err=pcall(function()
      if state.scope then
        state.session:keep_section_setting(state.scope,id)
      else state.session.draft[id]=state.session.values[id] end
      require('lilyp.fonts').validate_change(before,view().values)
      for section_id,old in pairs(section_fonts) do
        require('lilyp.fonts').validate_change(old,state.session:view(section_id).values)
      end
    end)
    if not ok then state.session.draft=saved.draft;state.session.section_drafts=saved.sections end
    state.status=ok and 'Selected setting restored to its opening value.' or tostring(err)
    redraw();return ok
  end
  map('U',state.undo_setting)
  map('r',function()state.session:revert();state.status='All presentation drafts reverted';redraw()end)
  function state.source()
    local path,entry=require('lilyp.learning').source(state.session,state.scope,current_fields()[state.selection])
    path=path or state.session.style_path
    local text=state.session.snapshot[path]
    if not text then state.status='No source available for this setting.';redraw();return end
    local buf=form.popover(state,vim.split(text,'\n',{plain=true}),
      ' '..path..' · opening snapshot · read-only ','lilypond')
    local location=observation.locate(entry)
    if location then
      local _,row=text:sub(1,location.first-1):gsub('\n','')
      vim.api.nvim_win_set_cursor(state.preview_win,{row+1,0})
    end
    return buf
  end
  map('o',state.source)
  map('q',state.close);map('<Esc>',state.close)
  state.finish_edit=finish_edit
  state.redraw=redraw
  function state.apply_profile(id)
    if state.busy then return false end
    if not finish_edit(false) then return false end
    local ok,err=pcall(function()state.session:set_many(require('lilyp.readability').get(id),state.scope)end)
    state.status=ok and 'Readability trial staged; Preview to assess fit. Page targets and handwritten breaks are preserved.' or tostring(err)
    redraw();return ok
  end
  state.center_content=function(kind)
    return require('lilyp.workspace_content').presentation(state,kind,current_fields()[state.selection])
  end
  function state.search()
    local entries={}
    for _,f in ipairs(fields.list) do
      entries[#entries+1]={label=fields.tabs[f.tab]..' · '..f.label,run=function()
        if f.advanced then state.advanced=true end
        positions[position_key()]=state.selection
        state.tab=f.tab
        for index,item in ipairs(current_fields()) do if item.id==f.id then state.selection=index end end
        redraw()
      end}
    end
    return form.search(state,entries)
  end
  function state.choose_navigation()
    vim.ui.select(state.workspace_view.outline,{prompt='Project outline',format_item=function(item)return item.label end},
      function(item)if item and not state.closed then state.focus='settings';state.inspector_closed=false;item.run() end end)
  end
  function state.resolve(choice,id,scope)
    if state.busy then return false end
    if id==nil then
      if state.focus=='center' then
        local line=(state.center_lines or {})[state.center_cursor or 1]
        local content=state.center_content_view
        local conflict=line and content.targets and content.targets[line.original]
        if not conflict then state.status='Select a YAML/source difference first.';redraw();return false end
        id,scope=conflict.id,conflict.section_id
      else id=current_fields()[state.selection].id;scope=state.scope end
    end
    local ok,err=pcall(state.session.resolve_conflict,state.session,id,choice,scope)
    state.status=ok and 'Resolution staged; b shows the proposed file changes.' or tostring(err)
    redraw();return ok
  end
  function state.resolve_all(choice)
    if state.busy then return false end
    local ok,count=pcall(state.session.resolve_all,state.session,choice)
    state.status=ok and (count..' supported differences resolved in draft; '..#state.session:unresolved()..' remain.') or tostring(count)
    redraw();return ok
  end
  function state.focus_conflict(conflict)
    state.select_scope(conflict.section_id)
    local f=fields.by_id[conflict.id]
    if f then
      state.tab=f.tab
      if f.advanced then state.advanced=true end
      for index,item in ipairs(current_fields()) do if item.id==f.id and item.resolution then state.selection=index;break end end
    else state.status=conflict.reason or 'Correct this binding manually, then e Reload.' end
    state.focus='settings';state.inspector_closed=false;redraw()
  end
  function state.open_center()
    local line=(state.center_lines or {})[state.center_cursor or 1]
    local content=state.center_content_view
    local conflict=line and content.targets and content.targets[line.original]
    if conflict then return state.focus_conflict(conflict) end
    state.focus='settings';state.inspector_closed=false;redraw()
  end
  function state.compare(kind)
    assert(kind=='yaml' or kind=='proposed','Unknown comparison')
    state.comparison=kind;state.show_center('Changes')
  end
  function state.reload()
    if state.busy then return false end
    local ok,session=pcall(require('lilyp.session').open,state.session.root)
    if not ok then state.status=tostring(session);redraw();return false end
    state.session:close();state.session=session
    if state.scope and not session.section_styles[state.scope] then state.scope=nil end
    state.comparison=#session.conflicts>0 and 'yaml' or 'proposed'
    state.status='Reloaded saved project; previous drafts discarded.';redraw();return true
  end
  map('b',function()state.compare(state.comparison=='yaml' and 'proposed' or 'yaml')end)
  map('y',function()state.resolve('yaml')end);map('v',function()state.resolve('source')end)
  map('Y',function()state.resolve_all('yaml')end);map('V',function()state.resolve_all('source')end)
  map('x',function()state.resolve('unresolved')end);map('e',state.reload)
  form.attach(state)
  redraw();return state
end
return M
