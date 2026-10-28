-- Real builds run directly from Lua with Python deliberately unavailable.
local root=vim.fn.fnamemodify(debug.getinfo(1,'S').source:sub(2),':p:h:h')
vim.opt.rtp:prepend(root)
local fs=require('lilyp.fs')
local app=require('lilyp')
local compiler=require('lilyp.compiler')
local project=fs.stage({['main.ly']=fs.read(root..'/tests/fixtures/main.ly'),['style.ily']=fs.read(root..'/tests/fixtures/style.ily'),
  ['sections/refrain.ily']=fs.read(root..'/tests/fixtures/sections/refrain.ily')})
app.setup({python='/not-used/python',build_location='project'})
vim.cmd.edit(vim.fn.fnameescape(project..'/main.ly'))
local context=require('lilyp.score_context').resolve()
local function compile(format,expected_failure)
  local artifact,failure,completion
  local deliveries={count=0}
  local process=app.compile({format=format,on_done=function(value)artifact=value end,on_error=function(err)failure=err end,on_complete=function(value)completion=value;deliveries.count=deliveries.count+1 end})
  assert(process.pid and vim.wait(15000,function()return completion~=nil end,10),'Build did not complete')
  if expected_failure then assert(failure and not artifact,failure);return failure,completion,deliveries end
  assert(artifact and not failure,failure)
  assert(completion.tag=='succeeded' and completion.publication=='published')
  return artifact,completion,deliveries
end
local before=fs.snapshot(project)
local svg=compile()
assert(svg.format=='svg' and #svg.pages==1 and not svg.log:lower():find('warning:',1,true))
assert(vim.fn.filereadable(context.pdf)==0,'Working build generated PDF')
local midi=fs.read(context.directory..'/main.midi')
local pointer=fs.read(context.manifest)
local manifest=vim.json.decode(fs.read(vim.json.decode(pointer).manifest))
assert(#manifest.entries>0 and #manifest.pages==1)
assert(manifest.entries[1].source:find(project,1,true)==1)
local pdf=compile('pdf')
assert(pdf.format=='pdf' and vim.fn.filereadable(pdf.pdf)==1)
assert(midi==fs.read(pdf.directory..'/main.midi') and midi==fs.read(context.directory..'/main.midi'),'PDF publishing changed playback')
assert(vim.deep_equal(before,fs.snapshot(project)),'Build changed source')
local pdf_bytes=fs.read(context.pdf)
local write=vim.uv.fs_write
vim.uv.fs_write=function()return nil,'Injected lock write failure'end
assert(not pcall(require('lilyp.build_artifacts').lock,context.directory))
vim.uv.fs_write=write
local release=require('lilyp.build_artifacts').lock(context.directory);release()
local original=fs.read(project..'/main.ly')
fs.write(project..'/main.ly','\\version "2.26.0"\n\\undefinedCommand\n')
compile(nil,true)
assert(fs.read(context.manifest)==pointer and fs.read(context.pdf)==pdf_bytes and fs.read(context.directory..'/main.midi')==midi)
fs.write(project..'/main.ly',original)
-- A failed manifest publication rolls back a MIDI file already replaced.
local part=project..'/sections/refrain.ily'
local part_original=fs.read(part)
fs.write(part,part_original:gsub('g4','gis4'))
local atomic=fs.atomic
fs.atomic=function(path,text)if path==context.manifest then error('Injected pointer failure')end;return atomic(path,text)end
local message,completion=compile(nil,true)
assert(message:find('Previous output restored',1,true) and completion.publication=='restored')
fs.atomic=atomic
assert(fs.read(context.manifest)==pointer and fs.read(context.directory..'/main.midi')==midi)
fs.write(part,part_original)
-- Successful output still reaches viewer/legacy observers if lock cleanup fails.
local artifacts=require('lilyp.build_artifacts')
local lock=artifacts.lock
artifacts.lock=function(directory)
  local unlock=lock(directory)
  return function()unlock();error('injected release failure')end
end
local cleanup_svg,cleanup_result=compile()
artifacts.lock=lock
assert(cleanup_svg and cleanup_result.tag=='succeeded' and cleanup_result.publication=='published' and #cleanup_result.cleanup==1)
pointer=fs.read(context.manifest)
-- A duplicate process callback must not publish or complete a second time.
local system=vim.system
vim.system=function(args,opts,callback)
  return system(args,opts,function(value)callback(value);callback(value)end)
end
local notify=vim.notify
vim.notify=function()error('injected notification failure')end
local _,_,deliveries=compile()
vim.system=system;vim.notify=notify
local drained=false;vim.schedule(function()drained=true end)
assert(vim.wait(1000,function()return drained end,5) and deliveries.count==1)
pointer=fs.read(context.manifest)
-- Publication rollback failure stays distinct from restored output.
fs.write(part,part_original:gsub('g4','gis4'))
local midi_writes=0
fs.atomic=function(path,text)
  if path==context.manifest then error('injected pointer failure') end
  if path==context.directory..'/main.midi' then
    midi_writes=midi_writes+1
    if midi_writes==2 then error('injected MIDI recovery failure') end
  end
  return atomic(path,text)
end
local partial_error,partial=compile(nil,true)
fs.atomic=atomic
assert(partial.publication=='partial' and partial_error:find('Rollback needs attention',1,true))
assert(fs.read(context.manifest)==pointer)
fs.write(context.directory..'/main.midi',midi);fs.write(part,part_original)
-- Reused chord sources expose distinct selectable instances.
local reused=project..'/reused.ly'
fs.write(reused,'\\version "2.26.0"\nphrase = \\relative c\' { <c e g>4 d e f }\n\\score { \\phrase \\layout {} }\n\\score { \\phrase \\layout {} }\n')
vim.cmd.edit(vim.fn.fnameescape(reused))
local repeated=compile()
local indexed=vim.json.decode(fs.read(vim.json.decode(fs.read(repeated.manifest)).manifest))
local chord=indexed.entries[1]
local line=vim.fn.readfile(reused)[chord.line]
local index=require('lilyp.source_index')
local column=vim.str_byteindex(line,'utf-32',chord.char)
assert(index.locate(indexed.entries,reused,chord.line,column,1).key~=index.locate(indexed.entries,reused,chord.line,column,2).key)
local pages=project..'/pages.ly'
fs.write(pages,'\\version "2.26.0"\n\\score { { c\'1 \\pageBreak d\'1 } \\layout {} }\n')
vim.cmd.edit(vim.fn.fnameescape(pages));assert(#compile().pages==2)
fs.write(pages,'\\version "2.26.0"\n{ c\'1 }\n');assert(#compile().pages==1)
-- Cancel and shutdown target the actual compiler group, including descendants
-- that ignore graceful termination, without publishing partial output.
vim.cmd.edit(vim.fn.fnameescape(project..'/main.ly'))
local fake=project..'/test-compiler.sh'
local pidfile=project..'/build/child.pid'
fs.write(fake,'#!/bin/sh\ntrap "" TERM\nsleep 60 &\nprintf "%s" "$!" > '..vim.fn.shellescape(pidfile)..'\nwait\n')
assert(vim.uv.fs_chmod(fake,448))
app.setup({python='/not-used/python',build_location='project',lilypond=fake})
local failed
local process=app.compile({on_error=function(err)failed=err end})
assert(vim.wait(3000,function()return vim.fn.filereadable(pidfile)==1 end,10))
local child=tonumber(fs.read(pidfile))
assert(compiler.cancel(context.main))
assert(vim.wait(5000,function()return failed end,10) and failed:find('cancelled',1,true))
local function dead(pid)
  local ok,status=pcall(fs.read,'/proc/'..pid..'/stat')
  return not ok or not status or status:match('^%d+ %b() Z')~=nil
end
assert(vim.wait(3000,function()return dead(process.pid) and dead(child)end,10),'Cancellation left compiler descendants running')
assert(fs.read(context.manifest)==pointer)
release=require('lilyp.build_artifacts').lock(context.directory);release()
assert(vim.uv.fs_unlink(pidfile))
local shutdown_result,shutdown_count=nil,0
process=app.compile({on_complete=function(value)shutdown_result=value;shutdown_count=shutdown_count+1 end})
assert(vim.wait(3000,function()return vim.fn.filereadable(pidfile)==1 end,10))
child=tonumber(fs.read(pidfile));compiler.shutdown()
assert(shutdown_count==1 and shutdown_result.tag=='cancelled')
assert(vim.wait(3000,function()return dead(process.pid) and dead(child)end,10),'Shutdown left compiler descendants running')
assert(fs.read(context.manifest)==pointer)
release=require('lilyp.build_artifacts').lock(context.directory);release()
print('PASS: Lua-only SVG/PDF builds, unchanged MIDI/source, failed-build retention, publication rollback, repeated chords, page shrink, and compiler-group cancellation/shutdown')
