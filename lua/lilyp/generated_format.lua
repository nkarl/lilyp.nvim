-- Whitespace policy for newly emitted source only. Never reformat handwritten projects.
local M={}
function M.normalize(text,options)
  options=options or {}
  local code=require('lilyp.source_regions').code_positions(text)
  local lines,at={},1
  while at<=#text do
    local finish=text:find('\n',at,true) or #text+1
    local value=text:sub(at,finish-1)
    lines[#lines+1]={text=value,blank=value:match('^%s*$')~=nil and (code[at] or code[finish]) or false}
    at=finish+1
  end
  local kept={}
  for i,line in ipairs(lines) do
    local skip=false
    if line.blank then
      skip=#kept==0 or kept[#kept].blank
      local previous=kept[#kept]
      local following=lines[i+1]
      if previous and following then
        if options.font_properties and previous.text:match('^%s*property%-defaults%.fonts%.')
          and following.text:match('^%s*property%-defaults%.fonts%.') then skip=true end
        if options.includes and previous.text:match('^\\include "sections/')
          and following.text:match('^\\include "sections/') then skip=true end
      end
    end
    if not skip then kept[#kept+1]=line end
  end
  while #kept>0 and kept[#kept].blank do kept[#kept]=nil end
  local result={};for _,line in ipairs(kept) do result[#result+1]=line.text end
  return table.concat(result,'\n')..'\n'
end
return M
