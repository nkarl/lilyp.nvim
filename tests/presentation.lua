local root=vim.fs.dirname(vim.fs.dirname(debug.getinfo(1,'S').source:sub(2)))
vim.opt.rtp:prepend(root)
local plugin=require('lilyp')
local fs=require('lilyp.fs')
local sessions=require('lilyp.session')
local style=require('lilyp.style')
local fields=require('lilyp.fields')
local viewed
plugin.setup({viewer=function(pdf)viewed=pdf end})
local function fixture()return fs.stage(fs.snapshot(root..'/tests/fixtures'))end
local function fails(fn,needle)
  local ok,err=pcall(fn);assert(not ok,'Expected rejection: '..(needle or ''))
  if needle then assert(tostring(err):find(needle,1,true),tostring(err))end
end
local project=fixture()
-- Applying with loaded clean buffers must preserve boundary blank lines and
-- Neovim's file metadata, so the next ordinary save reproduces published bytes.
fs.write(project..'/style.ily','\n\n'..fs.read(project..'/style.ily')..'\n\n')
local original=fs.snapshot(project)
local s=sessions.open(project..'/sections/refrain.ily')
assert(not s.specified and s.values.staff_size==15 and s.values.lyric_size==1)
assert(vim.deep_equal(original,fs.snapshot(project)),'Opening wrote project files')
s:close();assert(vim.deep_equal(original,fs.snapshot(project)),'Closing wrote project files')
-- Existing historical backups are preserved, but new Apply operations do not
-- create or append persistent backup/journal records.
local historical=fixture()
vim.fn.mkdir(historical..'/backups','p');fs.write(historical..'/backups/keep.txt','old backup')
local preserved=sessions.open(historical);preserved:apply();preserved:close()
assert(fs.read(historical..'/backups/keep.txt')=='old backup')
local count=0;for _ in vim.fs.dir(historical..'/backups') do count=count+1 end
assert(count==1,'Apply created a new persistent backup')
s=sessions.open(project..'/main.ly')
local preview=s:preview()
assert(vim.fn.filereadable(preview.pdf)==1)
assert(vim.deep_equal(original,fs.snapshot(project)),'Preview wrote project files')
assert(s:apply())
assert(vim.fn.isdirectory(project..'/backups')==0,'Apply created persistent backups')
assert(fs.read(project..'/style.ily')==original['style.ily'],'Specification import changed style source')
assert(fs.read(project..'/main.ly')==original['main.ly'])
assert(fs.read(project..'/sections/refrain.ily')==original['sections/refrain.ily'])
assert(fs.read(require('lilyp.output').directory(project)..'/main.pdf'):find(project..'/sections/refrain.ily',1,true),
  'Published PDF source links must reference the real project')
assert(fs.read(project..'/score.yaml'):find('# Preserve this project description',1,true))
s:close()
local custom_metadata='\n# Preserve unrelated metadata after the presentation block.\n"ghi chú": {text: "giữ nguyên"}\n'
fs.write(project..'/score.yaml',fs.read(project..'/score.yaml')..custom_metadata)
s=sessions.open(project..'/main.ly');assert(s.specified and #s.drift==0)
s:set('staff_size',16);s:set('odd_color','#000080');s:set('top_margin',12)
s:set('stanza_size',0);s:set('row_spacing',5);s:set('page_count',1)
assert(#s:changes()==6)
local loaded={}
for _,relative in ipairs({'style.ily','score.yaml'}) do
  local buffer=vim.fn.bufadd(project..'/'..relative);vim.fn.bufload(buffer)
  loaded[relative]=buffer
end
vim.bo[loaded['style.ily']].modifiable=false
assert(s:apply());s:close()
assert(fs.read(project..'/score.yaml'):sub(-#custom_metadata)==custom_metadata,'Apply lost unrelated YAML metadata')
for _,relative in ipairs({'style.ily','score.yaml'}) do
  local buffer=loaded[relative]
  assert(not vim.bo[buffer].modified,'Apply left a refreshed buffer dirty')
  local published=fs.read(project..'/'..relative)
  local text=table.concat(vim.api.nvim_buf_get_lines(buffer,0,-1,false),'\n')..(vim.bo[buffer].endofline and '\n' or '')
  assert(text==published,'Apply refreshed buffer differs from published bytes: '..relative)
  assert(vim.bo[buffer].modifiable==(relative~='style.ily'),'Apply changed buffer modifiability')
  vim.bo[buffer].modifiable=true
  vim.api.nvim_buf_call(buffer,function()vim.cmd('silent write!')end)
  assert(fs.read(project..'/'..relative)==published,'Saving refreshed buffer changed published bytes')
  vim.api.nvim_buf_delete(buffer,{force=false})
end
assert(vim.fn.isdirectory(project..'/backups')==0,'Apply persisted backup files')
s=sessions.open(project..'/main.ly')
assert(s.values.staff_size==16 and s.values.top_margin==12 and s.values.odd_color=='#000080')
assert(fs.read(project..'/style.ily'):find('#(define curator-custom-value 42)',1,true),'Custom code was lost')
fails(function()s:set('staff_size',-1)end)
fails(function()s:set('odd_color','red')end)
assert(s.values.stanza_size==0 and s.values.row_spacing==5 and s.values.page_count==1)
-- A file changed outside the form: no stale write.
s:set('staff_size',17)
fs.write(project..'/sections/refrain.ily',original['sections/refrain.ily']..'\n% external edit\n')
fails(function()s:apply()end,'Project changed')
s:close()
-- Unsaved editor changes block preview rather than silently saving music.
s=sessions.open(project..'/main.ly')
local buf=vim.fn.bufadd(project..'/main.ly');vim.fn.bufload(buf)
vim.api.nvim_buf_set_lines(buf,0,0,false,{'% unsaved'})
fails(function()s:preview()end,'unsaved')
vim.bo[buf].modified=false;vim.api.nvim_buf_delete(buf,{force=true});s:close()
-- Drift in specified values is visible rather than overwritten.
fs.write(project..'/style.ily',fs.read(project..'/style.ily'):gsub('staff%-size 16','staff-size 18'))
s=sessions.open(project..'/main.ly');assert(#s.drift>0)
fails(function()s:set('staff_size',17)end,'differs from the YAML specification');s:close()
-- A custom later assignment makes the corresponding field unavailable.
local custom=fixture()
fs.write(custom..'/style.ily',fs.read(custom..'/style.ily')..'\n\\layout { \\context { \\Lyrics \\override LyricText.font-size = #(if #t 2 1) } }\n')
s=sessions.open(custom..'/main.ly');assert(s.inspected.lyric_size.tag=='custom');s:close()
-- An explicit handwritten override include blocks its affected control.
fs.write(custom..'/style-overrides.ily','\\layout { \\context { \\Lyrics \\override LyricText.font-shape = #\'upright } }\n')
s=sessions.open(custom..'/main.ly');assert(s.inspected.lyric_shape.tag=='custom');s:close()
-- Failed compile never publishes specification import or a partial style edit.
local broken=fixture()
fs.write(broken..'/sections/refrain.ily','this is not LilyPond source\n')
fs.write(broken..'/main.ly',fs.read(broken..'/main.ly')..'\n\\score {\n')
local before=fs.snapshot(broken);s=sessions.open(broken..'/main.ly')
fails(function()s:apply()end,'lilypond exited with status');assert(vim.deep_equal(before,fs.snapshot(broken)));s:close()
-- Publication failure after the first write restores the old style/spec.
local rollback=fixture();s=sessions.open(rollback..'/main.ly');s:apply();s:close()
s=sessions.open(rollback..'/main.ly');s:set('staff_size',17)
before=fs.snapshot(rollback)
local atomic,calls=fs.atomic,0
fs.atomic=function(path,...)
  if path==rollback..'/score.yaml' and calls==0 then calls=1;error('injected publication failure')end
  return atomic(path,...)
end
fails(function()s:apply()end,'Apply failed')
fs.atomic=atomic
assert(vim.deep_equal(before,fs.snapshot(rollback)),'Rollback failed');s:close()
-- Cosmetic settings cannot affect musical output through custom source coupling.
local coupled=fixture()
local main=fs.read(coupled..'/main.ly'):gsub('\\refrainMusic', '\\transpose c #(ly:make-pitch 0 titleFontSize 0) \\refrainMusic')
fs.write(coupled..'/main.ly',main)
s=sessions.open(coupled..'/main.ly');s:apply();s:close()
s=sessions.open(coupled..'/main.ly');s:set('title_size',2)
before=fs.snapshot(coupled)
fails(function()s:apply()end,'altered MIDI')
assert(vim.deep_equal(before,fs.snapshot(coupled)));s:close()
-- A lock from another Apply is not removed or overwritten.
local locked=fixture();s=sessions.open(locked..'/main.ly')
fs.write(locked..'/.lilypond-curator.lock','other operation')
fails(function()s:apply()end,'operation lock')
assert(fs.read(locked..'/.lilypond-curator.lock')=='other operation');s:close()

-- Five-tab UI opens/closes without writes and can inspect an specification import plan.
vim.o.columns,vim.o.lines=120,40
local ui=require('lilyp.ui').open(custom..'/main.ly')
for i=1,5 do ui.switch_tab(i) end
assert(ui.session.root==custom)
ui.close()
local ui_project=fixture()
ui=require('lilyp.ui').open(ui_project..'/main.ly')
assert(ui.apply())
assert(ui.session.specified)
assert(ui.set('lyric_size',0.5))
local ui_before=fs.snapshot(ui_project)
assert(ui.preview())
assert(viewed and vim.fn.filereadable(viewed)==1)
assert(vim.deep_equal(ui_before,fs.snapshot(ui_project)))
assert(ui.apply())
ui.close()
print('PASS: specification import, preview isolation, presentation edits, MIDI protection, custom code, conflicts, failed compile, rollback, and five-tab UI')

-- Shared appearance controls: import is inert, Apply preserves MIDI, and booleans survive YAML.
local appearance=fixture()
fs.write(appearance..'/sections/refrain.ily',fs.read(appearance..'/sections/refrain.ily'):gsub('\\repeat volta', '\\tempo \"Andante\" 4 = 72 \\mark \\default \\textMark \"Direction\" \\repeat volta'))
s=sessions.open(appearance..'/main.ly');s:apply();s:close()
s=sessions.open(appearance..'/main.ly')
local appearance_before=fs.snapshot(appearance)
local appearance_values={ragged_last_bottom=false,hide_tempo_note=true,indent=8,short_indent=6,
  metronome_color='#ff0000',rehearsal_color='#008800',text_mark_color='#0000ff'}
for id,value in pairs(appearance_values) do
  assert(s.inspected[id].tag=='available',id)
  s:set(id,value)
end
s:apply();s:close()
s=sessions.open(appearance..'/main.ly')
for id,value in pairs(appearance_values) do assert(s.values[id]==value,id..' did not round-trip') end
local appearance_text=fs.read(appearance..'/style.ily')
assert(appearance_text:find('tempoHideNote = ##t',1,true))
assert(not appearance_text:find('\\override tempoHideNote',1,true))
assert(fs.read(appearance..'/main.ly')==appearance_before['main.ly'])
assert(fs.read(appearance..'/sections/refrain.ily')==appearance_before['sections/refrain.ily'])
s:set('hide_tempo_note',false);s:set('ragged_last_bottom',true)
s:apply();s:close()
s=sessions.open(appearance..'/main.ly')
assert(s.values.hide_tempo_note==false and s.values.ragged_last_bottom==true and #s.drift==0)
fails(function()s:set('hide_tempo_note','false')end,'expected a boolean')
s:close()
-- Zero indent is valid existing LilyPond, and short-indent must not shadow indent.
local parsed=style.inspect('scoreLayout = \\layout { indent = 0 short-indent = 6\\mm }')
assert(parsed.indent.tag=='custom') -- unitless input remains custom, never appended over
assert(parsed.short_indent.value==6)
parsed=style.inspect('scoreLayout = \\layout { short-indent = 6\\mm }')
assert(parsed.indent.evidence.assignments==0 and parsed.indent.tag=='available')
parsed=style.inspect('\\paper { ragged-last-bottom = ##f }\n% ragged-last-bottom = ##t')
assert(parsed.ragged_last_bottom.value==false and parsed.ragged_last_bottom.tag=='recognized')
parsed=style.inspect('\\paper { ragged-last-bottom = ##f ragged-last-bottom = #(some-function) }')
assert(parsed.ragged_last_bottom.tag=='custom')
-- An external direction override disables only that control.
fs.write(appearance..'/extra.ily','\\layout { \\context { \\Score \\override Score.TextMark.color = "#123456" } }')
s=sessions.open(appearance..'/main.ly')
assert(s.inspected.text_mark_color.tag=='custom')
assert(s.inspected.metronome_color.tag=='recognized');s:close()
print('PASS: shared paper, indentation, direction colors, tempo visibility, boolean round-trips, and override preservation')


-- Specifications do not identify an owner. An arbitrary old owner never gates access.
local legacy=fixture()
s=sessions.open(legacy..'/main.ly');s:apply();s:close()
local specfile=fs.read(legacy..'/score.yaml')
assert(not specfile:find('owner:',1,true))
for _,old_owner in ipairs({'lilypond-curator.nvim','lilyp.nvim','some-other-editor'}) do
  fs.write(legacy..'/score.yaml',specfile:gsub('presentation:\n','presentation:\n  owner: '..old_owner..'\n'))
  local legacy_before=fs.snapshot(legacy)
  s=require('lilypond_curator.session').open(legacy..'/main.ly')
  assert(s.specified and #s.drift==0 and s.metadata_cleanup)
  assert(vim.deep_equal(legacy_before,fs.snapshot(legacy)),'Opening rewrote metadata')
  local cleanup_preview=s:preview()
  assert(vim.fn.filereadable(cleanup_preview.pdf)==1)
  assert(vim.deep_equal(legacy_before,fs.snapshot(legacy)),'Preview rewrote metadata')
  s:apply();s:close()
  assert(not fs.read(legacy..'/score.yaml'):find('owner:',1,true))
  assert(fs.read(legacy..'/style.ily')==legacy_before['style.ily'])
  s=sessions.open(legacy..'/main.ly')
  assert(not s.metadata_cleanup and s.specified and #s.drift==0)
  assert(s:apply()==nil);s:close()
end
-- YAML values remain authoritative when source values disagree.
fs.write(legacy..'/score.yaml',fs.read(legacy..'/score.yaml'):gsub('staff_size: 15','staff_size: 18'))
s=sessions.open(legacy..'/main.ly')
assert(s.values.staff_size==18 and s.draft.staff_size==18 and #s.drift==1)
fails(function()s:set('staff_size',17)end,'differs from the YAML specification')
fails(function()s:apply()end,'reconciled');s:close()
print('PASS: owner-free specifications, arbitrary legacy owner cleanup, unchanged appearance/MIDI, and YAML authority')

fails(function()require('lilyp.spec').call({action='write',text=original['score.yaml'],
  presentation={schema_version=1,owner='Lylip',settings={}}})end,'owner is not supported')
