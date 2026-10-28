-- Read-only symbol descriptions at exact compiled source positions. These are
-- source notation, never inferred note bindings, sounding chords, or edit IDs.
local reader=require('lilyp.music_reader')
local M={}
local dynamics={p='Piano',pp='Pianissimo',ppp='Pianississimo',pppp='Very soft',f='Forte',ff='Fortissimo',fff='Fortississimo',ffff='Very loud',mp='Mezzo piano',mf='Mezzo forte',sf='Sforzando',sfz='Sforzato',fp='Forte piano',cresc='Crescendo',dim='Diminuendo'}
local articulations={staccato='Staccato',tenuto='Tenuto',accent='Accent',marcato='Marcato',fermata='Fermata',breathe='Breath mark'}
local punctuation={['[']={'beam','Beam start'},[']']={'beam','Beam end'},['(']={'slur','Slur start'},[')']={'slur','Slur end'},['~']={'tie','Tie'},['\\(']={'slur','Phrasing slur start'},['\\)']={'slur','Phrasing slur end'},['\\<']={'dynamic','Crescendo hairpin'},['\\>']={'dynamic','Diminuendo hairpin'},['\\!']={'dynamic','Hairpin end'}}
local short={['.']='Staccato',['-']='Tenuto',['>']='Accent',['^']='Marcato',['!']='Staccatissimo',['+']='Stopped',['_']='Portato'}
local inspection=require('lilyp.inspection')
local supported=inspection.supported
local function bounded(value)return vim.fn.strcharpart(tostring(value),0,240)end
local function unquote(s)
  return (s:sub(2,-2):gsub('\\([\\"])','%1'))
end
local function pitch_name(s)
  local p=reader.pitch(s)
  if not p then return nil end
  return ({'C','D','E','F','G','A','B'})[p.step+1]..({[-2]='𝄫',[-1]='♭',[0]='',[1]='♯',[2]='𝄪'})[p.alter]
end
-- Markup is displayed as bounded source, not evaluated or converted into HTML.
local function expression_end(ts,i)
  local t=ts[i];if not t then return nil end
  if t.text=='{' then return t.close end
  if t.kind=='string' or t.kind=='number' or t.kind=='word' then return i end
  local arity=({['\\markup']=1,['\\bold']=1,['\\italic']=1,['\\center-column']=1,['\\musicglyph']=1,['\\fontsize']=2,['\\with-color']=2,['\\hspace']=1})[t.text]
  if arity then
    local last=i
    for _=1,arity do last=expression_end(ts,last+1);if not last then return nil end end
    return last
  end
  if t.text=='#' then
    local n=i+1
    if ts[n] and ts[n].text=='-' then n=n+1 end
    if ts[n] and (ts[n].kind=='number' or ts[n].kind=='word' or ts[n].kind=='string') then
      if ts[n+1] and ts[n+1].text=='.' and ts[n+2] and ts[n+2].kind=='number' then n=n+2 end
      return n
    end
  end
  if t.text=='\\default' then return i end
end
function M.analyzer(raw,guard)
  local ok,ts=pcall(reader.tokens,raw)
  if not ok then return function()return inspection.unsupported() end end
  local mapped,blocks={},{}
  local pitch_language_ok=type(guard)~='string' or not (guard:find('Dutch',1,true) or guard:find('Included .ly',1,true))
  local function put(index,value)if ts[index] then mapped[ts[index].first]=value end end
  local function span(a,b)return raw:sub(ts[a].first,ts[b].last)end
  -- Explicit modes supply lexical meaning even when pitch interpretation is
  -- unsupported. Nested markup/property expressions are excluded below.
  for i,t in ipairs(ts) do
    if (t.text=='\\lyricmode' or t.text=='\\chordmode' or t.text=='\\lyrics') and ts[i+1] and ts[i+1].close then
      blocks[#blocks+1]={mode=t.text=='\\chordmode' and 'chord' or 'lyric',open=i+1,close=ts[i+1].close,
        definition=ts[i-1] and ts[i-1].text=='=' and ts[i-2] and ts[i-2].kind=='word' and ts[i-2].text or nil}
    end
  end
  local definitions={}
  local streams=type(guard)=='table' and guard.snapshot and guard.snapshot.streams or {[raw]=ts}
  for _,stream in pairs(streams) do
    for n,t in ipairs(stream) do
      if t.depth==0 and t.kind=='word' and stream[n+1] and stream[n+1].text=='=' then
        local value
        local p,m=stream[n+3],stream[n+4]
        if pitch_language_ok and stream[n+2] and stream[n+2].text=='\\key' and p and m and pitch_name(p.text) and (m.text=='\\major' or m.text=='\\minor') then
          value=supported('key',{form='alias',key=pitch_name(p.text)..' '..m.text:sub(2),alias='\\'..t.text})
        end
        definitions[t.text]=definitions[t.text] or {}
        definitions[t.text][#definitions[t.text]+1]={stream=stream,index=n,value=value}
      end
    end
  end
  local function command(i)
    local t=ts[i];local s=t.text;local name=s:sub(2);local a,b,c=ts[i+1],ts[i+2],ts[i+3]
    if definitions[name] then return nil end
    if dynamics[name] then return supported('dynamic',{name='Dynamic marking',notation=s,meaning=dynamics[name]}),i end
    if articulations[name] then return supported('articulation',{name=articulations[name],notation=s}),i end
    if punctuation[s] then return supported(punctuation[s][1],{name=punctuation[s][2],notation=s}),i end
    if s=='\\key' and a and b and pitch_name(a.text) and (b.text=='\\major' or b.text=='\\minor') then
      local detail={form='literal',written=a.text..' '..b.text}
      if pitch_language_ok then detail.key=pitch_name(a.text)..' '..b.text:sub(2) end
      return supported('key',detail),i+2
    elseif (s=='\\time' or s=='\\tuplet' or s=='\\times') and a and b and c and a.kind=='number' and b.text=='/' and c.kind=='number' then
      local ratio=a.text..'/'..c.text
      return supported(s=='\\time' and 'meter' or 'tuplet',{[s=='\\time' and 'meter' or 'ratio']=ratio,command=s}),i+3
    elseif s=='\\tempo' then
      local n=i+1;local detail={}
      if ts[n] and ts[n].kind=='string' then detail.text=bounded(unquote(ts[n].text));n=n+1 end
      if ts[n] and ts[n].kind=='number' then
        local first=n;n=n+1
        while ts[n] and ts[n].text=='.' do n=n+1 end
        if not (ts[n] and ts[n].text=='=' and ts[n+1] and ts[n+1].kind=='number') then return nil end
        detail.beat_unit=bounded(span(first,n-1));detail.bpm=ts[n+1].text;n=n+2
      end
      if next(detail) then return supported('tempo',detail),n-1 end
    elseif s=='\\repeat' and a and b and (a.text=='volta' or a.text=='unfold' or a.text=='percent' or a.text=='tremolo') and b.kind=='number' then
      return supported('repeat',{repeat_type=a.text,count=tonumber(b.text)}),i+2
    elseif s=='\\alternative' then return supported('alternative',{}),i
    elseif s=='\\grace' or s=='\\slashedGrace' or s=='\\acciaccatura' or s=='\\appoggiatura' then
      return supported('grace',{command=s}),i
    elseif s=='\\relative' or s=='\\fixed' or s=='\\absolute' then
      local detail={mode=name}
      if a and reader.pitch(a.text) then detail.anchor=a.text end
      return supported('pitch_context',detail),i
    elseif s=='\\bar' and a and a.kind=='string' then return supported('barline',{style=bounded(unquote(a.text))}),i+1
    elseif s=='\\clef' and a and (a.kind=='string' or a.kind=='word') then
      return supported('clef',{clef=bounded(a.kind=='string' and unquote(a.text) or a.text)}),i+1
    elseif s=='\\partial' and a and a.kind=='number' then
      local n=i+1;while ts[n+1] and ts[n+1].text=='.' do n=n+1 end
      return supported('pickup',{duration=bounded(span(i+1,n))}),n
    elseif s=='\\mark' or s=='\\textMark' or s=='\\textEndMark' or s=='\\rehearsalMark' then
      local last=expression_end(ts,i+1)
      if last then
        local text=span(i+1,last);local detail={form=s=='\\textEndMark' and 'end' or 'score',mark=bounded(text)}
        local glyph=text:match('\\musicglyph%s+"([^"]+)"')
        if glyph then detail.glyph=bounded(({['scripts.segno']='Segno',['scripts.coda']='Coda'})[glyph] or glyph) end
        return supported('mark',detail),last
      end
    elseif s=='\\break' or s=='\\noBreak' or s=='\\pageBreak' or s=='\\noPageBreak' then
      return supported('layout',{command=s}),i
    end
  end
  -- Do not classify command-like text inside markup, strings, or Scheme as
  -- score commands. Keep a stack for Scheme lists, separate from music braces.
  local excluded={}
  local i=1
  while i<=#ts do
    local t=ts[i]
    if t.text=='#' or t.text=='$' then
      local n=i+1
      if ts[n] and ts[n].text=="'" then n=n+1 end
      if ts[n] and ts[n].text=='(' then
        local depth=1;n=n+1
        while ts[n] and depth>0 do
          if ts[n].text=='(' then depth=depth+1 elseif ts[n].text==')' then depth=depth-1 end
          n=n+1
        end
      else n=(expression_end(ts,i) or i)+1 end
      for j=i,n-1 do excluded[j]=true end;i=n
    elseif t.text=='\\markup' then
      local last=expression_end(ts,i)
      if not last then
        -- Unknown markup arity: withhold the enclosing block's remainder.
        last=#ts
        for j=i-1,1,-1 do if ts[j].text=='{' and ts[j].close and ts[j].close>i then last=ts[j].close-1;break end end
      end
      for j=i,last do excluded[j]=true end;i=last+1
    else i=i+1 end
  end
  for n,t in ipairs(ts) do
    if not excluded[n] and t.kind=='command' then
      local value=command(n)
      if value then put(n,value) end
      if t.text=='\\alternative' and ts[n+1] and ts[n+1].close then
        local opening=n+1;local count=0
        for j=opening+1,ts[opening].close-1 do
          if ts[j].text=='{' and ts[j].depth==ts[opening].depth+1 then
            count=count+1;put(j,supported('alternative',{ending=count}))
          end
        end
      end
    end
  end
  -- Resolve a literal key alias only when it is the selected definition;
  -- an opaque redefinition or ambiguous include must not inherit old details.
  local own=type(guard)=='table' and guard.snapshot and guard.snapshot.streams[raw] or ts
  for n,t in ipairs(ts) do
    if t.kind=='command' and not excluded[n] then
      local candidates=definitions[t.text:sub(2)] or {};local found
      for _,d in ipairs(candidates) do if d.stream==own and d.index<n then found=d end end
      if not found and #candidates==1 then found=candidates[1] end
      if found and found.value then put(n,found.value) end
    end
  end
  for _,block in ipairs(blocks) do
    local n=block.open+1
    if block.mode=='lyric' then
      local stanza
      while n<block.close do
        local t=ts[n];local s=t.text
        if s=='\\set' or s=='\\override' or s=='\\revert' or s=='\\unset' then
          local first=n;n=n+1
          if s=='\\revert' or s=='\\unset' then
            if ts[n] then
              n=n+1
              while ts[n] and (ts[n].text=='.' or ts[n-1].text=='.') do n=n+1 end
            end
          else
            while n<block.close and ts[n].text~='=' and ts[n].kind~='command' and ts[n].text~='}' do n=n+1 end
            if ts[n] and ts[n].text=='=' then
              local next_token=ts[n+1]
              local last=next_token and next_token.kind=='command' and next_token.text~='\\markup' and n+1 or expression_end(ts,n+1)
              if not last then break end
              if span(first+1,n-1)=='stanza' then
                stanza=bounded(ts[n+1].kind=='string' and unquote(ts[n+1].text) or span(n+1,last))
                local value=supported('lyric',{form='stanza',text=bounded(span(n+1,last))})
                for j=first,last do put(j,value) end
              end
              n=last+1
            end
          end
        elseif s=='\\markup' then n=(expression_end(ts,n) or block.close)+1
        elseif s=='\\skip' then n=(expression_end(ts,n+1) or n)+1
        elseif t.kind=='command' then n=n+1 -- opaque command; do not guess its expansion
        elseif s=='{' or s=='}' then n=n+1
        elseif not excluded[n] then
          local last=n
          while ts[last+1] and last+1<block.close and ts[last+1].first==ts[last].last+1 and not excluded[last+1] and ts[last+1].kind~='command' and ts[last+1].text~='{' and ts[last+1].text~='}' do last=last+1 end
          local text=span(n,last)
          local form=text=='__' and 'extender' or text=='--' and 'hyphen' or text=='_' and 'skip' or 'syllable'
          local detail={form=form,text=bounded(t.kind=='string' and unquote(text) or text)}
          if block.definition then detail.definition=bounded(block.definition) end
          if stanza then detail.stanza=stanza end
          put(n,supported('lyric',detail))
          n=last+1
        else n=n+1 end
      end
    else
      -- Chord spelling and modifiers are source values, not an expanded set of
      -- sounding pitches. Fail the local block when duration state is unknown.
      local values={};local denominator,dots,scale=4,'','';local failed=false
      local language_ok=pitch_language_ok
      while n<block.close do
        local t=ts[n];local s=t.text
        if t.kind=='word' and (reader.pitch(s) or s=='s' or s=='r') then
          local first=n;local root=pitch_name(s);n=n+1;local explicit=false
          if ts[n] and ts[n].kind=='number' then
            denominator=tonumber(ts[n].text);dots='';scale='';explicit=true;n=n+1
            if denominator<1 or denominator>1024 or math.log(denominator)/math.log(2)%1>1e-9 then failed=true;break end
            while ts[n] and ts[n].text=='.' do dots=dots..'.';n=n+1 end
          end
          if ts[n] and ts[n].text=='*' then
            if not ts[n+1] or ts[n+1].kind~='number' then failed=true;break end
            scale='*'..ts[n+1].text;n=n+2
            if ts[n] and ts[n].text=='/' then
              if not ts[n+1] or ts[n+1].kind~='number' or tonumber(ts[n+1].text)==0 then failed=true;break end
              scale=scale..'/'..ts[n+1].text;n=n+2
            end
          end
          local modifier,bass='',nil
          if ts[n] and ts[n].text==':' then
            n=n+1;local start=n
            while ts[n] and (ts[n].kind=='word' and not reader.pitch(ts[n].text) or ts[n].kind=='number' or ts[n].text=='.' or ts[n].text=='+' or ts[n].text=='-') do n=n+1 end
            if n>start then modifier=span(start,n-1) end
          end
          if ts[n] and ts[n].text=='/' then
            n=n+1;if ts[n] and ts[n].text=='+' then n=n+1 end
            if not ts[n] or not pitch_name(ts[n].text) then failed=true;break end
            bass=ts[n].text;n=n+1
          end
          local detail={form=root and 'name' or s=='s' and 'skip' or 'rest',written=bounded(span(first,n-1)),duration={notation=bounded(denominator..dots..scale),inherited=not explicit}}
          if root and language_ok then
            detail.root=root;detail.modifier=bounded(modifier~='' and modifier or 'Major (default)')
            if bass then detail.bass=pitch_name(bass) end
          end
          values[ts[first].first]=supported('chord',detail)
        elseif s=='{' or s=='}' or s=='|' or s=='~' then n=n+1
        elseif s=='\\repeat' or s=='\\alternative' or s=='\\partial' or s=='\\bar' or s=='\\key' or s=='\\time' or s=='\\tempo' or s=='\\break' then
          local _,last=command(n);if not last then failed=true;break end;n=last+1
        else failed=true;break end
      end
      if not failed then for byte,value in pairs(values) do mapped[byte]=value end end
    end
  end
  -- Event punctuation is meaningful only inside music, never in prose, Scheme,
  -- chord modifiers, or lyric punctuation.
  for n,t in ipairs(ts) do
    if not mapped[t.first] and not excluded[n] and (punctuation[t.text] or t.text=='-' or t.text=='^' or t.text=='_') then
      local inside_mode=false
      for _,b in ipairs(blocks) do if n>b.open and n<b.close then inside_mode=true;break end end
      if not inside_mode then
        local accepted,r=pcall(reader.region,ts,t.first,t.first,true)
        if accepted and ts[r.open].first<t.first then
          local spec=punctuation[t.text]
          if spec then put(n,supported(spec[1],{name=spec[2],notation=t.text}))
          elseif (t.text=='-' or t.text=='^' or t.text=='_') and ts[n+1] and punctuation[ts[n+1].text] then
            local spec=punctuation[ts[n+1].text]
            put(n,supported(spec[1],{name=spec[2],notation=t.text..ts[n+1].text,direction=t.text=='^' and 'Above' or t.text=='_' and 'Below' or 'Default'}))
          elseif (t.text=='-' or t.text=='^' or t.text=='_') and ts[n+1] and short[ts[n+1].text] then
            put(n,supported('articulation',{name=short[ts[n+1].text],notation=t.text..ts[n+1].text}))

          end
        end
      end
    end
  end
  return function(byte)return mapped[byte] or inspection.unsupported() end
end
return M
