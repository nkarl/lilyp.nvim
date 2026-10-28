local M = {}

local function available(module, path)
  return not not package.loaded[module] or #vim.api.nvim_get_runtime_file(path, false) > 0
end

local function run(args)
  local ok, result = pcall(function() return vim.system(args, { text = true }):wait(3000) end)
  if not ok then return nil, tostring(result) end
  local failure = require('lilyp.process').failure(args, result, 3000)
  if failure then return nil, vim.trim(failure) end
  return vim.trim(result.stdout or '')
end

local function tool(name, purpose, required)
  if vim.fn.executable(name) == 1 then
    vim.health.ok(name .. ': ' .. purpose)
    return true
  end
  local report = required and vim.health.error or vim.health.warn
  report(name .. ' not found: ' .. purpose, { 'Install it and make it available on PATH.' })
  return false
end

function M.check()
  local health = vim.health
  health.start('Lylip: runtime and compiler')
  if vim.fn.has('nvim-0.11') == 1 then health.ok('Neovim 0.11 or newer')
  else health.error('Neovim 0.11 or newer is required') end
  local options = require('lilyp').options()
  if not options.svg_glyph_cache then
    health.info('SVG glyph cache is disabled')
  elseif vim.fn.filereadable(require('lilyp.svg_glyph_cache').path)~=1 then
    health.warn('SVG glyph cache hook is missing; builds use ordinary engraving', {'Reinstall the plugin to restore the bundled hook.'})
  else
    health.info('SVG glyph cache requested; the hook enables it only on compatible LilyPond 2.26.0 native SVG builds')
  end
  if tool(options.lilypond, 'score compilation, preview, and Apply', true) then
    local version, err = run({ options.lilypond, '--version' })
    local major, minor = (version or ''):match('(%d+)%.(%d+)')
    if major and (tonumber(major) > 2 or tonumber(major) == 2 and tonumber(minor) >= 26) then
      health.ok(version:match('[^\n]+'))
    else
      health.error('LilyPond 2.26 or newer is required: ' .. (version or err))
    end
  end
  local yaml_ok,yaml=pcall(require,'lilyp.vendor.libyaml')
  if yaml_ok then health.ok('In-process Lua YAML with libyaml '..yaml.version)
  else health.error(tostring(yaml),{'Install the libyaml shared library; no Python or Lua package is required.'}) end
  tool('pdftoppm', 'PDF page comparison during specification import', true)

  health.start('Lylip: optional features')
  if options.navigation.enabled or options.build_integration then
    local browser=options.score_viewer.browser[1]
    if not browser then
      for _,name in ipairs({'google-chrome-stable','google-chrome','chromium'}) do
        if vim.fn.executable(name)==1 then browser=name;break end
      end
    end
    if browser then tool(browser,'SVG app-window viewing',false)
    else health.warn('SVG viewing needs Chrome/Chromium or score_viewer.browser') end
    health.info('Score compilation, YAML specifications, and SVG navigation run in Lua')
  end
  tool('git', 'notation review, workbench records, and milestones', false)
  tool('rg', 'Open Project discovery; direct project paths still work without it', false)
  local fontconfig = tool('fc-list', 'installed font selection', false)
  local family = options.defaults.style.lyric_font
  if type(family) ~= 'string' or family == '' then
    health.error('defaults.style.lyric_font must be a nonempty font family')
  elseif require('lilyp.fonts').is_builtin(family) then
    health.ok('Lyric font uses a LilyPond built-in family: ' .. family)
  elseif fontconfig and vim.fn.executable('fc-match') == 1 then
    local matched = run({ 'fc-match', '--format=%{family}', family })
    local found = false
    for name in (matched or ''):gmatch('[^,]+') do
      if vim.trim(name):lower() == family:lower() then found = true end
    end
    if found then health.ok('Preferred lyric font is installed: ' .. family)
    else health.warn('Preferred lyric font is unavailable: ' .. family, { 'Install it or set defaults.style.lyric_font to an installed family. Fontconfig selected: ' .. (matched or 'unknown') }) end
  end
  if available('telescope', 'lua/telescope/init.lua') then health.ok('Telescope is available')
  else health.info('Telescope is optional; direct commands and native selection remain available') end
  if options.build_integration then
    if available('nvls', 'lua/nvls.lua') then health.ok('nvim-lilypond-suite is available for the configured build integration')
    else health.error('build_integration is enabled but nvim-lilypond-suite is unavailable', { 'Install and configure nvls before lilyp.setup(), or disable build_integration.' }) end
    tool('ffmpeg', 'suite audio conversion', false)
  else health.info('Suite build integration is disabled; core creation and curation work independently') end

  health.start('Lylip: external resources')
  local defaults = options.defaults
  if defaults.engraving_mode ~= 'default' then
    local template = defaults.engraving_template
    if type(template) == 'string' and vim.fn.filereadable(vim.fn.expand(template)) == 1 then
      health.ok('External engraving template: ' .. template)
    else health.error('Configured engraving template is missing: ' .. tostring(template), { 'Set defaults.engraving_template to a readable file, or use engraving_mode = "default".' }) end
  else health.info('Standard engraving uses no external template') end
  local inventory = defaults.instrument_inventory
  if inventory and inventory ~= '' then
    local ok, catalog = pcall(require('lilyp.instruments').load, inventory)
    if ok then
      health.ok('External instrument inventory: ' .. inventory)
      local font = catalog.font
      if type(font) == 'string' and vim.fn.filereadable(font) == 1 then health.ok('Audition SoundFont: ' .. font)
      else health.warn('No readable audition SoundFont in the inventory', { 'Install a SoundFont separately and set the inventory soundfont_path to its local path. Instrument selection still works.' }) end
    else health.error('Configured instrument inventory is invalid: ' .. tostring(catalog)) end
  else health.info('No instrument inventory configured; instrument names can be entered directly. Catalog browsing and audition require an external inventory.') end
  tool('fluidsynth', 'optional instrument audition', false)
  tool('mpv', 'optional instrument audition playback', false)
end

return M
