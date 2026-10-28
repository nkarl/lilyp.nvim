-- Two bounded transition graphs; effects and resources stay with their owners.
local outcome=require('lilyp.operation_outcome')
local M={}
local common={
  cancelling={cleaning=true},publishing={recovering=true,cleaning=true},
  recovering={cleaning=true},cleaning={completed=true},completed={},
}
local graphs={
  validation=vim.tbl_extend('force',common,{
    queued={validating=true,cancelling=true,cleaning=true},
    validating={publishing=true,cancelling=true,cleaning=true},
  }),
  build=vim.tbl_extend('force',common,{
    preparing={running=true,cancelling=true,cleaning=true},
    running={publishing=true,cancelling=true,cleaning=true},
  }),
}
function M.new(kind)
  assert(graphs[kind],'Unknown lifecycle kind')
  return {kind=kind,phase=kind=='validation' and 'queued' or 'preparing'}
end
local function advance(state,phase)
  assert(graphs[state.kind] and graphs[state.kind][state.phase],'Unknown lifecycle state')
  assert(graphs[state.kind][state.phase][phase],state.kind..': illegal transition '..state.phase..' -> '..tostring(phase))
  if phase=='cleaning' then state.settled_from=state.phase end
  state.phase=phase
end
function M.move(state,phase)
  assert(phase~='completed','Completion requires a validated outcome')
  advance(state,phase)
end
function M.cancellable(state)
  return state.phase=='queued' or state.phase=='validating' or state.phase=='preparing' or state.phase=='running'
end
function M.complete(state,result)
  outcome.assert_valid(result)
  if state.settled_from=='cancelling' then assert(result.tag=='cancelled','Cancelled work must complete as cancelled') end
  if result.tag=='cancelled' then assert(state.settled_from=='cancelling','Cancellation needs a cancellation transition')
  elseif result.publication=='published' then assert(state.settled_from=='publishing','Published outcome needs publication')
  elseif result.publication=='restored' or result.publication=='partial' then assert(state.settled_from=='recovering','Rollback outcome needs recovery') end
  advance(state,'completed');state.outcome=result
  return result
end
return M
