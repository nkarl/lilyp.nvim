-- Explicit trial profiles; these never replace setup or existing-project defaults.
local M={list={
  {id='standard_reading',label='Standard reading · staff 20 pt, lyrics +2, upright, regular',values={staff_size=20,lyric_size=2,lyric_shape='upright',lyric_weight='normal'}},
  {id='large_print',label='Large print · staff 22 pt, lyrics +3, upright, regular',values={staff_size=22,lyric_size=3,lyric_shape='upright',lyric_weight='normal'}},
}}
function M.get(id)
  for _,profile in ipairs(M.list) do if profile.id==id then return vim.deepcopy(profile.values) end end
  error('Unknown readability profile: '..tostring(id))
end
function M.choose(state)
  vim.ui.select(M.list,{prompt='Readability trial · stages a draft; Preview before Apply',format_item=function(item)return item.label end},function(item)
    if item and not state.closed and state.is_current() then state.apply_profile(item.id) end
  end)
end
return M
