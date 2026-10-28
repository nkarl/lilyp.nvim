-- Creation-only emission uses the same canonical recipes as presentation editing.
local bindings=require('lilyp.style_bindings')
local settings=require('lilyp.settings')
local M={}
function M.paper(values)
  local lines={}
  for _,f in ipairs(settings.list) do
    local value=values[f.id]
    if value~=nil and (f.id:match('_margin$') or (bindings.by_id[f.id] or {}).paper) then
      local recipe=bindings.by_id[f.id]
      lines[#lines+1]='  '..(recipe.paper or f.id:gsub('_','-'))..' = '..bindings.literal(f,value)..(f.unit=='mm' and '\\mm' or '')
    end
  end
  return lines
end
function M.layout(values,scope,chords)
  local lines,contexts={},{}
  local ids=scope=='section' and {'staff_size','lyric_font','lyric_size','lyric_shape','word_spacing','chord_size','chord_padding',
    'stanza_size','stanza_shape','row_spacing','hide_tempo_note','indent','short_indent'}
    or {'stanza_size','stanza_shape','row_spacing','hide_tempo_note','metronome_color','rehearsal_color','text_mark_color','short_indent'}
  for _,f in ipairs(settings.list) do
    local recipe=bindings.by_id[f.id]
    if recipe and recipe.creation_extra and not recipe.paper and vim.tbl_contains(f.scopes,scope or 'global') then ids[#ids+1]=f.id end
  end
  for _,id in ipairs(ids) do
    local value=values[id]
    if value~=nil and not (chords==false and (id=='chord_size' or id=='chord_padding')) then
      local recipe=bindings.for_scope(id,scope or 'global')
      local f=settings.by_id[id]
      if recipe.layout_function then lines[#lines+1]='  #('..recipe.layout_function..' '..value..')'
      elseif recipe.setting then lines[#lines+1]='  '..recipe.setting..' = '..value..(recipe.unit or '')
      else
        local context=recipe.context or 'Lyrics'
        contexts[context]=contexts[context] or {}
        local literal=bindings.literal(f,value)
        if f.kind=='number' then literal='#'..literal elseif f.kind=='symbol' then literal="#'"..literal end
        contexts[context][#contexts[context]+1]='    '..(recipe.property and '' or '\\override ')..recipe.layout..' = '..literal
      end
    end
  end
  local names=vim.tbl_keys(contexts);table.sort(names)
  for _,name in ipairs(names) do
    lines[#lines+1]='  \\context { \\'..name
    vim.list_extend(lines,contexts[name]);lines[#lines+1]='  }'
  end
  return lines
end
return M
