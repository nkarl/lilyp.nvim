-- Compatibility facade assembled from shared semantics, display metadata, and recipes.
local settings=require('lilyp.settings')
local ui=require('lilyp.field_ui')
local bindings=require('lilyp.style_bindings')
local M={tabs=ui.tabs,list={},by_id={}}
for _,display in ipairs(ui.list) do
  local definition=assert(settings.by_id[display.id],'Unknown display setting: '..display.id)
  local recipe=assert(bindings.by_id[display.id],'Missing source recipe: '..display.id)
  assert(not M.by_id[display.id],'Duplicate display setting: '..display.id)
  local field=vim.tbl_extend('force',definition,recipe,display)
  M.list[#M.list+1]=field;M.by_id[field.id]=field
end
function M.validate(f,value)return settings.validate(f.id,value)end
M.literal=bindings.literal
return M
