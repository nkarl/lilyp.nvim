local M={}
-- Track lexical context so examples, quoted code, and comments are not imported as settings.
local function code_positions(text)
  local positions, state, depth, i = {}, 'code', 0, 1
  while i<=#text do
    local c,pair=text:sub(i,i),text:sub(i,i+1)
    if state=='string' then
      if c=='\\' then i=i+1 elseif c=='"' then state='code' end
    elseif state=='line' then if c=='\n' then state='code' end
    elseif state=='block' then
      if pair=='%{' then depth=depth+1;i=i+1
      elseif pair=='%}' then depth=depth-1;i=i+1;if depth==0 then state='code' end end
    elseif pair=='#\\' then
      i=i+2
      while text:sub(i+1,i+1):match('[%a]') do i=i+1 end
    elseif c=='"' then state='string'
    elseif pair=='%{' then state='block';depth=1;i=i+1
    elseif c=='%' or c==';' then state='line'
    else positions[i]=true end
    i=i+1
  end
  return positions
end

M.code_positions=code_positions

-- A bounded structural reader, not a LilyPond/Scheme evaluator.
local function brace_closings(text,code)
  local stack,closings={},{}
  for i=1,#text do
    if code[i] then
      local c=text:sub(i,i)
      if c=='{' then stack[#stack+1]=i
      elseif c=='}' and #stack>0 then closings[stack[#stack]]=i;stack[#stack]=nil end
    end
  end
  return closings
end
function M.blocks(text,command)
  local code=code_positions(text)
  local closings=brace_closings(text,code)
  local result,cursor={},1
  while true do
    local a,b=text:find('\\'..command..'%s*{',cursor)
    if not a then break end
    if code[a] then
      local closing=assert(closings[b],'Unbalanced '..command..' block')
      result[#result+1]={first=a,open=b,close=closing,body_first=b+1,body_last=closing-1}
    end
    cursor=b+1
  end
  return result
end
function M.mask(text,spans)
  local patches={}
  for _,span in ipairs(spans) do
    patches[#patches+1]={first=span.first,last=span.close,text=text:sub(span.first,span.close):gsub('[^\n]',' ')}
  end
  return M.patch(text,patches)
end
function M.layouts(text)
  local code=code_positions(text)
  local closings=brace_closings(text,code)
  local result,cursor={},1
  while true do
    local a,b,name=text:find('([%a_][%w_%-]*)%s*=%s*\\layout%s*{',cursor)
    if not a then break end
    if code[a] and not text:sub(a-1,a-1):match('[%w_%-]') then
      local closing=assert(closings[b],'Unbalanced layout binding: '..name)
      result[name]=result[name] or {}
      result[name][#result[name]+1]={binding=name,first=a,open=b,close=closing,
        body_first=b+1,body_last=closing-1}
    end
    cursor=b+1
  end
  return result
end
function M.layout(text,name)
  local matches=M.layouts(text)[name]
  assert(matches and #matches==1,'Expected one explicit layout binding: '..name)
  return matches[1]
end
function M.patch(text,patches)
  table.sort(patches,function(a,b)return a.first>b.first end)
  local boundary=#text+2
  for _,p in ipairs(patches) do
    assert(p.first>=1 and p.first<=#text+1 and p.last>=p.first-1 and p.last<boundary,'Overlapping or invalid source edits')
    assert(p.last<=#text and type(p.text)=='string','Invalid source replacement')
    text=text:sub(1,p.first-1)..p.text..text:sub(p.last+1);boundary=p.first
  end
  return text
end
return M
