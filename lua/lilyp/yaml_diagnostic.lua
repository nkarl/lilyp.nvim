-- Structured document failures; display wording never controls validation.
local M={}
local kinds={Syntax=true,DuplicateKey=true,InvalidKind=true,UnsupportedVersion=true,InvalidShape=true,
  InvalidValue=true,UnknownField=true,DuplicateId=true,InvalidPath=true,InvalidPresentation=true,MissingReference=true}
local meta={__tostring=function(value)return M.message(value)end}
local function same(a,b)
  if #a~=#b then return false end
  for i,item in ipairs(a) do if item~=b[i] then return false end end
  return true
end
function M.locate(locations,path,part)
  local parent=vim.deepcopy(path)
  while true do
    for _,entry in ipairs(locations or {}) do
      if same(entry.path,parent) then return vim.deepcopy(entry[part or 'value']) end
    end
    if #parent==0 then return {line=1,column=1} end
    table.remove(parent)
  end
end
function M.new(kind,path,message,locations,part)
  assert(kinds[kind],'Unknown YAML diagnostic kind')
  assert(type(path)=='table' and type(message)=='string' and message~='','Invalid YAML diagnostic')
  assert(vim.islist(path),'YAML path must be a list')
  for _,item in ipairs(path) do assert(type(item)=='string' or type(item)=='number' and item>=1 and item%1==0,'Invalid YAML path') end
  return setmetatable({tag='yaml_diagnostic',kind=kind,path=vim.deepcopy(path),message=message,
    location=M.locate(locations,path,part)},meta)
end
function M.is(value)return type(value)=='table' and getmetatable(value)==meta end
function M.at(value,locations)
  assert(M.is(value),'Expected YAML diagnostic')
  local result=M.new(value.kind,value.path,value.message,locations)
  return result
end
function M.path(path)
  local text=''
  for _,item in ipairs(path) do
    if type(item)=='number' then text=text..'['..item..']'
    elseif item:match('^[%a_][%w_]*$') then text=text..(text~='' and '.' or '')..item
    else text=text..'['..vim.json.encode(item)..']' end
  end
  return text
end
function M.message(value)
  return 'score.yaml:'..value.location.line..':'..value.location.column..': '..value.message
    ..(#value.path>0 and (' ('..M.path(value.path)..')') or '')
end
return M
