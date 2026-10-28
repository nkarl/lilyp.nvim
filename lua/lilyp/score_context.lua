-- Resolve editable source and build identity without creating output or saving.
local M={}
function M.resolve(buf)
  buf=buf or vim.api.nvim_get_current_buf()
  if buf==0 then buf=vim.api.nvim_get_current_buf() end
  local source=vim.api.nvim_buf_get_name(buf)
  assert(source~='' and source:match('%.i?ly$'),'Open a saved LilyPond source first')
  local project=require('lilyp.project').resolve(source)
  local main,root,name,check
  if project then
    main,root,name=project.main,project.root,'main'
    check={main,require('lilyp.fs').inside(root,project.style_relative)}
  else
    local adapter=require('lilyp.integrations.nvls')
    local file=adapter.source_info and vim.api.nvim_buf_call(buf,adapter.source_info) or nil
    main=file and file.main or source
    root=vim.fs.dirname(main);name=vim.fn.fnamemodify(main,':t:r');check={main}
  end
  local directory=require('lilyp.output').directory(root,not project and main or nil)
  return {buf=buf,source=source,main=main,root=root,name=name,directory=directory,
    pdf=directory..'/'..name..'.pdf',manifest=directory..'/'..name..'.svg.json',check_sources=check,project=project~=nil}
end
function M.assert_clean(context,command)
  for _,buf in ipairs(vim.api.nvim_list_bufs()) do
    local name=vim.api.nvim_buf_get_name(buf)
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified and name:match('%.i?ly$')
      and (name==context.source or name==context.main or vim.startswith(name,context.root..'/')) then
      error('Unsaved source changes. Compile with '..(command or 'F5')..' before locating a note: '..name)
    end
  end
end
return M
