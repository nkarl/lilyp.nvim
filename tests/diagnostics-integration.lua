-- Optional cross-plugin regression: both checkouts are required, no host config.
local plugin=vim.fs.dirname(vim.fs.dirname(debug.getinfo(1,'S').source:sub(2)))
local diagnostics_path=vim.env.LILYP_DIAGNOSTICS_PLUGIN or vim.fs.dirname(plugin)..'/lilypond-diagnostics.nvim'
assert(vim.fn.isdirectory(diagnostics_path)==1,'Set LILYP_DIAGNOSTICS_PLUGIN to the diagnostics checkout')
vim.opt.rtp:prepend(plugin);vim.opt.rtp:prepend(diagnostics_path)
local fs=require('lilyp.fs')
local root=vim.fn.tempname();vim.fn.mkdir(root..'/sections','p')
fs.write(root..'/score.yaml','kind: lilypond-score\nsource:\n  main: score.ly\n')
fs.write(root..'/score.ly','\\version "2.26.0"\n\\include "sections/part.ily"\n\\score { \\music \\layout {} }\n')
fs.write(root..'/other.ly',fs.read(root..'/score.ly'))
fs.write(root..'/sections/part.ily',"music = { \\time 4/4 c'2 d'4 e' | }\n")
local buf=vim.fn.bufadd(root..'/sections/part.ily');vim.fn.bufload(buf);vim.bo[buf].filetype='lilypond'
local original=fs.snapshot(root)
local checker=require('lilypond_diagnostics')
local ns=vim.api.nvim_create_namespace('lilypond_diagnostics')
local system=vim.system;local parsers=0
vim.system=function(...)parsers=parsers+1;return system(...)end
package.loaded.nvls={get_file_infos=function()error('Build resolution in diagnostics')end,
 get_nvls_options=function()return {lilypond={options={}}}end}
local entries={}
local resolver=require('lilyp.integrations.diagnostics').resolve_entry
checker.setup({delay=30,resolve_entry=function(target,done)
 resolver(target,function(entry,err)entries[#entries+1]=entry;done(entry,err)end)
end})
local function trigger(event)vim.api.nvim_exec_autocmds(event or 'TextChangedI',{buffer=buf})end
vim.api.nvim_buf_set_lines(buf,0,-1,false,{"music = { \\time 4/4 c'2. d'4 e' | }"})
for _=1,20 do trigger()end
assert(parsers==0,'Edit events launched Python before debounce')
assert(vim.wait(5000,function()return #vim.diagnostic.get(buf,{namespace=ns})>0 end,5))
assert(parsers==1 and entries[1]==root..'/score.ly')
assert(vim.diagnostic.get(buf,{namespace=ns})[1].message:find('bar check failed',1,true))
vim.api.nvim_buf_set_lines(buf,0,-1,false,{"music = { \\time 4/4 c'2 d'4 e' | }"})
trigger('InsertLeave')
assert(vim.wait(5000,function()return checker.status().state=='idle' and #vim.diagnostic.get(buf,{namespace=ns})==0 end,5))
for _=1,20 do trigger('BufEnter');trigger();trigger('InsertLeave')end
assert(parsers==1,'Repeated edits/buffer entry reparsed unchanged YAML')
assert(vim.deep_equal(original,fs.snapshot(root)) and not vim.uv.fs_lstat(root..'/build'),'Diagnostics modified the source or prepared build output')
fs.write(root..'/score.yaml','kind: lilypond-score\nsource:\n  main: other.ly\n')
trigger('BufWritePost')
assert(vim.wait(5000,function()return entries[#entries]==root..'/other.ly' and checker.status().state=='idle' end,5))
assert(parsers==2,'Changed main entry was not reparsed exactly once')
checker.stop();assert(require('lilypond_diagnostics.runner').drain())
vim.system=system;vim.fn.delete(root,'rf')
print('PASS: cross-plugin async nested-source diagnostics, real unsaved warning/clear, zero warm Python launches, main-entry invalidation, and no output writes')
