-- Inspection = Unsupported | Supported Symbol. Constructors enforce the
-- per-variant contract; unavailable parser details never cross this boundary.
local M={}
local function str(v)return type(v)=='string' and #v<=4096 end
local function nonempty(v)return str(v) and #v>0 end
local function integer(v)return type(v)=='number' and v==v and v%1==0 end
local function positive(v)return integer(v) and v>0 end
local function boolean(v)return type(v)=='boolean' end
local function enum(...)
  local values={};for _,v in ipairs({...}) do values[v]=true end
  return function(v)return type(v)=='string' and values[v]==true end
end
local function record(required,optional,check)
  return function(v)
    if type(v)~='table' then return false end
    for key,validate in pairs(required) do if not validate(v[key]) then return false end end
    for key,value in pairs(v) do
      local validate=required[key] or (optional or {})[key]
      if not validate or not validate(value) then return false end
    end
    return not check or check(v)
  end
end
local function list(validate)
  return function(v)
    if type(v)~='table' or not vim.islist(v) then return false end
    local count=0
    for key,value in pairs(v) do
      if not positive(key) or key>#v or not validate(value) then return false end
      count=count+1
    end
    return count==#v
  end
end
local duration=record({denominator=positive,dots=integer,notation=nonempty,inherited=boolean},{scale=nonempty},function(v)
  return v.dots>=0 and v.denominator<=1024 and math.log(v.denominator)/math.log(2)%1<1e-9
end)
local tuplets=list(record({command=enum('tuplet','times'),ratio=nonempty}))
local mode=enum('relative','absolute','fixed')
local direction=enum('Above','Below','Default')
local schemas={
  note=record({first=positive,last=positive,written_pitch=nonempty,absolute_pitch=nonempty,pitch=nonempty,midi=integer,
    mode=mode,duration=duration,tuplets=tuplets,chord_member=positive,chord_size=positive,grace=boolean},{anchor=nonempty},function(v)
      return v.last>=v.first and v.chord_member<=v.chord_size and (v.mode=='absolute' and v.anchor==nil or v.mode~='absolute' and v.anchor~=nil)
    end),
  rest=record({first=positive,last=positive,duration=duration,tuplets=tuplets,grace=boolean},nil,function(v)return v.last>=v.first end),
  skip=record({first=positive,last=positive,duration=duration,tuplets=tuplets,grace=boolean},nil,function(v)return v.last>=v.first end),
  lyric=record({form=enum('syllable','extender','hyphen','skip','stanza'),text=str},{definition=nonempty,stanza=str}),
  chord=record({form=enum('name','skip','rest'),written=nonempty,duration=record({notation=nonempty,inherited=boolean})},
    {root=nonempty,modifier=nonempty,bass=nonempty},function(v)
      return (v.root==nil)==(v.modifier==nil) and (v.bass==nil or v.root~=nil)
        and (v.form=='name' or v.root==nil and v.modifier==nil and v.bass==nil)
    end),
  dynamic=record({name=nonempty,notation=nonempty},{meaning=nonempty}),
  articulation=record({name=nonempty,notation=nonempty}),
  beam=record({name=nonempty,notation=nonempty},{direction=direction}),
  slur=record({name=nonempty,notation=nonempty},{direction=direction}),
  tie=record({name=nonempty,notation=nonempty},{direction=direction}),
  key=record({form=enum('literal','alias')},{written=nonempty,key=nonempty,alias=nonempty},function(v)
    return v.form=='literal' and v.written~=nil and v.alias==nil or v.form=='alias' and v.alias~=nil and v.key~=nil and v.written==nil
  end),
  meter=record({meter=nonempty,command=nonempty}),
  tuplet=record({ratio=nonempty,command=nonempty}),
  tempo=record({}, {text=str,beat_unit=nonempty,bpm=nonempty},function(v)
    return (v.beat_unit==nil)==(v.bpm==nil) and (v.text~=nil or v.beat_unit~=nil)
  end),
  ['repeat']=record({repeat_type=enum('volta','unfold','percent','tremolo'),count=integer}),
  alternative=record({}, {ending=positive}),
  grace=record({command=nonempty}),
  pitch_context=record({mode=mode},{anchor=nonempty}),
  barline=record({style=str}),
  clef=record({clef=nonempty}),
  pickup=record({duration=nonempty}),
  mark=record({form=enum('score','end'),mark=str},{glyph=nonempty}),
  layout=record({command=nonempty}),
}
M.kinds=vim.tbl_keys(schemas);table.sort(M.kinds)
function M.unsupported()return {tag='unsupported'}end
function M.valid(result)
  if type(result)~='table' then return false end
  if result.tag=='unsupported' then return vim.tbl_count(result)==1 end
  if result.tag~='supported' or vim.tbl_count(result)~=2 or type(result.symbol)~='table' then return false end
  local symbol=result.symbol;local validate=schemas[symbol.kind]
  if not validate then return false end
  local detail={};for key,value in pairs(symbol) do if key~='kind' then detail[key]=value end end
  return validate(detail)
end
function M.supported(kind,detail)
  assert(schemas[kind],'Unknown inspection symbol kind: '..tostring(kind))
  assert(schemas[kind](detail),'Invalid '..kind..' inspection details')
  local symbol=vim.deepcopy(detail);symbol.kind=kind
  return {tag='supported',symbol=symbol}
end
-- Prefer a complete literal event over a standalone source symbol. This is the
-- only composition point; consumers receive exactly one branch.
function M.choose(event,symbol)
  assert(M.valid(event) and M.valid(symbol),'Invalid reader inspection result')
  return event.tag=='supported' and event or symbol
end
-- Loading untrusted/future/corrupt cached metadata fails closed. New readers use
-- constructors directly so implementation errors fail tests rather than hiding.
function M.normalize(result)
  return M.valid(result) and vim.deepcopy(result) or M.unsupported()
end
return M
