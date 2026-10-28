local M={}
local function characters(text) return vim.fn.split(text,'\\zs') end
local function intraline(before,after)
  local a,b=characters(before:sub(2)),characters(after:sub(2))
  local spans_a,spans_b={},{}
  local function span(chars,start,count,spans)
    if count==0 then return end
    local first=1
    for i=1,start-1 do first=first+#chars[i] end
    local last=first
    for i=start,start+count-1 do last=last+#chars[i] end
    spans[#spans+1]={first,last}
  end
  local function lines(chars)return #chars==0 and '' or table.concat(chars,'\n')..'\n'end
  local hunks=vim.diff(lines(a),lines(b),{result_type='indices',algorithm='minimal'})
  for _,hunk in ipairs(hunks) do
    span(a,hunk[1],hunk[2],spans_a);span(b,hunk[3],hunk[4],spans_b)
  end
  return spans_a,spans_b
end
function M.content(changes,key)
  local content={title='Saved source changes',lines={},locations={},highlights={},key=key,diff=true}
  local function add(line,path,number)
    content.lines[#content.lines+1]=line
    if number then content.locations[#content.lines]={path=path,line=math.max(1,number)} end
  end
  for _,change in ipairs(changes) do
    local path=change.path
    add('--- '..path);add('+++ '..path)
    local before=change.before and change.before.text or ''
    local after=change.after and change.after.text or ''
    local patch=vim.diff(before,after,{result_type='unified',ctxlen=3,algorithm='histogram'})
    local new_line=1
    local removed,added={},{}
    local function highlight()
      for i=1,math.min(#removed,#added) do
        local a,b=intraline(content.lines[removed[i]],content.lines[added[i]])
        content.highlights[removed[i]]=a;content.highlights[added[i]]=b
      end
      removed,added={},{}
    end
    for line in patch:gmatch('[^\n]+') do
      if line:match('^@@') then
        highlight();new_line=tonumber(line:match('%+(%d+)')) or 1;add(line,path,new_line)
      elseif line:sub(1,1)=='-' then
        if #added>0 then highlight() end
        add(line,path,new_line);removed[#removed+1]=#content.lines
      elseif line:sub(1,1)=='+' then
        add(line,path,new_line);added[#added+1]=#content.lines;new_line=new_line+1
      else
        highlight();add(line,path,new_line)
        if line:sub(1,1)==' ' then new_line=new_line+1 end
      end
    end
    highlight()
    if patch=='' then add('File mode changed: '..(change.before and change.before.mode or 'absent')..' → '..(change.after and change.after.mode or 'absent')) end
    add('')
  end
  if #content.lines==0 then content.lines={'No saved source changes.'} end
  return content
end
return M
