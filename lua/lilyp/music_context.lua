-- Conservative compiled-source interpretation. Never infers an edit target from
-- a neighboring token or claims a sounding/concert pitch.
local reader=require('lilyp.music_reader')
local inspection=require('lilyp.inspection')
local M={}
local unavailable=inspection.unsupported
local function clean_error(message)
  local value=tostring(message)
  while value:match('^.-:%d+: ') do value=value:gsub('^.-:%d+: ','') end
  return value
end
local function root_region(ts,r)
  local prefix=(r.relative or r.fixed) and r.open-2 or (ts[r.open-1] and ts[r.open-1].text=='\\absolute' and r.open-1 or r.open)
  local assigned=ts[prefix-1] and ts[prefix-1].text=='=' and ts[prefix-2] and ts[prefix-2].depth==0
  assert(ts[r.open].depth==0 and (assigned or prefix==1 or (ts[prefix-1] and ts[prefix-1].kind=='string')),
    'Pitch context must be a top-level literal music definition or explicit pitch block')
  return assigned and ts[prefix-2].text or nil
end

-- Restrict source definitions reinterpreted by wrappers across files. Language
-- and Scheme ambiguity withhold interpretation for the complete snapshot.
function M.guard(files)
  local streams,definitions,bodies,restricted={},{},{},{}
  for path,raw in pairs(files) do
    if path:match('%.i?ly$') then
      local ok,ts=pcall(reader.tokens,raw)
      if not ok then return 'Source syntax could not be analyzed: '..clean_error(ts) end
      streams[#streams+1]=ts
      for i,t in ipairs(ts) do
        if t.kind=='word' and t.depth==0 and ts[i+1] and ts[i+1].text=='=' then
          local first=ts[i+2]
          local open=first and (first.text=='{' and i+2 or (first.text=='\\relative' or first.text=='\\fixed') and i+4 or first.text=='\\absolute' and i+3)
          if open and ts[open] and ts[open].close then
            local accepted,events=pcall(reader.read_events,ts,{open=open,close=ts[open].close})
            local free=accepted and #events==0
            definitions[t.text]=definitions[t.text]==nil and free or false
            bodies[t.text]=bodies[t.text] or {};bodies[t.text][#bodies[t.text]+1]={tokens=ts,open=open,close=ts[open].close}
          end
        end
      end
    end
  end
  local function restrict(name,reason)
    if restricted[name] then return end
    restricted[name]=reason
    for _,body in ipairs(bodies[name] or {}) do
      for j=body.open+1,body.close-1 do
        local ref=body.tokens[j].text:match('^\\([%a][%w_%-]*)$')
        if ref and definitions[ref]==false then restrict(ref,reason) end
      end
    end
  end
  for _,ts in ipairs(streams) do
      for i,t in ipairs(ts) do
        local s=t.text
        if s=='\\language' and (not ts[i+1] or ts[i+1].text~='"nederlands"') then
          return 'Only default/Dutch pitch names are supported'
        elseif s=='\\include' and ts[i+1] and ts[i+1].text:match('%.ly"$') then
          return 'Included .ly files may change pitch interpretation'
        elseif s=='\\modalTranspose' then
          return 'Context-changing pitch wrappers require a separate mapping: '..s
        elseif s=='define-music-function' or s=='define-scheme-function' then
          return 'Scheme music functions require a separate mapping'
        end
        local arguments=({['\\relative']=1,['\\absolute']=0,['\\fixed']=1,['\\transpose']=2})[s]
        if arguments then
          local start=i+arguments+1
          if s=='\\relative' and ts[i+1] and ts[i+1].text=='{' then start=i+1 end
          local body=ts[start]
          if body then
            for j=start,(body.close or start) do
              local ref=ts[j].text:match('^\\([%a][%w_%-]*)$')
              if ref and definitions[ref]==false then
                restrict(ref,'Pitch wrappers around music references require a separate mapping: '..s..' \\'..ref)
              end
            end
          end
        end
      end
  end
  local accepted,snapshot=pcall(require('lilyp.music_commands').snapshot,files)
  if not accepted then return 'Source syntax could not be analyzed: '..clean_error(snapshot) end
  return {restricted=restricted,snapshot=snapshot}
end

local function annotate(ts,events,syntax)
  local by_first={}
  for _,event in ipairs(events) do if event.token then by_first[event.token.first]=event end end
  local denominator,dots,scale=4,0,nil
  local cursor=1
  local function duration()
    local explicit=false
    local node=syntax[cursor]
    if node and ts[node.index].kind=='number' then
      denominator=tonumber(ts[node.index].text);dots=0;scale=nil;explicit=true;cursor=cursor+1
      assert(denominator>=1 and denominator<=1024 and math.log(denominator)/math.log(2)%1<1e-9,'Unsupported note duration')
      while syntax[cursor] and ts[syntax[cursor].index].text=='.' do dots=dots+1;cursor=cursor+1 end
    end
    if syntax[cursor] and ts[syntax[cursor].index].text=='*' then
      cursor=cursor+1
      local numerator=syntax[cursor] and ts[syntax[cursor].index]
      assert(numerator and numerator.kind=='number','Expected duration multiplier');cursor=cursor+1
      scale=numerator.text
      if syntax[cursor] and ts[syntax[cursor].index].text=='/' then
        cursor=cursor+1
        local divisor=syntax[cursor] and ts[syntax[cursor].index]
        assert(divisor and divisor.kind=='number' and tonumber(divisor.text)>0,'Invalid duration divisor')
        scale=scale..'/'..divisor.text;cursor=cursor+1
      end
    end
    return {denominator=denominator,dots=dots,scale=scale,
      notation=tostring(denominator)..string.rep('.',dots)..(scale and '*'..scale or ''),inherited=not explicit}
  end
  local function pitch_free(nodes)
    for _,node in ipairs(nodes) do
      local t=ts[node.index]
      assert(t.text~='r' and t.text~='s' and t.kind~='number','Rhythmic music references require a separate mapping')
      if node.reference then pitch_free(node.reference) end
    end
  end
  local grace=false
  local function set(event,d,tuplets,member,count)
    event.duration=vim.deepcopy(d);event.tuplets=vim.deepcopy(tuplets)
    event.member=member;event.members=count;event.grace=grace
  end
  local sequence
  local function item(tuplets)
    local node=syntax[cursor];local t=ts[node.index];local s=t.text
    cursor=cursor+1
    if s=='{' then sequence(tuplets,true)
    elseif s=='\\grace' or s=='\\slashedGrace' or s=='\\acciaccatura' or s=='\\appoggiatura' then
      local saved_grace=grace
      grace=true
      local next_node=assert(syntax[cursor],'Missing grace music')
      local next_token=ts[next_node.index]
      assert(next_token.text=='{' or next_token.text=='<' or reader.pitch(next_token.text)
        or next_token.text=='r' or next_token.text=='s','Grace requires literal music')
      item(tuplets)
      grace=saved_grace
    elseif s=='\\tuplet' or s=='\\times' then
      local ratio=ts[node.index+1].text..'/'..ts[node.index+3].text
      assert(tonumber(ts[node.index+1].text)>0 and tonumber(ts[node.index+3].text)>0,'Invalid tuplet ratio')
      assert(syntax[cursor] and ts[syntax[cursor].index].text=='{','Tuplet requires a literal braced body')
      cursor=cursor+1;local child=vim.deepcopy(tuplets)
      child[#child+1]={command=s:sub(2),ratio=ratio};sequence(child,true)
    elseif s=='<' then
      local members={}
      while syntax[cursor] and ts[syntax[cursor].index].text~='>' do
        local pitch_token=ts[syntax[cursor].index]
        local event=by_first[pitch_token.first]
        if event then members[#members+1]=event
        else assert(pitch_token.kind=='command','Chord contains an unsupported expression') end
        cursor=cursor+1
      end
      assert(syntax[cursor] and #members>0,'Unclosed chord');cursor=cursor+1
      local d=duration()
      for n,event in ipairs(members) do set(event,d,tuplets,n,#members) end
    elseif by_first[t.first] then set(by_first[t.first],duration(),tuplets,1,1)
    elseif s=='r' or s=='s' then
      local event={token=t,event_type=s=='r' and 'rest' or 'skip'}
      by_first[t.first]=event;set(event,duration(),tuplets,1,1)
    elseif node.reference then pitch_free(node.reference)
    elseif t.kind=='number' or s=='*' or s=='/' or s==':' then error('Unsupported rhythmic expression: '..s)
    end
  end
  sequence=function(tuplets,nested)
    while syntax[cursor] do
      if ts[syntax[cursor].index].text=='}' then
        assert(nested,'Unmatched music brace');cursor=cursor+1;return
      end
      item(tuplets)
    end
    assert(not nested,'Unclosed music brace')
  end
  sequence({},false)
  for n,node in ipairs(syntax) do
    if node.decoration then
      local next_node=syntax[n+1]
      assert(next_node and by_first[ts[next_node.index].first],'Tweak requires a literal note')
      by_first[ts[node.index].first]=by_first[ts[next_node.index].first]
    end
  end
  return by_first
end

function M.analyzer(raw,guard)
  if guard==nil then guard=M.guard({['/score.ly']=raw}) end
  local ok,ts=pcall(reader.tokens,raw)
  local snapshot=type(guard)=='table' and guard.snapshot
  if snapshot and snapshot.streams[raw] then ts=snapshot.streams[raw] end
  local cache={}
  return function(byte)
    if type(guard)=='string' then return unavailable(guard) end
    if not ok then return unavailable('Source syntax could not be analyzed') end
    local success,result=pcall(function()
      local r=reader.region(ts,byte,byte,true)
      local name=root_region(ts,r)
      assert(not (guard and guard.restricted[name]),guard and guard.restricted[name])
      if not cache[r.open] then
        local accepted,value=pcall(function()
          local events,_,syntax=reader.read_events(ts,r,nil,snapshot and snapshot.options)
          return annotate(ts,events,syntax)
        end)
        cache[r.open]={ok=accepted,value=accepted and value or clean_error(value)}
      end
      local parsed=cache[r.open]
      assert(parsed.ok,parsed.value)
      local event=assert(parsed.value[byte],'The compiler origin is not the start of a supported pitch token')
      if event.event_type then
        return inspection.supported(event.event_type,{
          first=event.token.first,last=event.token.last,duration=event.duration,tuplets=event.tuplets,grace=event.grace})
      end
      local p=event.pitch
      local names={'C','D','E','F','G','A','B'}
      local accidental=({[-2]='𝄫',[-1]='♭',[0]='',[1]='♯',[2]='𝄪'})[p.alter]
      return inspection.supported('note',{first=event.token.first,last=event.token.last,
        written_pitch=event.token.text,absolute_pitch=p.name..reader.marks(math.floor(event.diatonic/7)),
        pitch=names[p.step+1]..accidental..tostring(math.floor(event.diatonic/7)+3),midi=event.midi,
        mode=r.relative and 'relative' or r.fixed and 'fixed' or 'absolute',anchor=(r.relative or r.fixed) and r.anchor.text or nil,grace=event.grace,
        duration=event.duration,tuplets=event.tuplets,chord_member=event.member,chord_size=event.members})
    end)
    return success and result or unavailable(clean_error(result))
  end
end
return M
