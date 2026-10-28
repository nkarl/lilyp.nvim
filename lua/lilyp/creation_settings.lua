local settings=require('lilyp.settings')
local M={}
local names={staff_size='staff_size',numeric_time='numeric_time',lyric_font='lyric_font',lyric_size='lyric_size',
  lyric_word_spacing='word_spacing',odd_verse_color='odd_color',even_verse_color='even_color',
  chord_size='chord_size',chord_padding='chord_padding',inner_note_size='inner_note_size',section_gap='section_gap'}
function M.defaults()
  local result={}
  for old,id in pairs(names) do result[old]=settings.by_id[id].default end
  result.lyric_italic=settings.by_id.lyric_shape.default=='italic'
  result.subtitle_italic=settings.by_id.subtitle_shape.default=='italic'
  for _,id in ipairs({'title_size','subtitle_size','composer_size'}) do result[id]=settings.by_id[id].default end
  return result
end
function M.canonical(style)
  local result={}
  for old,id in pairs(names) do if style[old]~=nil then result[id]=style[old] end end
  for old,id in pairs({lyric_italic='lyric_shape',subtitle_italic='subtitle_shape'}) do
    if style[old]~=nil then
      assert(type(style[old])=='boolean','style.'..old..' must be true or false')
      result[id]=style[old] and 'italic' or 'upright'
    end
  end
  -- Canonical names take precedence over their legacy aliases.
  for id in pairs(settings.by_id) do if style[id]~=nil then result[id]=style[id] end end
  settings.validate_values(result,'global');return result
end
function M.values(options)
  local result=M.canonical(vim.tbl_extend('force',M.defaults(),options.style or {}))
  result.paper=options.paper
  return result
end
function M.set(options,id,value)
  if value~=nil then settings.validate(id,value,'global') end
  if id=='paper' then options.paper=value;return end
  options.style=options.style or {}
  options.style[id]=value
  -- Keep the old setup keys usable after editing or resetting a canonical field.
  for old,canonical in pairs(names) do
    if canonical==id and old~=id then options.style[old]=value end
  end
  for canonical,old in pairs({lyric_shape='lyric_italic',subtitle_shape='subtitle_italic'}) do
    if id==canonical then
      if value==nil then options.style[old]=nil else options.style[old]=value=='italic' end
    end
  end
end
return M
