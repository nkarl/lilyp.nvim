local plugin=vim.fs.dirname(vim.fs.dirname(debug.getinfo(1,'S').source:sub(2)))
vim.opt.rtp:prepend(plugin)
local fs=require('lilyp.fs')
local sessions=require('lilyp.session')
local function fails(fn,needle)
  local ok,err=pcall(fn);assert(not ok,'Expected rejection')
  assert(tostring(err):find(needle,1,true),tostring(err))
end
local root=fs.stage(fs.snapshot(plugin..'/tests/fixtures'))
fs.write(root..'/style.ily',fs.read(root..'/style.ily'):gsub('Noto Serif','LilyPond Serif')..'\n\\paper { ragged-last-bottom = ##t }\n')
local s=sessions.open(root);local _,yaml=s:render();s:close();fs.write(root..'/score.yaml',yaml)
local clean=fs.snapshot(root)
local function drift()
  local copy=fs.stage(clean)
  local style=fs.read(copy..'/style.ily'):gsub('staff%-size 15','staff-size 18'):gsub('subtitleFontSize = #0','subtitleFontSize = #2')
    :gsub('sectionGap = \\markup \\vspace #3','sectionGap = \\markup \\vspace #1')
    :gsub('minimum%-distance = #2','minimum-distance = #4'):gsub('ragged%-last%-bottom = ##t','ragged-last-bottom = ##f')
    :gsub('ChordName%.font%-size = #0.5','ChordName.font-size = #0')
  fs.write(copy..'/style.ily',style);return copy
end
local project=drift();local before=fs.snapshot(project)
s=sessions.open(project);assert(#s:unresolved()==6)
fails(function()s:apply()end,'reconciled')
s:resolve_conflict('staff_size','yaml');assert(#s:unresolved()==5 and s.draft.staff_size==15)
s:resolve_conflict('staff_size','unresolved');assert(#s:unresolved()==6)
local opening=vim.deepcopy(s.draft)
local set=s.set
s.set=function(self,id,...)
  if id=='staff_size' then error('injected validation failure') end
  return set(self,id,...)
end
fails(function()s:resolve_all('source')end,'injected validation failure')
assert(vim.deep_equal(s.draft,opening) and not next(s.resolutions) and not s.reconciling,'Bulk resolution was not rolled back')
s.set=nil
assert(s:resolve_all('source')==6 and #s:unresolved()==0)
assert(s.draft.chord_size==0 and s.draft.ragged_last_bottom==false)
assert(vim.deep_equal(before,fs.snapshot(project)),'Decisions wrote project files')
local plan=s:plan();assert(plan.compare_pages and #plan.sources==1 and plan.sources[1].path=='score.yaml')
local preview=s:preview() -- Real PDF raster parity and MIDI equality are enforced.
assert(vim.deep_equal(before,fs.snapshot(project)),'Preview wrote project files')
require('lilyp.transaction').publish(s,plan,preview);s:close()
assert(fs.read(project..'/style.ily')==before['style.ily'])
s=sessions.open(project);assert(#s:unresolved()==0 and s.values.staff_size==18 and s.values.chord_size==0 and s.values.ragged_last_bottom==false);s:close()
-- Keeping YAML must actually publish source repairs even with no changed YAML values.
project=drift();s=sessions.open(project);assert(s:resolve_all('yaml')==6)
plan=s:plan();assert(not plan.compare_pages and #s:changes()==6)
assert(s:apply());s:close()
assert(fs.read(project..'/style.ily')==clean['style.ily'])
s=sessions.open(project);assert(#s:unresolved()==0);s:close()
-- Revert clears decisions; unrecognized expressions remain blocked even in bulk.
project=drift();s=sessions.open(project);s:resolve_all('source');s:revert()
assert(#s:unresolved()==6 and s.draft.staff_size==15);s:close()
fs.write(project..'/style.ily',fs.read(project..'/style.ily')..'\n#(set-global-staff-size 20)\n')
s=sessions.open(project);assert(s:resolve_all('source')==5 and #s:unresolved()==1)
fails(function()s:resolve_conflict('staff_size','yaml')end,'manual source correction')
fails(function()s:plan()end,'reconciled');s:close()
-- Dirty/external work still blocks publication of an otherwise resolved draft.
project=drift();s=sessions.open(project);s:resolve_all('source')
fs.write(project..'/style.ily',fs.read(project..'/style.ily')..'% newer external work\n')
fails(function()s:apply()end,'changed outside');s:close()
-- Configure uses its existing panels; both comparisons and decisions stay read-only.
project=drift();before=fs.snapshot(project)
vim.o.columns,vim.o.lines=180,48
local ui=require('lilyp.ui');local state=ui.configure({path=project})
assert(state.center_tab=='Changes' and state.comparison=='yaml')
assert(state.workspace_view.outline[1].label:find('(6)',1,true))
local target,row
for index,line in ipairs(state.center_lines) do
  local conflict=state.center_content_view.targets[line.original]
  if conflict then target,row=conflict,index;break end
end
state.center_cursor=row;state.focus='center'
assert(state.resolve('yaml'))
assert(state.session.resolutions[require('lilyp.reconciliation').key(target.id,target.section_id)]=='yaml','Center action resolved the wrong setting')
state.open_center()
assert(state.focus=='settings' and state.workspace_view.fields[state.selection].label=='Resolution')
assert(state.workspace_view.help:find('YAML:',1,true) and state.workspace_view.help:find('Saved source:',1,true))
assert(state.resolve('yaml',target.id,target.section_id))
assert(state.resolve_all('source'));assert(state.resolve('yaml','staff_size'))
state.compare('proposed')
local lines=table.concat(state.center_content_view.lines,'\n')
assert(lines:find('--- score.yaml',1,true) and lines:find('--- style.ily',1,true))
local draft=vim.deepcopy(state.session.resolutions)
ui.review(project);local resumed=ui.configure({path=project})
assert(resumed==state and vim.deep_equal(draft,state.session.resolutions),'Switching views lost decisions')
for _,size in ipairs({{72,27},{120,40},{180,48}}) do
  vim.o.columns,vim.o.lines=unpack(size);vim.api.nvim_exec_autocmds('VimResized',{})
  state.compare('yaml');state.redraw()
  for _,line in ipairs(vim.api.nvim_buf_get_lines(state.buf,0,-1,false)) do
    assert(vim.fn.strdisplaywidth(line)<=vim.api.nvim_win_get_width(state.win)-2)
  end
end
assert(vim.deep_equal(before,fs.snapshot(project)),'Panel navigation wrote project files')
fs.write(project..'/style.ily',before['style.ily']..'% source changed while reviewing\n')
assert(state.reload() and #state.session:unresolved()==6 and not next(state.session.resolutions))
state.close()
-- Local specified values use the same explicit reconciliation mechanism.
project=fs.stage(clean)
fs.write(project..'/main.ly',fs.read(project..'/main.ly'):gsub('\\layout { \\scoreLayout }','\\layout { \\scoreLayout \\context { \\Lyrics \\override LyricText.font-size = #2 } }',1))
s=sessions.open(project);s:enable_section('refrain');s:apply();s:close()
s=sessions.open(project);local entry=s.section_styles.refrain.observed.entries.lyric_size
local text=fs.read(project..'/style.ily');fs.write(project..'/style.ily',text:sub(1,entry.location.first-1)..'3'..text:sub(entry.location.last+1));s:close()
s=sessions.open(project);assert(s:conflict('lyric_size','refrain').actual==3)
s:resolve_conflict('lyric_size','source','refrain');assert(s:plan().compare_pages);s:apply();s:close()
s=sessions.open(project);assert(#s:unresolved()==0 and s:view('refrain').values.lyric_size==3);s:close()
-- Resolve global drift while importing a first section: migration must separately preserve the saved appearance.
project=drift();s=sessions.open(project);s:resolve_all('yaml');s:set('lyric_size',2,'refrain');s:preview();s:close()
print('PASS: YAML/source decisions, exact file diffs, source-adoption PDF parity, MIDI protection, global/local reconciliation, migration, stale/custom guards, read-only three-panel UI, and retained drafts')
