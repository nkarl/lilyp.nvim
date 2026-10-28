local M = {}
function M.resolve(options)
  assert(options == nil or type(options) == 'table', 'lilyp.setup options must be a table')
  local supplied = vim.deepcopy(options or {})
  if supplied.defaults == nil then supplied.defaults = supplied.generator end
  supplied.generator = nil
  supplied.python = nil -- obsolete interpreter option; YAML runs in process
  assert(supplied.defaults == nil or type(supplied.defaults) == 'table', 'defaults must be a table')
  if supplied.defaults then
    for _, name in ipairs({'style', 'instruments', 'category_defaults', 'subcategory_defaults'}) do
      assert(supplied.defaults[name] == nil or type(supplied.defaults[name]) == 'table', 'defaults.' .. name .. ' must be a table')
    end
  end
  local resolved = vim.tbl_deep_extend('force', vim.deepcopy(require('lilyp.defaults')), supplied)
  for _, name in ipairs({'lilypond'}) do
    assert(type(resolved[name]) == 'string' and resolved[name] ~= '', name .. ' must be an executable name or path')
  end
  assert(type(resolved.gain) == 'number' and resolved.gain >= 0 and resolved.gain < math.huge, 'gain must be a finite nonnegative number')
  assert(resolved.build_location == 'temporary' or resolved.build_location == 'project', 'build_location must be temporary or project')
  assert(type(resolved.build_integration) == 'boolean', 'build_integration must be true or false')
  assert(type(resolved.svg_glyph_cache) == 'boolean', 'svg_glyph_cache must be true or false')
  assert(resolved.viewer == nil or type(resolved.viewer) == 'function', 'viewer must be a function')
  assert(type(resolved.navigation)=='table' and type(resolved.navigation.enabled)=='boolean','navigation.enabled must be true or false')
  -- Old host-side PDF navigation preferences are inert compatibility keys.
  resolved.navigation.python=nil;resolved.navigation.viewer=nil
  assert(type(resolved.score_viewer)=='table','score_viewer must be a table')
  assert(resolved.score_viewer.format==nil or resolved.score_viewer.format=='svg','SVG is the working viewer; use LylipPublishPDF for PDF output')
  resolved.score_viewer.format=nil
  assert(type(resolved.score_viewer.browser)=='table' and vim.islist(resolved.score_viewer.browser),'score_viewer.browser must be an argument list')
  for _,arg in ipairs(resolved.score_viewer.browser) do assert(type(arg)=='string' and arg~='','score_viewer.browser arguments must be nonempty strings') end
  return resolved
end
return M
