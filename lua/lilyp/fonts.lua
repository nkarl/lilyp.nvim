-- Static Fontconfig faces. Availability is checked without changing a project.
local M={}
local inventory
-- These aliases are defined by LilyPond's private Fontconfig configuration, so
-- the system fc-list/fc-match cannot validate them. Offer their standard faces.
local native={}
for _,family in ipairs({'LilyPond Serif','LilyPond Sans Serif','LilyPond Monospace'}) do
  native[family]={normal={upright=true,italic=true},bold={upright=true,italic=true}}
end
function M.is_builtin(family)return native[family]~=nil end
local weights={[0]='thin',[40]='ultralight',[50]='light',[55]='semilight',[75]='book',[80]='normal',[100]='medium',[180]='semibold',[200]='bold',[205]='ultrabold',[210]='heavy',[215]='ultraheavy'}
local aliases={regular='normal',extralight='ultralight',demilight='semilight',demibold='semibold',extrabold='ultrabold',black='heavy',ultrablack='ultraheavy',extrablack='ultraheavy',slanted='oblique'}
local function supported(path,format)
  if format~='TrueType' and format~='CFF' and format~='Type 1' then return false end
  if format~='CFF' then return true end
  -- CFF2 and OpenType collections are unsupported by the standard PDF backend.
  local file=io.open(path,'rb');if not file then return false end
  local header=file:read(12)
  if not header or #header<12 or header:sub(1,4)=='ttcf' then file:close();return false end
  local count=header:byte(5)*256+header:byte(6)
  local tables=file:read(count*16) or '';file:close()
  for i=1,#tables,16 do if tables:sub(i,i+3)=='CFF2' then return false end end
  return true
end
function M.load()
  if inventory then return inventory end
  local result=vim.system({'fc-list','--format=%{family}\t%{weight}\t%{slant}\t%{variable}\t%{fontformat}\t%{file}\n'},{text=true}):wait(10000)
  assert(result.code==0,'Fontconfig is unavailable')
  local families={}
  for line in (result.stdout or ''):gmatch('[^\n]+') do
    local names,weight,slant,variable,format,path=line:match('^(.-)\t(.-)\t(.-)\t(.-)\t(.-)\t(.*)$')
    if names and variable:lower()~='true' and supported(path,format) then
      local series=weights[tonumber(weight)]
      local shape=({[0]='upright',[100]='italic',[110]='oblique'})[tonumber(slant)]
      if series and shape then for name in names:gmatch('[^,]+') do
        families[name]=families[name] or {};families[name][series]=families[name][series] or {};families[name][series][shape]=true
      end end
    end
  end
  inventory=families;return inventory
end
function M.clear()inventory=nil end
function M.families(values)
  local names={}
  local families=vim.tbl_extend('force',{},native)
  if vim.fn.executable('fc-list')==1 then families=vim.tbl_extend('force',families,M.load()) end
  for name in pairs(families) do
    if not values or pcall(M.check,vim.tbl_extend('force',values,{lyric_font=name})) then names[#names+1]=name end
  end
  table.sort(names);return names
end
function M.check(values)
  local family,weight,shape=values.lyric_font,values.lyric_weight,values.lyric_shape
  if not family or (weight==nil and shape==nil) then return true end
  local faces=native[family] or M.load()[family]
  assert(faces,'No supported static font faces found for '..family)
  weight=aliases[weight] or weight;shape=aliases[shape] or shape
  for series,shapes in pairs(faces) do
    if (not weight or series==weight) and (not shape or shapes[shape]) then return true end
  end
  error('Font face unavailable: '..family..' · '..(weight or 'any weight')..' · '..(shape or 'any shape')..'. Choose an available weight/shape; substitution was not staged.')
end
function M.choices(id,values,choices)
  if id~='lyric_weight' and id~='lyric_shape' then return choices end
  local result={}
  for _,value in ipairs(choices) do
    local candidate=vim.tbl_extend('force',values,{[id]=value})
    if (not aliases[value] or values[id]==value) and pcall(M.check,candidate) then result[#result+1]=value end
  end
  return result
end
function M.validate_change(before,after)
  if before.lyric_font~=after.lyric_font or before.lyric_weight~=after.lyric_weight or before.lyric_shape~=after.lyric_shape then M.check(after) end
end
return M
