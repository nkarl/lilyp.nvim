local plugin=vim.fs.dirname(vim.fs.dirname(debug.getinfo(1,'S').source:sub(2)))
vim.opt.rtp:prepend(plugin)
local app,fs,output=require('lilyp'),require('lilyp.fs'),require('lilyp.output')
app.setup({})
local root=fs.stage(fs.snapshot(plugin..'/tests/fixtures'))
local before=fs.snapshot(root)
local directory=output.directory(root)
assert(directory:match('^/tmp/lilyp%-%d+/%x+$'))
local system,parsers=vim.system,0
vim.system=function(...)parsers=parsers+1;return system(...)end
for _=1,20 do assert(output.directory(root)==directory) end
vim.system=system
assert(parsers==0,'Unchanged output lookup repeatedly launched the YAML parser')
assert(vim.fn.isdirectory(directory)==0,'Resolution created output')
assert(output.directory(root..'/')==directory)
assert(output.directory(root..'-other')~=directory)
assert(output.directory(root,root..'/one.ly')~=output.directory(root,root..'/two.ly'))
assert(vim.deep_equal(before,fs.snapshot(root)))
assert(output.ensure(root)==directory)
assert(vim.uv.fs_lstat(root..'/build').type=='link')
assert(vim.uv.fs_readlink(root..'/build')==directory)
local ignore='/build/\n/backups/\n# keep custom rules\ncustom\n'
fs.write(root..'/.gitignore',ignore)
assert(output.ensure(root)==directory and fs.read(root..'/.gitignore')==ignore)
output.record(root)
assert(fs.read(root..'/.gitignore')=='/build\n/backups/\n# keep custom rules\ncustom\n')
assert(bit.band(vim.uv.fs_stat(directory).mode,511)==448)
assert(vim.fn.delete(directory,'d')==0)
assert(output.ensure(root)==directory,'Cleanup must recreate the target')
assert(vim.fn.delete(directory,'d')==0)
-- A temporary-directory symlink must never redirect generated output.
assert(vim.uv.fs_symlink(root,directory))
assert(not pcall(output.ensure,root))
assert(vim.uv.fs_unlink(directory))
assert(output.ensure(root)==directory)
-- A stale or unrelated link is repaired without modifying its target.
assert(vim.uv.fs_unlink(root..'/build'))
local previous=vim.fn.tempname();vim.fn.mkdir(previous,'p');fs.write(previous..'/keep','keep')
assert(vim.uv.fs_symlink(previous,root..'/build'))
assert(output.ensure(root)==directory and fs.read(previous..'/keep')=='keep')
assert(vim.uv.fs_readlink(root..'/build')==directory)

-- Real directories are preserved and converted into an explicit local spec only
-- during rebuild. Read-only resolution/inspection must not rewrite the YAML.
assert(vim.uv.fs_unlink(root..'/build'));vim.fn.mkdir(root..'/build','p')
fs.write(root..'/build/keep','keep')
local yaml=fs.read(root..'/score.yaml')..'outputs:\n  location: temporary\n  pdf: true\n  custom: keep\n'
fs.write(root..'/score.yaml',yaml)
assert(output.directory(root)==root..'/build')
assert(output.ensure(root)==root..'/build' and fs.read(root..'/score.yaml')==yaml)
do
  local inspection=require('lilyp.session').open(root)
  local preview=inspection:preview()
  assert(vim.fn.filereadable(preview.pdf)==1)
  inspection:close()
  assert(fs.read(root..'/score.yaml')==yaml,'Preview adopted local output on disk')
end
local buf=vim.fn.bufadd(root..'/score.yaml');vim.fn.bufload(buf)
vim.api.nvim_buf_set_lines(buf,0,0,false,{'# unsaved'})
assert(not pcall(output.record,root),'Build preference must preserve unsaved YAML')
assert(fs.read(root..'/score.yaml')==yaml)
vim.bo[buf].modified=false;vim.api.nvim_buf_delete(buf,{force=true})
output.record(root)
local local_spec=require('lilyp.spec').call({action='read',text=fs.read(root..'/score.yaml')})
assert(local_spec.outputs.location=='project' and local_spec.outputs.directory=='build/')
assert(local_spec.outputs.custom=='keep' and local_spec.outputs.pdf==true)
assert(fs.read(root..'/score.yaml'):find('# Preserve this project description',1,true))
assert(fs.read(root..'/build/keep')=='keep')
-- The recorded choice survives cleanup and an editor default change.
assert(vim.uv.fs_unlink(root..'/build/keep'));assert(vim.fn.delete(root..'/build','d')==0)
assert(output.ensure(root)==root..'/build' and vim.uv.fs_lstat(root..'/build').type=='directory')

-- An explicit local preference can replace a temporary link without moving or
-- deleting cached output. A later real-directory detection retains that choice.
local switched=fs.stage(fs.snapshot(plugin..'/tests/fixtures'))
local target=output.ensure(switched);fs.write(target..'/keep','cached')
fs.write(switched..'/score.yaml',fs.read(switched..'/score.yaml')..'outputs:\n  location: project\n')
assert(output.ensure(switched)==switched..'/build')
assert(vim.uv.fs_lstat(switched..'/build').type=='directory' and fs.read(target..'/keep')=='cached')

-- Build repair after moving the project uses its new canonical path hash.
local moved=fs.stage(fs.snapshot(plugin..'/tests/fixtures'))
local old_target=output.ensure(moved);fs.write(old_target..'/keep','old cache')
assert(vim.uv.fs_rename(moved,moved..'-moved'));moved=moved..'-moved'
local new_target=output.ensure(moved)
assert(new_target~=old_target and vim.uv.fs_readlink(moved..'/build')==new_target)
assert(fs.read(old_target..'/keep')=='old cache')

-- Local Apply uses the same output resolver and never persists artifact backups.
app.setup({build_location='project'})
local s=require('lilyp.session').open(root)
s:apply();s:close()
assert(vim.fn.filereadable(root..'/build/main.pdf')==1)
local old_pdf=fs.read(root..'/build/main.pdf')
local old_midi=fs.read(root..'/build/main.midi')
before=fs.snapshot(root)
s=require('lilyp.session').open(root);s:set('staff_size',17)
local atomic,calls=fs.atomic,0
fs.atomic=function(path,...)
  if path==root..'/build/main.pdf' and calls==0 then calls=1;error('injected output failure') end
  return atomic(path,...)
end
local ok,err=pcall(s.apply,s)
fs.atomic=atomic;s:close()
assert(not ok and tostring(err):find('Apply failed',1,true),tostring(err))
assert(vim.deep_equal(before,fs.snapshot(root)),'Source rollback failed')
assert(fs.read(root..'/build/main.pdf')==old_pdf and fs.read(root..'/build/main.midi')==old_midi,'Output rollback failed')
s=require('lilyp.session').open(root);s:set('staff_size',17)
assert(s:apply());s:close()
assert(vim.fn.isdirectory(root..'/backups')==0,'Apply persisted backups or journals')
assert(fs.read(root..'/build/main.midi')==old_midi,'Storage change altered MIDI')
assert(not pcall(app.setup,{build_location='elsewhere'}))
app.setup({})
print('PASS: stable output resolution, private targets, symlink repair, local-directory adoption/spec persistence, local Apply, source-only backups, and output-failure rollback')
