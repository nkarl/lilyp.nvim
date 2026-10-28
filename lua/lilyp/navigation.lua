-- SVG is the interactive score medium. PDF artifacts open as ordinary documents.
local M={context=require('lilyp.score_context').resolve}
function M.open(opts)
  assert(not opts or not opts.format or opts.format=='svg','SVG is the working viewer; use LylipViewPDF to open a publication artifact')
  return require('lilyp.svg_navigation').open(opts)end
function M.forward(opts)
  assert(not opts or not opts.format or opts.format=='svg','PDF navigation is removed; forward search targets SVG')
  return require('lilyp.svg_navigation').forward(opts)
end
function M.open_pdf(opts)
  local context=opts and opts.context or M.context(opts and opts.buf)
  assert(vim.fn.filereadable(context.pdf)==1,'PDF is missing. Run :LylipPublishPDF first: '..context.pdf)
  local viewer=require('lilyp').options().viewer
  if viewer then return viewer(context.pdf) end
  return vim.ui.open(context.pdf)
end
function M.attach(buf)
  local function run(opts)
    local ok,err=pcall(M.open,opts)
    if not ok then vim.notify(tostring(err),vim.log.levels.ERROR) end
  end
  vim.api.nvim_buf_create_user_command(buf,'Viewer',function()run({buf=buf})end,
    {force=true,desc='Open the SVG score viewer'})
  if not require('lilyp').options().navigation.enabled then return end
  vim.api.nvim_buf_call(buf,function()
    if vim.fn.maparg('<F7>','n')=='' then
      vim.keymap.set('n','<F7>',function()run({buf=buf,forward=true,occurrence=vim.v.count1})end,
        {buffer=buf,desc='Locate the source note in the score'})
    end
  end)
end
return M
