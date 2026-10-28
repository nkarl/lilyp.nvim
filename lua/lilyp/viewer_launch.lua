local M={}
function M.open(url)
  local browser=vim.deepcopy(require('lilyp').options().score_viewer.browser)
  if #browser==0 then
    for _,name in ipairs({'google-chrome-stable','google-chrome','chromium'}) do
      if vim.fn.executable(name)==1 then browser={name};break end
    end
  end
  assert(#browser>0,'Install Chrome/Chromium or configure score_viewer.browser')
  browser[#browser+1]='--app='..url
  assert(vim.fn.jobstart(browser,{detach=true})>0,'Could not launch the SVG viewer')
end
return M
