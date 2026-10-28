-- Inspection-only command validation against the complete compiled snapshot.
-- Recognize a small literal vocabulary; never execute Scheme or trust a name.
local reader=require('lilyp.music_reader')
local M={}
local function literal(ts,i)
  local t=assert(ts[i],'Missing literal value')
  if t.kind=='string' or t.kind=='number' then return i end
  assert(t.text=='#','Expected a literal number or string')
  i=i+1
  if ts[i] and ts[i].text=='-' then i=i+1 end
  assert(ts[i] and ts[i].kind=='number','Expected a literal number')
  if ts[i+1] and ts[i+1].text=='.' then
    assert(ts[i+2] and ts[i+2].kind=='number','Invalid decimal');i=i+2
  end
  return i
end
local function markup(ts,i)
  local t=assert(ts[i],'Missing markup')
  if t.text=='\\markup' then return markup(ts,i+1) end
  if t.text=='{' then
    assert(t.close,'Unclosed markup')
    local n=i+1
    while n<t.close do n=markup(ts,n)+1 end
    return t.close
  end
  if t.kind=='string' then return i end
  if t.text=='\\bold' or t.text=='\\italic' or t.text=='\\center-column' then return markup(ts,i+1) end
  if t.text=='\\fontsize' then return markup(ts,literal(ts,i+1)+1) end
  if t.text=='\\musicglyph' then assert(ts[i+1] and ts[i+1].kind=='string','Expected glyph name');return i+1 end
  error('Unsupported markup: '..t.text)
end
function M.snapshot(files)
  local streams,definitions={},{}
  for _,raw in pairs(files) do
    local ts=reader.tokens(raw);streams[raw]=ts
    for i,t in ipairs(ts) do
      if t.kind=='word' and t.depth==0 and ts[i+1] and ts[i+1].text=='=' then
        definitions[t.text]=definitions[t.text] or {}
        definitions[t.text][#definitions[t.text]+1]={ts=ts,index=i,first=i+2}
      end
    end
  end
  local options={}
  local function definition(ts,i,name)
    local candidates=definitions[name] or {}
    local local_def
    for _,d in ipairs(candidates) do if d.ts==ts and d.index<i then local_def=d end end
    if local_def then return local_def end
    assert(#candidates<=1,'Ambiguous music definition: \\'..name)
    return candidates[1]
  end
  local function tweak(ts,i)
    assert(ts[i+1] and ts[i+1].text=='font-size','Only literal font-size tweaks are supported')
    return literal(ts,i+2)
  end
  function options.command(ts,i,resolving)
    local cmd=ts[i].text
    if cmd=='\\mark' or cmd=='\\textEndMark' then return markup(ts,i+1) end
    if cmd=='\\tweak' then return tweak(ts,i),true end
    local d=definition(ts,i,cmd:sub(2))
    if not d then return nil end
    local body=d.ts[d.first]
    if body and body.text=='\\tweak' then
      local last=tweak(d.ts,d.first)
      assert(d.ts[last+1] and d.ts[last+1].text=='\\etc','Unsupported tweak helper: '..cmd)
      assert(not d.ts[last+2] or d.ts[last+2].depth==0 and d.ts[last+3] and d.ts[last+3].text=='=',
        'Unsupported tweak helper tail: '..cmd)
      return i,true
    end
    assert(not resolving[d],'Recursive music command: '..cmd)
    resolving[d]=true
    local passage
    if body and body.text=='{' and body.close then passage={open=d.first,close=body.close}
    else
      -- A single key command or argument-free style alias is also common.
      local last=d.first
      if body and body.text=='\\key' then last=last+2
      elseif not body or (body.text~='\\numericTimeSignature' and body.text~='\\defaultTimeSignature') then
        resolving[d]=nil;error('Unsupported music definition: '..cmd)
      end
      assert(not d.ts[last+1] or d.ts[last+1].depth==0 and d.ts[last+2] and d.ts[last+2].text=='=',
        'Unsupported music definition tail: '..cmd)
      local subset={{text='{'}}
      for n=d.first,last do subset[#subset+1]=d.ts[n] end
      subset[#subset+1]={text='}'}
      local events=reader.read_events(subset,{open=1,close=#subset},resolving,options)
      assert(#events==0,'Pitch-bearing music references are unsupported: '..cmd)
      resolving[d]=nil;return i
    end
    local events,_,syntax=reader.read_events(d.ts,passage,resolving,options)
    resolving[d]=nil
    assert(#events==0,'Pitch-bearing music references are unsupported: '..cmd)
    for _,node in ipairs(syntax) do
      local t=d.ts[node.index]
      assert(t.kind~='number' and t.text~='r' and t.text~='s','Rhythmic music references require a separate mapping')
    end
    return i
  end
  return {streams=streams,options=options}
end
return M
