local plugin=vim.fs.dirname(vim.fs.dirname(debug.getinfo(1,'S').source:sub(2)))
vim.opt.rtp:prepend(plugin)
local fs=require('lilyp.fs')
local adapter=require('lilyp.integrations.nvls')
require('lilyp').setup({build_location='project'})
adapter.enabled=true
local project=fs.stage(fs.snapshot(plugin..'/tests/fixtures'))
local output=vim.fn.tempname();vim.fn.mkdir(output,'p')
local main=project..'/main.ly'
local section=project..'/sections/refrain.ily'
local file={main=main,source_folder=project,folder=output,name='main',output_fm='pdf'}
local jobs,lookups,refreshed=0,0,0
package.loaded.nvls={
  get_file_infos=function()lookups=lookups+1;return file end,
  get_nvls_options=function()return {lilypond={options={include_dir={}}}} end,
}
package.loaded['nvls.utils']={
  ensure_midi_helper=function()return '/test/midi-helper.ly' end,
  format_include_dirs=function()return {'/test/includes'} end,
}
package.loaded['nvls.player']={refresh_if_open=function()refreshed=refreshed+1 end}
package.loaded['nvls.errors']={process=function()end}
local system=vim.system
local pending
vim.system=function(args,opts,done)
  if args[1]~='lilypond' then return system(args,opts,done) end
  jobs=jobs+1
  assert(args[2]=='--svg' and opts.cwd==project and opts.detach)
  assert(vim.tbl_contains(args,'-dinclude-settings=/test/midi-helper.ly'))
  assert(vim.tbl_contains(args,'/test/includes'))
  local output_base=args[assert(vim.fn.index(args,'-o'))+2]
  fs.write(output_base..'.svg','<svg xmlns="http://www.w3.org/2000/svg"><path d="M0 0"/></svg>')
  fs.write(output_base..'.midi','test MIDI')
  pending=done
  return {pid=99999999,kill=function()end}
end
local buffers={}
for _,path in ipairs({main,section}) do
  local buf=vim.fn.bufadd(path);vim.fn.bufload(buf);buffers[#buffers+1]=buf
  vim.api.nvim_buf_set_lines(buf,0,0,false,{'% unsaved transcription'})
end
local outside=vim.fn.tempname()..'.ly';fs.write(outside,'% unrelated saved source\n')
local outside_buf=vim.fn.bufadd(outside);vim.fn.bufload(outside_buf)
vim.api.nvim_buf_set_lines(outside_buf,0,0,false,{'% unrelated unsaved edit'})
vim.api.nvim_set_current_buf(buffers[2]);vim.bo.filetype='lilypond'

-- A locked Apply must stop F5 before buffer saves, output resolution, or jobs.
local before=fs.snapshot(project)
fs.write(project..'/.lilypond-curator.lock','another Apply')
local ok,err=pcall(adapter.compile)
assert(not ok and tostring(err):find('Apply',1,true),'Compilation ignored the Apply publication lock')
assert(jobs==0 and lookups==0 and vim.deep_equal(before,fs.snapshot(project)))
for _,buf in ipairs(buffers) do assert(vim.bo[buf].modified,'Locked compile saved a dirty source buffer') end
assert(fs.read(project..'/.lilypond-curator.lock')=='another Apply')
assert(vim.uv.fs_unlink(project..'/.lilypond-curator.lock'))

-- Without the lock, explicit F5 saves its project sources and schedules the same
-- suite command, while leaving an unrelated dirty score alone.
adapter.compile()
assert(jobs==1 and lookups==0 and refreshed==0)
assert(not pcall(adapter.compile),'Concurrent build was accepted')
pending({code=0,signal=0,stdout='Compiler finished',stderr=''})
assert(vim.wait(1000,function()return refreshed==1 end))
vim.system=system
for _,path in ipairs({main,section}) do assert(fs.read(path):find('unsaved transcription',1,true)) end
assert(vim.bo[outside_buf].modified and fs.read(outside)=='% unrelated saved source\n')
for _,buf in ipairs(buffers) do vim.api.nvim_buf_delete(buf,{force=true}) end
vim.api.nvim_buf_delete(outside_buf,{force=true})
vim.fn.delete(project,'rf');vim.fn.delete(output,'rf');vim.fn.delete(outside)
print('PASS: Apply lock blocks F5 before saving/resolution/jobs; ordinary compilation saves project sources, preserves unrelated edits, and refreshes playback')
