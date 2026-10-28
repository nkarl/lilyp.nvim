-- In-memory adapter for excerpt-only and music/symbol-era build manifests.
-- The current readers and card never consume these shapes or rewrite a cache.
local inspection=require('lilyp.inspection')
local M={}
local function construct(kind,detail)
  local ok,value=pcall(inspection.supported,kind,detail)
  return ok and value or inspection.unsupported()
end
local function music(value)
  if type(value)~='table' or value.status~='resolved' then return inspection.unsupported() end
  local kind=value.event_type or 'note'
  if kind~='note' and kind~='rest' and kind~='skip' then return inspection.unsupported() end
  local detail={first=value.first,last=value.last,duration=value.duration,tuplets=value.tuplets,grace=value.grace or false}
  if kind=='note' then
    for _,key in ipairs({'written_pitch','absolute_pitch','pitch','midi','mode','anchor','chord_member','chord_size'}) do detail[key]=value[key] end
  end
  return construct(kind,detail)
end
local function symbol(value)
  if type(value)~='table' or value.status~='resolved' or type(value.fields)~='table' then return inspection.unsupported() end
  local f={}
  for key,item in pairs(value.fields) do
    if type(key)~='number' or type(item)~='table' or type(item.label)~='string' or type(item.value)~='string' or f[item.label]~=nil then
      return inspection.unsupported()
    end
    f[item.label]=item.value
  end
  local kind=value.kind;local detail
  if kind=='lyric' then
    local forms={['Lyric syllable']='syllable',['Lyric extender']='extender',['Lyric hyphen']='hyphen',['Lyric alignment skip']='skip',['Stanza label']='stanza'}
    detail={form=forms[value.label],text=f.Text or f.Label,definition=f.Definition,stanza=f.Stanza}
  elseif kind=='chord' then
    local forms={['Chord name']='name',['Chord skip']='skip',['Chord rest']='rest'}
    local notation,inherited=(f['Notated duration'] or ''):match('^(.-) · (.*)$')
    if inherited~='inherited' and inherited~='explicit' then return inspection.unsupported() end
    detail={form=forms[value.label],written=f['Written chord'],duration={notation=notation,inherited=inherited=='inherited'},root=f.Root,modifier=f.Modifier,bass=f.Bass}
  elseif kind=='dynamic' or kind=='articulation' or kind=='beam' or kind=='slur' or kind=='tie' then
    detail={name=value.label,notation=f.Marking or f.Notation}
    if kind=='dynamic' then detail.meaning=f.Meaning end
    if kind=='beam' or kind=='slur' or kind=='tie' then detail.direction=f.Direction end
  elseif kind=='key' then detail={form=f.Alias and 'alias' or 'literal',key=f.Key,alias=f.Alias,written=f['Written key']}
  elseif kind=='meter' then detail={meter=f.Meter,command=f.Command}
  elseif kind=='tuplet' then detail={ratio=f.Ratio,command=f.Command}
  elseif kind=='tempo' then detail={text=f.Text,beat_unit=f['Beat unit'],bpm=f['Beats per minute']}
  elseif kind=='repeat' then detail={repeat_type=f.Type,count=tonumber(f.Count)}
  elseif kind=='alternative' then detail={ending=f.Ending and tonumber(f.Ending) or nil}
  elseif kind=='grace' or kind=='layout' then detail={command=f.Command}
  elseif kind=='pitch_context' then detail={mode=f.Mode,anchor=f.Anchor}
  elseif kind=='barline' then detail={style=f.Style}
  elseif kind=='clef' then detail={clef=f.Clef}
  elseif kind=='pickup' then detail={duration=f['Notated duration']}
  elseif kind=='mark' then detail={form=value.label=='End mark' and 'end' or 'score',mark=f.Mark,glyph=f.Glyph}
  else return inspection.unsupported() end
  return construct(kind,detail)
end
function M.origin(origin)
  local copy=vim.deepcopy(origin)
  if copy.inspection~=nil then copy.inspection=inspection.normalize(copy.inspection)
  else copy.inspection=inspection.choose(music(copy.music),symbol(copy.symbol)) end
  copy.music=nil;copy.symbol=nil
  return copy
end
return M
