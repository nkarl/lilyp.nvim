local M={}

local function destinations()
  local spellings={'c','cis','des','d','dis','ees','e','f','fis','ges','g','gis','aes','a','ais','bes','b'}
  local semitones={0,1,1,2,3,3,4,5,6,6,7,8,8,9,10,10,11}
  local entries={}
  for _,octave in ipairs({1,0,2,-1,3,-2,4,-3,5,-4,6}) do
    local suffix=octave>=0 and string.rep("'",octave) or string.rep(',',-octave)
    for i,name in ipairs(spellings) do
      local value=48+12*octave+semitones[i]
      if value>=0 and value<=127 then
        entries[#entries+1]=name..suffix
      end
    end
  end
  return entries
end

function M.open(opts)
  opts=opts or {}
  local transpose=require('lilyp.transpose')
  local source=transpose.capture(opts)
  local actions=require('telescope.actions')
  local state=require('telescope.actions.state')
  local values=destinations()
  local picker=require('telescope.pickers').new(opts,{
    prompt_title='New first pitch (absolute LilyPond)',
    results_title='Destination pitches',
    finder=require('telescope.finders').new_table({results=values}),
    sorter=require('telescope.config').values.generic_sorter(opts),
    previewer=false,
    attach_mappings=function(prompt_bufnr)
      actions.select_default:replace(function()
        local query=vim.trim(state.get_current_line())
        local entry=state.get_selected_entry()
        -- Respect Telescope's highlighted row. A complete encoding also works
        -- without a matching row (double accidentals or pitches beyond the list).
        local destination=(entry and entry.value) or (transpose.valid_destination(query) and query)
        if not destination then
          vim.notify('Choose a destination pitch, for example fis\'',vim.log.levels.ERROR)
          return
        end
        local ok,result=pcall(transpose.selection,destination,source)
        if not ok then vim.notify(tostring(result),vim.log.levels.ERROR);return end
        actions.close(prompt_bufnr)
      end)
      return true
    end,
  })
  picker:find()
  return picker
end
return M
