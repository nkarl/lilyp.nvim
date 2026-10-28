local plugin = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)))
vim.opt.rtp:prepend(plugin)
local lsp = require('lilyp.lsp')
local fs = require('lilyp.fs')
local root = vim.fn.tempname() .. ' - Dâng'
vim.fn.mkdir(root .. '/sections', 'p')
fs.write(root .. '/score.yaml', 'schema_version: 1\nkind: lilypond-score\nsource:\n  main: entry.ly\n')
fs.write(root .. '/entry.ly', 'global = {}\n\\include "sections/part.ily"\n')
fs.write(root .. '/sections/part.ily', '\\global\n')
local before = fs.snapshot(root)
local buf = vim.fn.bufadd(root .. '/sections/part.ily')
local resolved
lsp.root_dir(buf, function(path) resolved = path end)
assert(vim.wait(5000,function()return resolved==root end,5))
local options = {lilypondShareDir='/example/share', includePaths={'/example/includes'}}
local config = {root_dir=resolved, init_options=options}
local params = {initializationOptions=options}
lsp.before_init(params, config)
assert(params.initializationOptions.projectMain == root .. '/entry.ly')
assert(config.init_options.projectMain == root .. '/entry.ly')
assert(vim.deep_equal(config.init_options.includePaths, {'/example/includes', root}))
assert(options.projectMain == nil and #options.includePaths == 1, 'Do not mutate shared defaults')
assert(config.init_options.lilypondShareDir == '/example/share')
assert(vim.deep_equal(before, fs.snapshot(root)), 'LSP discovery must not write the score')
-- Standalone scores get their own containing directory and no project context.
local standalone = vim.fn.tempname()
vim.fn.mkdir(standalone, 'p')
local single = vim.fn.bufadd(standalone .. '/single.ly')
lsp.root_dir(single, function(path) resolved=path end)
assert(resolved == standalone)
config = {root_dir=standalone, init_options={}}
lsp.before_init({}, config)
assert(config.init_options.projectMain == nil)
-- Invalid YAML must surface a warning, without claiming a different entry.
fs.write(root .. '/score.yaml', 'source: [broken\n')
local warnings = {}
local notify = vim.notify
vim.notify = function(message) warnings[#warnings+1] = message end
config = {root_dir=root, init_options={}}
lsp.before_init({}, config)
vim.wait(1000, function() return #warnings > 0 end)
vim.notify = notify
assert(config.init_options.projectMain == nil and #warnings == 1,vim.inspect({config=config,warnings=warnings}))
vim.fn.delete(root, 'rf')
vim.fn.delete(standalone, 'rf')
print('LSP project discovery checks passed')
vim.cmd('qa!')
