-- Explicit musical editing. This module does not participate in presentation Apply.
local M={}
local reader=require('lilyp.music_reader')
local pitch,midi,nearest,marks=reader.pitch,reader.midi,reader.nearest,reader.marks
local tokens,region,read_events=reader.tokens,reader.region,reader.read_events

local sharp={{'c',0,0},{'cis',0,1},{'d',1,0},{'dis',1,1},{'e',2,0},{'f',3,0},{'fis',3,1},{'g',4,0},{'gis',4,1},{'a',5,0},{'ais',5,1},{'b',6,0}}
local flat={{'c',0,0},{'des',1,-1},{'d',1,0},{'ees',2,-1},{'e',2,0},{'f',3,0},{'ges',4,-1},{'g',4,0},{'aes',5,-1},{'a',5,0},{'bes',6,-1},{'b',6,0}}

--- Pure transformation. first/last are inclusive, one-based byte offsets.
--- Returns transformed source and metadata; errors never mutate source.
function M.transform(text,first,last,destination)
  assert(type(text)=='string' and type(first)=='number' and type(last)=='number' and first%1==0 and last%1==0 and first>=1 and last>=first and last<=#text,'Invalid selection byte range')
  local target=assert(type(destination)=='string' and pitch(destination),'Destination must be an absolute Dutch LilyPond pitch, for example fis\'')
  local ts=tokens(text)
  for i,t in ipairs(ts) do
    if t.text=='\\language' then assert(ts[i+1] and ts[i+1].text=='"nederlands"','Only Dutch/default LilyPond pitch names are supported') end
    if t.text=='\\include' then
      local arg=ts[i+1] and ts[i+1].text or ''
      assert(not arg:match('%.ly"$'),'Included .ly files may change pitch language; only explicit local/default Dutch music is supported')
    end
  end
  local trimmed_first=assert(text:find('%S',first),'Empty selection')
  local trimmed_last=last
  while trimmed_last>=first and text:sub(trimmed_last,trimmed_last):match('%s') do trimmed_last=trimmed_last-1 end
  local r=region(ts,trimmed_first,trimmed_last)
  local events,anchor=read_events(ts,r)
  local selected={}
  for _,e in ipairs(events) do
    if e.token then
      local t=e.token
      if t.first<=last and t.last>=first then
        assert(t.first>=first and t.last<=last,'Selection cuts through a pitch token')
        selected[#selected+1]=e;e.selected=true
      end
    end
  end
  assert(#selected>0,'Selection contains no literal pitches')
  local delta=midi(target.step+7*target.octave,target.alter)-selected[1].midi
  if delta==0 then return text,{semitones=0,notes=#selected,patches={}} end
  -- Changing only one side of a tie would create invalid or misleading notation.
  for i=r.open+1,r.close-1 do
    if ts[i].text=='~' then
      local left,right
      for _,e in ipairs(events) do
        if e.token then
          if e.token.last<ts[i].first then left=e.group
          elseif not right then right=e.group end
        end
      end
      local changed,unchanged=false,false
      for _,e in ipairs(events) do
        if e.token and (e.group==left or e.group==right) then
          if e.selected then changed=true else unchanged=true end
        end
      end
      assert(not (changed and unchanged),'Selection must include both complete events connected by a tie')
    end
  end
  local previous=anchor and anchor.step+7*anchor.octave or 0
  local chord_first,patches=nil,{}
  for _,e in ipairs(events) do
    if e.chord_end then previous=assert(chord_first);chord_first=nil
    else
      local p,d=e.pitch,e.diatonic
      if e.selected then
        if e==selected[1] then p=target;d=target.step+7*target.octave
        else
          local value=e.midi+delta
          local spelling=(target.alter<0 and flat or sharp)[value%12+1]
          p={name=spelling[1],step=spelling[2],alter=spelling[3]}
          d=7*math.floor((value-48)/12)+p.step
        end
      end
      local base=r.relative and nearest(p.step,previous) or p.step
      local replacement=p.name..marks((d-base)/7)
      if replacement~=e.token.text then patches[#patches+1]={first=e.token.first,last=e.token.last,text=replacement} end
      previous=d
      if e.chord_open and not chord_first then chord_first=d end
    end
  end
  return require('lilyp.source_regions').patch(text,patches),{semitones=delta,notes=#selected,patches=patches}
end

--- Capture a selection before a picker changes the current buffer or Visual marks.
function M.capture(opts)
  opts=opts or {}
  local buf=opts.buf or vim.api.nvim_get_current_buf()
  if buf==0 then buf=vim.api.nvim_get_current_buf() end
  assert(vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modifiable and not vim.bo[buf].readonly,'Buffer is not editable')
  local lines=vim.api.nvim_buf_get_lines(buf,0,-1,false)
  local start,finish=opts.start,opts.finish
  assert((start==nil)==(finish==nil),'Supply both start and finish, or neither')
  if not start then
    assert(buf==vim.api.nvim_get_current_buf(),'Visual selection requires the current buffer')
    local mode=vim.fn.mode()
    local active=mode=='v' or mode=='V' or mode=='\22'
    local kind=active and mode or vim.fn.visualmode()
    assert(kind=='v' or kind=='V','Use a characterwise or linewise Visual selection')
    local a=active and vim.fn.getpos('v') or vim.fn.getpos("'<")
    local b=active and vim.fn.getpos('.') or vim.fn.getpos("'>")
    assert(a[2]>0 and b[2]>0,'No Visual selection')
    local segments=vim.fn.getregionpos(a,b,{type=kind,eol=true})
    assert(#segments>0,'Empty Visual selection')
    a,b=segments[1][1],segments[#segments][2]
    assert(a[4]==0 and b[4]==0,'Virtual-column selections are unsupported')
    start={a[2]-1,a[3]-1};finish={b[2]-1,b[3]-1}
    if kind=='V' then start[2]=0;finish[2]=#lines[b[2]]
    else
      local tail=lines[b[2]]:sub(b[3]);local char=vim.fn.strcharpart(tail,0,1)
      finish[2]=math.min(#lines[b[2]],finish[2]+#char)
    end
  end
  for _,pos in ipairs({start,finish}) do
    assert(type(pos)=='table' and type(pos[1])=='number' and type(pos[2])=='number' and pos[1]%1==0 and pos[2]%1==0 and pos[1]>=0 and pos[1]<#lines and pos[2]>=0 and pos[2]<=#lines[pos[1]+1],'Invalid buffer selection')
  end
  assert(start[1]<finish[1] or (start[1]==finish[1] and start[2]<finish[2]),'Empty or reversed selection')
  return {buf=buf,start=vim.deepcopy(start),finish=vim.deepcopy(finish),changedtick=vim.api.nvim_buf_get_changedtick(buf)}
end

function M.valid_destination(value)
  return type(value)=='string' and pitch(value)~=nil
end

--- Transpose a buffer selection. Explicit range uses zero-based, end-exclusive
--- {row, byte_column} start/finish positions. Otherwise use active/last Visual selection.
function M.selection(destination,opts)
  opts=opts or {}
  local captured=M.capture(opts)
  local buf,start,finish=captured.buf,captured.start,captured.finish
  assert(not opts.changedtick or opts.changedtick==captured.changedtick,'Source changed while choosing a destination; select the passage again')
  local lines=vim.api.nvim_buf_get_lines(buf,0,-1,false)
  local function offset(pos)
    local n=pos[2]+1
    for i=1,pos[1] do n=n+#lines[i]+1 end
    return n
  end
  local text=table.concat(lines,'\n')
  local updated,result=M.transform(text,offset(start),offset(finish)-1,destination)
  if updated~=text then
    -- One API edit gives one undo operation, including relative boundary repair.
    local first,last=1,#text
    while first<=#text and text:sub(first,first)==updated:sub(first,first) do first=first+1 end
    local ending=#updated
    while last>=first and ending>=first and text:sub(last,last)==updated:sub(ending,ending) do last=last-1;ending=ending-1 end
    local function position(byte)
      local row=0
      for _,line in ipairs(lines) do
        if byte<=#line then return row,byte end
        byte=byte-#line-1;row=row+1
      end
      return #lines-1,#lines[#lines]
    end
    local sr,sc=position(first-1);local er,ec=position(last)
    vim.api.nvim_buf_set_text(buf,sr,sc,er,ec,vim.split(updated:sub(first,ending),'\n',{plain=true}))
  end
  return result
end
return M
