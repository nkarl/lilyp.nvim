local M = {}

local function absolute(path)
  local normalized = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(path), ':p'))
  return normalized == '/' and normalized or normalized:gsub('/$', '')
end

-- Compatibility alias; all consumers share project discovery.
function M.root(path)
  if not path or path=='' then return nil end
  return require('lilyp.project').root(path)
end

function M.directory(options)
  local destination = vim.trim(options.project_directory or '')
  local parent = options.project_parent or vim.fn.getcwd()
  if destination == '' then
    local title = vim.trim(options.title or 'Untitled'):gsub('[/\\:%c]', '_')
    if title == '' or title == '.' or title == '..' then title = 'Untitled' end
    destination = title
  end
  destination = vim.fn.expand(destination)
  if not vim.startswith(destination, '/') then destination = vim.fs.joinpath(parent, destination) end
  return absolute(destination)
end

local function yaml(value)
  -- JSON quoted strings are valid YAML scalars, including Unicode and embedded punctuation.
  return vim.json.encode(value)
end

function M.spec(options)
  local templates = require('lilyp.scaffold')
  local sections=require('lilyp.sections')
  templates.preset(options.preset)
  local lines = {
    '# Descriptive score intentions. Edit LilyPond source to change the music.',
    '# source.main selects the entry point; musical source remains authoritative.',
    'schema_version: 1',
    'kind: lilypond-score',
    'title: ' .. yaml(options.title),
    'subtitle: ' .. yaml(options.subtitle or ''),
    'composer: ' .. yaml(options.composer or ''),
    'language: ' .. (options.lyrics_language ~= '' and options.lyrics_language and yaml(options.lyrics_language) or 'null'),
    'staff_preset: '..yaml(options.preset),
    'key: '..yaml(options.key), 'mode: '..yaml(options.mode), 'meter: '..yaml(options.meter),
    'source:', '  main: main.ly', '  style: style.ily', '  optional_sections: sections/',
    'outputs:', '  location: '..require('lilyp.output').location(), '  directory: build/', '  pdf: true', '  midi: ' .. tostring(options.midi),
    'voices:',
  }
  for _, track in ipairs(sections.tracks(options)) do
    vim.list_extend(lines, {'  - id: ' .. yaml(track.id), '    role: ' .. yaml(track.role),
      '    playback_role: '..yaml(track.playback_role), '    instrument: ' .. yaml(track.instrument)})
  end
  if options.chords then
    vim.list_extend(lines, {'  - id: chords', '    role: chord accompaniment',
      '    instrument: ' .. yaml(options.chord_instrument or 'acoustic grand')})
  end
  lines[#lines+1]='sections:'
  local plan=sections.plan(options)
  local order={}
  for _,section in ipairs(plan) do
    order[#order+1]=yaml(section.id)
    vim.list_extend(lines,{'  - id: '..yaml(section.id),'    type: '..yaml(section.type),
      '    name: '..yaml(section.name),'    source: '..yaml(sections.filename(section)),
      '    verses: '..tostring(sections.lyric_rows(options,section))})
    for _,id in ipairs({'key','mode','meter'}) do
      if section[id]~=nil then lines[#lines+1]='    '..id..': '..yaml(section[id]) end
    end
    if section.lyrics~=nil then lines[#lines+1]='    lyrics: '..tostring(section.lyrics) end
    if section.staff_preset then lines[#lines+1]='    staff_preset: '..yaml(section.staff_preset) end
    lines[#lines+1]='    voices:'
    local opts=sections.options(options,section)
    for _,staff in ipairs(templates.preset(opts.preset).staves) do
      vim.list_extend(lines,{'      - id: '..yaml(staff.id),
        '        playback_voice: '..yaml(sections.playback_id(options,staff)),
        '        instrument: '..yaml(templates.instrument(opts,staff.id))})
    end
    vim.list_extend(lines,{'    repeat_intent: null','    verse_endings: []'})
  end
  vim.list_extend(lines, {'printed_order: ['..table.concat(order,', ')..']',
    'playback:', '  section_order: ['..table.concat(order,', ')..']', '  continuous: true',
    'engraving:', '  expected_pages: null # Set a target when the layout is known.',
    '  small_inner_noteheads: null',
    '  volta_colors_match_verses: true',
    'validation:', '  warning_free: true', '  preserve_pitches_and_rhythms: true',
    'notes: []',
  })
  return table.concat(lines, '\n') .. '\n'
end

local function write_new(path, contents)
  local fd, err = vim.uv.fs_open(path, 'wx', 420)
  assert(fd, err)
  local written, failure = vim.uv.fs_write(fd, contents)
  vim.uv.fs_close(fd)
  assert(written == #contents, failure or ('Incomplete write: ' .. path))
end

function M.create(source, options)
  local sections=require('lilyp.sections')
  local section_error=sections.validate(sections.plan(options))
  assert(not section_error,section_error)
  local specification=M.spec(options)
  local root = M.directory(options)
  assert(not vim.uv.fs_lstat(root), 'Destination already exists; choose a new project directory: ' .. root)
  vim.fn.mkdir(vim.fs.dirname(root), 'p')
  local ok, err = vim.uv.fs_mkdir(root, 493)
  assert(ok, err)
  -- Never delete a partially created project on failure; surface its path for recovery.
  for _, name in ipairs({'sections'}) do
    local made, failure = vim.uv.fs_mkdir(vim.fs.joinpath(root, name), 493)
    assert(made, failure)
  end
  local assembled,section_files=sections.split(source,options)
  local main, styling = require('lilyp.scaffold').split_style(assembled)
  for relative,text in pairs(section_files) do write_new(vim.fs.joinpath(root,relative),text) end
  write_new(vim.fs.joinpath(root, 'main.ly'), main)
  write_new(vim.fs.joinpath(root, 'style.ily'), styling)
  write_new(vim.fs.joinpath(root, 'score.yaml'), specification)
  write_new(vim.fs.joinpath(root, '.gitignore'), '/build\n/backups/\n*.otter.scm\n')
  require('lilyp.output').ensure(root)
  return vim.fs.joinpath(root, 'main.ly')
end

-- Compatibility entry points; optional suite behavior belongs to its adapter.
function M.setup() return require('lilyp.integrations.nvls').setup() end
function M.compile() return require('lilyp.integrations.nvls').compile() end
function M.attach(buf) return require('lilyp.integrations.nvls').attach(buf) end
return M
