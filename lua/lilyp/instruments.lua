local M = {}
local cache

function M.load(path)
  assert(type(path) == 'string' and path ~= '', 'Configure defaults.instrument_inventory for catalog browsing and audition; Enter edits instrument names directly without it.')
  path = vim.fn.expand(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then error('Instrument inventory not found: ' .. path, 0) end
  local stamp = table.concat({stat.size, stat.mtime.sec, stat.mtime.nsec}, ':')
  if cache and cache.path == path and cache.stamp == stamp then return cache end
  local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), '\n'))
  if not ok or type(data) ~= 'table' or type(data.categories) ~= 'table' or type(data.presets) ~= 'table' then
    error('Invalid categorized instrument inventory: ' .. path, 0)
  end
  local catalog = { path = path, stamp = stamp, font = data.soundfont_path, entries = {}, by_name = {}, categories = {}, category_options = {} }
  for _, category in ipairs(data.categories) do
    catalog.categories[category.id] = category
  end
  for _, entry in ipairs(data.presets) do
    if entry.kind == 'gm' and entry.bank == 0 and type(entry.lilypond_midi_instrument) == 'string' then
      assert(type(entry.program) == 'number' and entry.program == math.floor(entry.program) and entry.program >= 0 and entry.program <= 127, 'Invalid GM program number')
      assert(not catalog.by_name[entry.lilypond_midi_instrument], 'Duplicate GM instrument name')
      local category = assert(catalog.categories[entry.category], 'Missing instrument category')
      local sublabel
      for _, sub in ipairs(category.subcategories) do if sub.id == entry.subcategory then sublabel = sub.label end end
      assert(sublabel, 'Missing instrument subcategory')
      entry.category_label, entry.subcategory_label = category.label, sublabel
      catalog.entries[#catalog.entries + 1] = entry
      catalog.by_name[entry.lilypond_midi_instrument] = entry
    end
  end
  assert(#catalog.entries == 128, 'Expected 128 selectable General MIDI instruments')
  for _, category in ipairs(data.categories) do
    if vim.tbl_contains(vim.tbl_map(function(e) return e.category end, catalog.entries), category.id) then
      catalog.category_options[#catalog.category_options + 1] = {value = category.id, label = category.label}
    end
  end
  cache = catalog
  return catalog
end

function M.subcategories(catalog, category)
  local result = {{value = 'all', label = 'All types'}}
  local meta = catalog.categories[category]
  if meta then
    for _, sub in ipairs(meta.subcategories) do
      for _, entry in ipairs(catalog.entries) do
        if entry.category == category and entry.subcategory == sub.id then
          result[#result + 1] = {value = sub.id, label = sub.label}
          break
        end
      end
    end
  end
  return result
end

function M.filtered(catalog, category, subcategory, preferred, settings)
  local result = {}
  for _, entry in ipairs(catalog.entries) do
    if (not category or category == 'all' or entry.category == category)
      and (not subcategory or subcategory == 'all' or entry.subcategory == subcategory) then
      result[#result + 1] = entry
    end
  end
  local fallback = settings.subcategory_defaults and settings.subcategory_defaults[(category or '') .. '.' .. (subcategory or '')]
    or settings.category_defaults and settings.category_defaults[category]
  local wanted = preferred
  local has_preferred = false
  for _, e in ipairs(result) do if e.lilypond_midi_instrument == preferred then has_preferred = true end end
  if not has_preferred then wanted = fallback end
  for i, e in ipairs(result) do
    if e.lilypond_midi_instrument == wanted then table.insert(result, 1, table.remove(result, i)); break end
  end
  return result
end

function M.pick(settings, opts)
  local ok, catalog = pcall(M.load, settings.instrument_inventory)
  if not ok then opts.on_status(catalog); return end
  local entries = M.filtered(catalog, opts.category, opts.subcategory, opts.current, settings)
  if #entries == 0 then opts.on_status('No instruments match this category and type.'); return end
  local available = pcall(require, 'telescope.pickers')
  if not available then
    vim.ui.select(entries, {prompt = 'MIDI instrument', format_item = function(entry)
      return entry.lilypond_midi_instrument
    end}, function(entry) if entry then opts.on_select(entry) end end)
    return
  end
  local actions = require('telescope.actions')
  local action_state = require('telescope.actions.state')
  require('telescope.pickers').new({}, {
    prompt_title = 'FluidR3 GM instruments · Ctrl+A audition · Ctrl+X stop',
    finder = require('telescope.finders').new_table({results = entries, entry_maker = function(entry)
      local name = entry.lilypond_midi_instrument
      local text = string.format('%s / %s · %s · %s · GM %d', entry.category_label,
        entry.subcategory_label, name, entry.fluidr3_name, entry.display_program)
      return {value = entry, display = text, ordinal = text}
    end}),
    sorter = require('telescope.config').values.generic_sorter({}),
    previewer = false,
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        local selected = action_state.get_selected_entry()
        if not selected then return end
        require('lilyp.audition').stop()
        actions.close(prompt_bufnr)
        vim.schedule(function() opts.on_select(selected.value) end)
      end)
      local function audition()
        local selected = action_state.get_selected_entry()
        if selected then
          require('lilyp.audition').play(catalog, selected.value, opts.low, opts.on_status)
        end
      end
      for _, mode in ipairs({'i', 'n'}) do
        map(mode, '<C-a>', audition)
        map(mode, '<C-x>', function() require('lilyp.audition').stop(); opts.on_status('Audition stopped.') end)
      end
      vim.api.nvim_create_autocmd('BufWipeout', {buffer = prompt_bufnr, once = true, callback = function()
        require('lilyp.audition').stop()
      end})
      return true
    end,
  }):find()
end

return M
