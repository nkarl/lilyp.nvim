-- Bounded, read-only LilyPond pitch syntax shared by inspection and transposition.
local M={}
local letters={c=0,d=1,e=2,f=3,g=4,a=5,b=6}
local naturals={0,2,4,5,7,9,11}
local alterations={['']=0,is=1,isis=2,es=-1,eses=-2}

local function pitch(word)
  local letter,acc,marks=word:match('^([a-g])([a-z]*)([,\']*)$')
  if not letter or alterations[acc]==nil then return nil end
  local octave=0
  for mark in marks:gmatch('.') do octave=octave+(mark=="'" and 1 or -1) end
  return {step=letters[letter],alter=alterations[acc],octave=octave,name=letter..acc}
end
local function midi(diatonic,alter)
  return 48+12*math.floor(diatonic/7)+naturals[diatonic%7+1]+alter
end
local function nearest(step,previous)
  return previous+((step-previous+3)%7)-3
end
local function marks(count)
  return count>=0 and string.rep("'",count) or string.rep(',',-count)
end

-- Keep byte offsets; never tokenize words inside comments or strings as music.
local function tokens(text)
  local out,i={},1
  while i<=#text do
    local start=i
    local c,pair=text:sub(i,i),text:sub(i,i+1)
    if c:match('%s') then i=i+1
    elseif pair=='%{' then
      local depth=1;i=i+2
      while i<=#text and depth>0 do
        local p=text:sub(i,i+1)
        if p=='%{' then depth=depth+1;i=i+2
        elseif p=='%}' then depth=depth-1;i=i+2 else i=i+1 end
      end
      assert(depth==0,'Unclosed block comment')
    elseif c=='%' then i=(text:find('\n',i,true) or (#text+1))
    else
      local kind='symbol'
      if c=='"' then
        kind='string';i=i+1
        while i<=#text and text:sub(i,i)~='"' do
          i=i+(text:sub(i,i)=='\\' and 2 or 1)
        end
        assert(i<=#text,'Unclosed string');i=i+1
      elseif c=='\\' then
        kind='command';i=i+1
        local word=text:match('^[%a][%w_%-]*',i)
        i=i+(word and #word or 1)
      elseif c:match('[%a_]') then
        kind='word'
        local word=text:match('^[%a_][%w_%-]*',i);i=i+#word
        -- Durations are separate from pitch tokens, including inherited durations.
        local head=word:match('^[a-z]+')
        if head and (pitch(head) or head=='r' or head=='s') and word:sub(#head+1,#head+1):match('[%d%-]') then
          i=start+#head
        end
        while text:sub(i,i)=="'" or text:sub(i,i)==',' do i=i+1 end
      elseif c:match('%d') then
        kind='number';local number=text:match('^%d+',i);i=i+#number
      elseif pair=='<<' or pair=='>>' then i=i+2
      else i=i+1 end
      out[#out+1]={text=text:sub(start,i-1),kind=kind,first=start,last=i-1}
    end
  end
  local stack={}
  for n,t in ipairs(out) do
    t.depth=#stack
    if t.text=='{' then stack[#stack+1]=n
    elseif t.text=='}' then
      local open=table.remove(stack)
      if open then out[open].close=n;t.open=open end
    end
  end
  return out
end

-- Commands whose arguments cannot contain music. Unknown commands fail closed.
local zero={major=true,minor=true,
  p=true,pp=true,ppp=true,pppp=true,f=true,ff=true,fff=true,ffff=true,mf=true,mp=true,
  sf=true,sfz=true,fp=true,cresc=true,dim=true,fermata=true,staccato=true,tenuto=true,
  accent=true,marcato=true,["break"]=true,noBreak=true,breathe=true,
  voiceOne=true,voiceTwo=true,oneVoice=true,stemUp=true,stemDown=true,stemNeutral=true,
  autoBeamOn=true,autoBeamOff=true,numericTimeSignature=true,defaultTimeSignature=true}
local one={clef=true,bar=true,partial=true,barNumberCheck=true}
local function region(ts,first,last,inspection)
  local candidate
  for i,t in ipairs(ts) do
    if t.text=='{' and t.close and ts[t.close].last>=last then
      local before=ts[i-1]
      local relative=ts[i-2] and ts[i-2].text=='\\relative'
      local fixed=inspection and ts[i-2] and ts[i-2].text=='\\fixed'
      local absolute=before and before.text=='\\absolute'
      local assigned=before and before.text=='='
      if relative or fixed or absolute or assigned then
        local beginning=(relative or fixed) and i-2 or (absolute and i-1 or i)
        if ts[beginning-1] and ts[beginning-1].text=='=' and ts[beginning-2] then beginning=beginning-2
        elseif assigned and ts[i-2] then beginning=i-2 end
        -- Outermost supported music context supplies relative pitch state.
        if not candidate and ts[beginning].first<=first then candidate={open=i,close=t.close,relative=relative,fixed=fixed,anchor=(relative or fixed) and before or nil} end
      end
    end
  end
  assert(candidate,'Select music inside a literal music variable, \\relative pitch { ... }, or \\absolute { ... }')
  return candidate
end

local function read_events(ts,r,resolving,inspection)
  resolving=resolving or {}
  local events,syntax={},{}
  local anchor=(r.relative or r.fixed) and assert(pitch(r.anchor.text),'Music requires an explicit supported anchor pitch')
  assert(not r.fixed or anchor.step==0 and anchor.alter==0,'Fixed music requires a C octave anchor')
  local previous=anchor and anchor.step+7*anchor.octave or 0
  local chord_first,chord_open
  local group=0
  local depth=0
  local i=r.open+1
  while i<r.close do
    local beginning=i
    local referenced_syntax,decoration
    local t=ts[i];local s=t.text
    local p=t.kind=='word' and pitch(s)
    if p then
      if not chord_open then group=group+1 end
      local d=r.relative and nearest(p.step,previous)+7*p.octave or p.step+7*(p.octave+(r.fixed and anchor.octave or 0))
      events[#events+1]={token=t,pitch=p,diatonic=d,midi=midi(d,p.alter),chord_open=chord_open,group=group}
      previous=d
      if chord_open and not chord_first then chord_first=d end
    elseif s=='>' and ts[i-1] and ts[i-1].text=='-' then -- short accent articulation
    elseif s=='<' then
      assert(not chord_open,'Nested chords are unsupported');chord_open=true;chord_first=nil;group=group+1
    elseif s=='>' then
      assert(chord_open and chord_first,'Empty or unmatched chord');previous=chord_first;chord_open=nil;chord_first=nil
      events[#events+1]={chord_end=true}
    elseif s=='{' then depth=depth+1
    elseif s=='}' then depth=depth-1;assert(depth>=0,'Unbalanced music expression')
    elseif t.kind=='command' then
      local cmd=s:sub(2)
      local handled
      if inspection then handled,decoration=inspection.command(ts,i,resolving) end
      if handled then i=handled
      elseif inspection and (cmd=='alternative' or cmd=='grace' or cmd=='slashedGrace' or cmd=='acciaccatura' or cmd=='appoggiatura') then
        if cmd=='alternative' then assert(ts[i+1] and ts[i+1].text=='{','Alternative requires a literal body') end
      elseif zero[cmd] then -- no arguments
      elseif one[cmd] then
        local arg=ts[i+1];assert(arg and (arg.kind=='number' or arg.kind=='string' or arg.kind=='word'),'Missing '..s..' argument');i=i+1
        if cmd=='partial' then while ts[i+1] and ts[i+1].text=='.' do i=i+1 end end
      elseif cmd=='key' then
        assert(ts[i+1] and pitch(ts[i+1].text) and ts[i+2] and (ts[i+2].text=='\\major' or ts[i+2].text=='\\minor'),'Unsupported key signature');i=i+2
      elseif cmd=='time' or cmd=='tuplet' or cmd=='times' then
        assert(ts[i+1] and ts[i+1].kind=='number' and ts[i+2] and ts[i+2].text=='/' and ts[i+3] and ts[i+3].kind=='number','Unsupported '..s..' arguments');i=i+3
      elseif cmd=='repeat' then
        assert(ts[i+1] and (ts[i+1].text=='volta' or ts[i+1].text=='unfold') and ts[i+2] and ts[i+2].kind=='number','Unsupported repeat');i=i+2
      elseif cmd=='tempo' then
        local label=ts[i+1] and ts[i+1].kind=='string'
        if label then i=i+1 end
        if ts[i+1] and ts[i+1].kind=='number' then
          i=i+1
          while ts[i+1] and ts[i+1].text=='.' do i=i+1 end
          assert(ts[i+1] and ts[i+1].text=='=' and ts[i+2] and ts[i+2].kind=='number','Unsupported tempo');i=i+2
        else assert(label,'Unsupported tempo') end
      elseif cmd=='(' or cmd==')' or cmd=='<' or cmd=='>' or cmd=='!' then -- slurs/hairpins
      else
        -- Local pitch-free globals (key/time/tempo) are common in generated music.
        -- Never assume an arbitrary variable named "global" is pitch-free.
        local definition
        for n,token in ipairs(ts) do
          if token.kind=='word' and token.text==cmd and token.depth==0 and ts[n+1] and ts[n+1].text=='=' then
            assert(not definition,'Ambiguous music definition: '..s)
            assert(n<i and ts[n+2] and ts[n+2].text=='{' and ts[n+2].close,'Unsupported music definition: '..s)
            definition={open=n+2,close=ts[n+2].close}
          end
        end
        assert(definition and not resolving[cmd],'Unsupported or recursive music command: '..s)
        resolving[cmd]=true
        local referenced,_,notation=read_events(ts,definition,resolving,inspection)
        referenced_syntax=notation
        resolving[cmd]=nil
        assert(#referenced==0,'Pitch-bearing music references are unsupported: '..s)
      end
    elseif t.kind=='number' or (t.kind=='word' and (s=='r' or s=='s')) then
      -- Durations, rests, and skips do not change pitch context.
    elseif t.kind=='string' then
      assert(ts[i-1] and (ts[i-1].text=='^' or ts[i-1].text=='_' or ts[i-1].text=='-'),'Unexpected string in music')
    elseif s:match('^[|%.~%(%)[%]!?%^_+*/:%-]$') then -- ordinary event punctuation
    else error('Unsupported music token: '..s) end
    syntax[#syntax+1]={index=beginning,last=i,reference=referenced_syntax,decoration=decoration}
    i=i+1
  end
  assert(not chord_open and depth==0,'Unbalanced music expression')
  return events,anchor,syntax
end

-- Internal syntax API; callers must enforce their own supported-context boundary.
M.pitch,M.midi,M.nearest,M.marks=pitch,midi,nearest,marks
M.tokens,M.region,M.read_events=tokens,region,read_events
return M
