-- Source review, deliberate workbench records, and stable backup milestones.
local git=require('lilyp.git')
local form=require('lilyp.form')
local messages=require('lilyp.commit_messages')
local M={}
function M.mount(state)
  state.tab,state.selection,state.status,state.center_tab=1,1,'','Changes'
  state.messages,state.presets,state.tag={},{},''
  local fields,editor
  local function kind() return state.tab==1 and 'record' or 'milestone' end
  local function section()
    local sections=state.metadata and type(state.metadata.sections)=='table' and state.metadata.sections or {}
    for _,item in ipairs(sections) do
      if type(item)=='table' and item.source==state.path then return item.name or item.id end
    end
    return state.path and state.path:match('([^/]+)%.i?ly$')
  end
  local function alive() return not state.closed and state.is_current() end
  local function close_preview()
    if state.preview_win and vim.api.nvim_win_is_valid(state.preview_win) then vim.api.nvim_win_close(state.preview_win,true) end
    state.preview_win=nil
  end
  state.close_preview=close_preview
  local function selected_changes()
    local result={}
    for _,item in ipairs(state.comparison or {}) do if item.path==state.path then result[#result+1]=item end end
    return result
  end
  local function center_content(view)
    local key=tostring(state.generation)..'/'..view..'/'..(state.path or '')..'/'..(state.selected_oid or '')
    if state.reviewed or state.restore_review then
      local plan=state.restore_review or state.reviewed
      local content=require('lilyp.review_diff').content(plan.changes,key..'/review/'..tostring(plan))
      content.title=state.restore_review and 'Restore review · saved files → selected version' or 'Commit review · exact saved source selection'
      return content
    end
    if view=='Changes' then
      local content=require('lilyp.review_diff').content(selected_changes(),key)
      content.title=(state.path or 'No source')..' · saved files vs '..(state.selected_oid and state.selected_oid:sub(1,8) or 'empty history')
      return content
    elseif view=='Source' then
      local text=state.saved[state.path] and state.saved[state.path].text or ''
      local lines=vim.split(text,'\n',{plain=true});local locations={}
      for i in ipairs(lines) do locations[i]={path=state.path,line=i} end
      return {title=(state.path or 'No source')..' · saved source',lines=lines,locations=locations,source=true,key=key}
    end
    local lines={'Project Git','',state.repo.enabled and 'Workbench: '..state.repo.branch or 'Git is not enabled for this project.',
      'Stable milestones: backup','', 'Only saved source files are recorded.',
      'F5 and Apply do not create Git commits.','Presentation drafts are separate from saved sources.',
      'Select a file on the left, compare it in the center, and choose a record on the right.',
      'Records use the current branch; milestones leave that branch and staging untouched.'}
    if state.repo.parent then lines[#lines+1]='Parent repository detected: '..state.repo.parent;lines[#lines+1]='Enable Git creates a repository at this score root.' end
    if not state.repo.enabled then lines[#lines+1]='Choose Enable Git to initialize this project.' end
    return {title='Notation review and milestones',lines=lines,key=key,prose=true}
  end
  function state.center_content(view)
    local key=table.concat({tostring(state.generation),view,state.path or '',state.selected_oid or '',
      tostring(state.reviewed),tostring(state.restore_review)},'/')
    if state.content_key~=key then state.content_key=key;state.cached_content=center_content(view) end
    return state.cached_content
  end
  local function redraw()
    if state.editing or not alive() then return end
    local k=kind()
    local outline={}
    local changed={}
    for _,item in ipairs(state.comparison or {}) do changed[item.path]=true end
    for _,path in ipairs(state.paths) do
      outline[#outline+1]={label=path,active=path==state.path,dirty=changed[path],run=function()state.select_source(path)end}
    end
    if #outline==0 then outline={{label='No source files',active=true,run=function()end}} end
    fields={
      {id='preset',label='Preset',value=state.presets[k]},
      {id='message',label='Message',value=state.messages[k]},
    }
    if k=='record' then fields[#fields+1]={id='scope',label='Record files',value=state.scope=='file' and 'Selected file' or 'All source files'}
    else fields[#fields+1]={id='tag',label='Tag (optional)',value=state.tag} end
    fields[#fields+1]={id='review',label='Review changes',value='Enter'}
    fields[#fields+1]={id='save',label=k=='record' and 'Record changes' or 'Save milestone',value=state.reviewed and 'Ready to save' or 'Review first'}
    if not state.repo.enabled then fields[#fields+1]={id='enable',label='Enable Git',value='Initialize this project'} end
    for _,entry in ipairs(state.entries) do fields[#fields+1]={id='history',entry=entry,label=entry.date,
      value=entry.message,badge=entry.oid==state.selected_oid and 'selected' or ''} end
    state.selection=math.max(1,math.min(state.selection,#fields))
    local selected=fields[state.selection]
    local explanation=selected.id=='message' and 'One editable message. Presets are optional; add a measure or detail when useful.'
      or selected.id=='tag' and 'Optional annotated milestone tag. Existing tags are never replaced.'
      or selected.id=='history' and 'Enter compares saved files with this version. r reviews a restore; no branch switch.'
      or 'Review the exact saved source selection before recording. Opening and comparing perform no writes.'
    state.drawing=true
    form.render(state,{heading='LYLIP · NOTATION REVIEW / '..vim.fs.basename(state.root),
      context='Workbench: '..(state.repo.branch or 'Git disabled')..' · Stable: backup · saved files only',
      outline_title='SOURCE FILES',inspector_title='RECORDS & MILESTONES',
      outline=outline,scope_key=state.path or '',scope_label=k=='record' and 'Workbench records' or 'Stable milestones',
      tabs={'Record','Milestone'},tab=state.tab,fields=fields,selection=state.selection,
      help=explanation,detail=state.selected_oid and ('Compare: '..state.selected_oid:sub(1,12)) or 'No recorded baseline.',
      summary={'Saved source files only. Generated outputs are excluded.'},
      actions='c Record   r Restore review   v Audition   g Refresh   P Presentation   H Home   q Close',
      navigation='Tab Panes · j/k Move · Enter Inspect/edit · 1 Record · 2 Milestone',status=state.status})
    state.drawing=false
  end
  state.redraw=redraw
  local function message_default()
    local k=kind()
    state.presets[k]=state.presets[k] or messages.last(k)
    state.messages[k]=state.messages[k] or messages.compose(state.presets[k],section())
  end
  function state.refresh()
    state.repo=git.inspect(state.root)
    state.saved=git.snapshot(state.root)
    local ok,metadata=pcall(require('lilyp.spec').read,state.saved['score.yaml'] and state.saved['score.yaml'].text or '')
    state.metadata=ok and metadata or nil
    state.entries=state.repo.enabled and git.history(state.root,kind()) or {}
    if not state.selected_oid then
      if kind()=='record' then state.selected_oid=state.repo.head else state.selected_oid=state.repo.milestone end
    end
    state.comparison=state.repo.enabled and git.compare(state.root,state.selected_oid) or {}
    local paths={}
    for path in pairs(state.saved) do paths[path]=true end
    for _,item in ipairs(state.comparison) do paths[item.path]=true end
    state.paths=vim.tbl_keys(paths);table.sort(state.paths)
    if not state.path or not paths[state.path] then
      local source=state.metadata and state.metadata.source or {}
      local main=type(source.main)=='string' and source.main or 'main.ly'
      state.path=paths[main] and main or state.paths[1]
    end
    message_default()
    state.reviewed,state.restore_review=nil,nil
    state.generation=(state.generation or 0)+1
    redraw()
  end
  local function report(fn)
    if state.busy then return end
    state.busy=true
    local ok,result=pcall(fn)
    state.busy=false
    state.status=ok and tostring(result or 'Done') or tostring(result)
    redraw();return ok,result
  end
  function state.enable() return report(function()git.enable(state.root);state.refresh();return 'Project Git enabled. Configure repository user.name and user.email if Git requests an identity.' end) end
  function state.select_source(path)
    if state.finish_edit and not state.finish_edit(false) then return end
    local previous=messages.compose(state.presets[kind()],section())
    state.path=path
    if state.messages[kind()]==previous then state.messages[kind()]=messages.compose(state.presets[kind()],section()) end
    state.reviewed,state.restore_review=nil,nil;redraw()
  end
  function state.select_history(entry)
    state.selected_oid=entry.oid;state.comparison=git.compare(state.root,entry.oid)
    local paths={};for path in pairs(state.saved) do paths[path]=true end
    for _,item in ipairs(state.comparison) do paths[item.path]=true end
    state.paths=vim.tbl_keys(paths);table.sort(state.paths)
    state.reviewed,state.restore_review=nil,nil;state.center_tab='Changes'
    state.generation=(state.generation or 0)+1;redraw()
  end
  function state.switch_tab(tab)
    if state.finish_edit and not state.finish_edit(false) then return end
    state.tab=(tab-1)%2+1;state.selection=1;state.selected_oid=nil;state.refresh()
  end
  function state.set(id,value)
    if id=='message' then state.messages[kind()]=value
    elseif id=='tag' then state.tag=value
    elseif id=='preset' then
      messages.remember(kind(),value);state.presets[kind()]=value;state.messages[kind()]=messages.compose(value,section())
    elseif id=='scope' then state.scope=value;state.reviewed=nil
    else error('Unknown review field: '..id) end
    redraw();return true
  end
  function state.review_changes()
    return report(function()
      state.restore_review=nil
      state.reviewed=git.plan(state.root,kind(),kind()=='record' and state.scope=='file' and {state.path} or nil)
      state.focus='center';state.center_tab='Changes'
      return #state.reviewed.changes..' source files reviewed. c saves this selection.'
    end)
  end
  function state.save()
    if state.finish_edit and not state.finish_edit(false) then return end
    if not state.reviewed then return state.review_changes() end
    return report(function()
      local hash=git.save(state.reviewed,state.messages[kind()],kind()=='milestone' and state.tag or nil)
      state.selected_oid=nil;state.refresh()
      return (kind()=='record' and 'Recorded ' or 'Milestone saved ')..hash:sub(1,12)
    end)
  end
  function state.review_restore(scope)
    return report(function()
      assert(state.selected_oid,'Select a recorded version first')
      state.reviewed=nil
      local selected
      if scope~='all' then selected={state.path} end
      state.restore_review=git.restore_plan(state.root,state.selected_oid,selected)
      state.focus='center';state.center_tab='Changes'
      return 'Restore review: '..#state.restore_review.changes..' files. r confirms; g cancels and refreshes.'
    end)
  end
  function state.restore_confirm()
    if not state.restore_review then
      return vim.ui.select({'Selected file','All source files'},{prompt='Review restore from selected version'},function(choice)
        if choice and alive() then state.review_restore(choice=='All source files' and 'all' or 'file') end
      end)
    end
    local plan=state.restore_review
    vim.ui.select({'Restore reviewed files','Cancel'},{prompt='Replace '..#plan.changes..' saved source files? Unrecorded changes will be replaced.'},function(choice)
      if choice~='Restore reviewed files' or not alive() or state.restore_review~=plan then return end
      report(function()local count=git.restore(plan);state.refresh();return 'Restored '..count..' files. Rebuild with F5.' end)
    end)
  end
  function state.choose_source()
    vim.ui.select(state.paths,{prompt='Review source file'},function(path)if path and alive() then state.select_source(path) end end)
  end
  state.choose_navigation=state.choose_source
  function state.open_center()
    local content=state.center_content_view
    local row=state.center_lines and state.center_lines[state.center_cursor or 1]
    local location=content and content.locations and content.locations[row and row.original or 1] or {path=state.path,line=1}
    if not location or not location.path then return end
    local path=require('lilyp.fs').inside(state.root,location.path)
    if vim.fn.filereadable(path)~=1 then state.status='This file is absent from saved sources.';redraw();return end
    vim.api.nvim_set_current_win(state.origin_win)
    vim.cmd.edit(vim.fn.fnameescape(path))
    vim.api.nvim_win_set_cursor(state.origin_win,{math.min(location.line,vim.api.nvim_buf_line_count(0)),0})
  end
  function state.audition()
    return report(function()
      vim.api.nvim_win_call(state.origin_win,function()
        assert(require('lilyp.project').root(vim.api.nvim_buf_get_name(0))==state.root,'Open a source file from this project before auditioning')
        assert(vim.fn.exists(':LilyPlayer')==2,'Playback requires the LilyPond suite')
        vim.cmd('LilyPlayer')
      end)
      return 'Auditioning the last built MIDI. F5 rebuilds saved notation.'
    end)
  end
  local function edit()
    local field=fields[state.selection]
    if field.id=='preset' then
      vim.ui.select(messages[kind()],{prompt='Commit message preset'},function(value)if value and alive() then state.set('preset',value) end end)
    elseif field.id=='message' or field.id=='tag' then
      editor.begin(field,form.row(state,state.selection),field.value)
    elseif field.id=='scope' then state.set('scope',state.scope=='file' and 'all' or 'file')
    elseif field.id=='review' then state.review_changes()
    elseif field.id=='save' then state.save()
    elseif field.id=='enable' then state.enable()
    elseif field.id=='history' then state.select_history(field.entry) end
  end
  editor=require('lilyp.form_edit').attach(state,{redraw=redraw,
    invalid_prefix=function()state.status='Keep the field label intact.';redraw()end,
    commit=function(field,value)
      if value:find('%c') then state.status='Use a single-line value.';redraw();return false end
      return state.set(field.id,value)
    end})
  state.finish_edit=editor.finish
  vim.api.nvim_create_autocmd('CursorMoved',{buffer=state.buf,callback=function()
    if state.drawing or state.editing or not alive() then return end
    local index=form.cursor_index(state)
    if index and index~=state.selection then state.selection=index;redraw() end
  end})
  local function map(key,fn)
    vim.keymap.set('n',key,function()if not state.busy and state.finish_edit(false) then fn() end end,{buffer=state.buf,silent=true,nowait=true})
  end
  local function move(delta)
    if not state.finish_edit(false) then return end
    state.selection=(state.selection-1+delta)%#fields+1;redraw()
  end
  for _,key in ipairs({'j','<Down>'}) do map(key,function()move(1)end) end
  for _,key in ipairs({'k','<Up>'}) do map(key,function()move(-1)end) end
  for _,key in ipairs({'h','l','<Left>','<Right>','<Space>','<CR>'}) do map(key,edit) end
  for i=1,2 do map(tostring(i),function()state.switch_tab(i)end) end
  map('[',function()state.switch_tab(state.tab-1)end);map(']',function()state.switch_tab(state.tab+1)end)
  editor.bind(move)
  function state.search()
    local entries={}
    for i,field in ipairs(fields) do entries[#entries+1]={label=field.label..' '..field.value,run=function()state.selection=i;redraw()end} end
    form.search(state,entries)
  end
  function state.dispose()state.closed=true;state.editing=nil;close_preview()end
  state.refresh()
  form.attach(state)
  map('c',state.save);map('e',state.enable);map('r',state.restore_confirm);map('v',state.audition)
  map('g',function()state.selected_oid=nil;state.refresh();state.status='Saved sources refreshed.';redraw()end)
  map('P',function()require('lilyp.ui').open(state.root)end)
  map('q',state.close);map('<Esc>',function()state.reviewed=nil;state.restore_review=nil;redraw()end)
  map('?',function()form.popover(state,{'Notation review and milestones','',
    'Left: source files. Center: saved source/diff. Right: presets, messages, and history.',
    '1: workbench records. 2: stable backup milestones. Enter edits or selects.',
    'c: review, then save. r: review and confirm restoring selected files or all sources.',
    'f/N: choose a source. Enter in the center opens it in the editing window.',
    'g: refresh/cancel review. v: audition the last built output. P: presentation.',
    'Presets fill one editable message; measure numbers are never guessed.',
    'F5 and Apply create no commits. Milestones never switch the workbench branch.',
    'Record commits require an unstaged index. Milestones preserve existing staging.',
    'H: home. q: close.'},' Review help ')end)
end
return M
