local root=vim.fs.dirname(vim.fs.dirname(debug.getinfo(1,'S').source:sub(2)))
vim.opt.rtp:prepend(root)
local fs=require('lilyp.fs')
local scaffold=require('lilyp.scaffold')
local sessions=require('lilyp.session')
local spec=require('lilyp.spec')
local model=require('lilyp.presentation_model')
local regions=require('lilyp.source_regions')
local function fails(fn,needle)
  local ok,err=pcall(fn);assert(not ok,'Expected rejection: '..tostring(needle))
  assert(not needle or tostring(err):find(needle,1,true),tostring(err))
end
local function read_spec(project)return spec.call({action='read',text=fs.read(project..'/score.yaml')}).presentation end
-- Hyphens are valid in LilyPond layout names and in the presentation schema.
-- Treat the reference as a literal name, not a Lua pattern repetition operator.
local hyphenated=fs.stage(fs.snapshot(root..'/tests/fixtures'))
fs.write(hyphenated..'/style.ily',fs.read(hyphenated..'/style.ily')..'\nrefrain-layout = \\layout { \\scoreLayout }\n')
fs.write(hyphenated..'/main.ly',fs.read(hyphenated..'/main.ly'):gsub('\\layout { \\scoreLayout }','\\layout { \\refrain-layout }'))
local named=sessions.open(hyphenated)
assert(require('lilyp.source_binding').available(named.section_styles.refrain),require('lilyp.source_binding').reason(named.section_styles.refrain))
local _,named_yaml=named:render();named:close();fs.write(hyphenated..'/score.yaml',named_yaml)
local named_before=fs.snapshot(hyphenated)
named=sessions.open(hyphenated);named:enable_section('refrain')
assert(named.section_drafts.refrain.layout=='refrain-layout' and named:plan().compare_pages)
assert(named:apply());named:close()
assert(fs.read(hyphenated..'/main.ly')==named_before['main.ly'])
assert(fs.read(hyphenated..'/style.ily')==named_before['style.ily'])
assert(read_spec(hyphenated).sections.refrain.layout=='refrain-layout')
named=sessions.open(hyphenated)
assert(require('lilyp.source_binding').available(named.section_styles.refrain) and #named.drift==0)
named:close()
scaffold.setup({title='Section presentation',composer='',preset='piano',key='c',mode='major',meter='4/4',
  tempo=84,paper='a4',engraving_mode='default'})
local options=scaffold.defaults()
options.title='Section presentation';options.project_directory=vim.fn.tempname();options.engraving_mode='default'
options.lyrics=true;options.chords=true;options.midi=true
options.sections={{id='section_a',name='A',type='refrain',verses=1,staff_preset='treble'},
  {id='section_b',name='B',type='verse',verses=2,staff_preset='satb'}}
local project=options.project_directory
require('lilyp.build').create(scaffold.render(options),options)
local main=fs.read(project..'/main.ly')
local n=0
main=main:gsub('\\layout { \\scoreLayout }',function()
  n=n+1
  if n==1 then return '\\layout { \\scoreLayout #(layout-set-staff-size 16) }' end
  return [=[\layout {
    \scoreLayout
    % Preserve local custom settings and this comment.
    \context { \Lyrics
      \override LyricText.font-size = #2
      \override VerticalAxisGroup.nonstaff-unrelatedstaff-spacing.padding = #1
    }
  }]=]
end)
assert(n==2);fs.write(project..'/main.ly',main)
local original=fs.snapshot(project)
local s=sessions.open(project)
assert(require('lilyp.source_binding').available(s.section_styles.section_a),require('lilyp.source_binding').reason(s.section_styles.section_a))
assert(require('lilyp.source_binding').available(s.section_styles.section_b),require('lilyp.source_binding').reason(s.section_styles.section_b))
assert(s:view('section_b').values.lyric_size==2)
assert(s.inspected.lyric_size.tag=='recognized','Section override must not disable shared controls')
s:close();assert(vim.deep_equal(original,fs.snapshot(project)))
s=sessions.open(project);assert(s:plan().compare_pages);s:apply();s:close()
assert(read_spec(project).schema_version==1,'Ordinary Save spec must not upgrade sections')
assert(fs.read(project..'/main.ly')==original['main.ly'])
assert(fs.read(project..'/style.ily')==original['style.ily'])
-- Explicit import of B moves only its layout, preserving every rasterized page and MIDI.
s=sessions.open(project);s:enable_section('section_b')
local before=fs.snapshot(project);local plan=s:plan()
assert(plan.compare_pages and #plan.sources==3)
assert(not s.section_drafts.section_a)
local preview=s:preview();assert(vim.fn.filereadable(preview.pdf)==1)
assert(vim.deep_equal(before,fs.snapshot(project)),'Preview wrote project')
local atomic=fs.atomic
fs.atomic=function(path,...)
  if path==project..'/main.ly' then error('injected layout-reference publication failure') end
  return atomic(path,...)
end
fails(function()require('lilyp.transaction').publish(s,plan,preview)end,'Apply failed')
fs.atomic=atomic
assert(vim.deep_equal(before,fs.snapshot(project)),'Layout migration publication failed to roll back')
require('lilyp.transaction').publish(s,plan,preview);s:close()
local yaml=read_spec(project)
assert(yaml.schema_version==2 and yaml.sections.section_b.settings.lyric_size==2 and not yaml.sections.section_a)
local styling=fs.read(project..'/style.ily')
assert(styling:find('Preserve local custom settings and this comment.',1,true))
assert(styling:find('nonstaff-unrelatedstaff-spacing.padding = #1',1,true))
assert(fs.read(project..'/sections/section_a.ily')==original['sections/section_a.ily'])
assert(fs.read(project..'/sections/section_b.ily')==original['sections/section_b.ily'])
s=sessions.open(project);assert(#s.drift==0 and #s:changes()==0)
assert(s:view('section_b').origins.lyric_size.scope=='section')
-- Shared changes update inherited values; explicit equal values, zero and false remain local.
s:set('lyric_size',3);s:set('hide_tempo_note',true);assert(s:view('section_b').values.lyric_size==2)
s:set('lyric_size',3,'section_a');s:set('indent',0,'section_a');s:set('hide_tempo_note',false,'section_a')
s:set('staff_size',17,'section_a');s:set('chord_size',1,'section_b');s:set('stanza_size',0)
local sources=s:render_sources()
local first=regions.layout(sources['style.ily'],'sectionALayout').first
assert(sources['style.ily']:find('StanzaNumber.font-size',1,true)<first,'Shared extensions must precede copied section layouts')
s:apply();assert(s.validated_migration and s.validated_migration.compare_pages,'Combined edit must validate migration separately');s:close()
s=sessions.open(project)
assert(#s.drift==0 and #s:changes()==0)
assert(s:view('section_a').values.indent==0 and s:view('section_a').values.hide_tempo_note==false)
assert(s:view('section_a').origins.lyric_size.scope=='section','Equal explicit override must remain explicit')
assert(s:view('section_b').values.lyric_size==2)
s:set('hide_tempo_note',true,'section_a')
assert(not s:plan().compare_pages,'False source override must not fall back through truthiness')
s:inherit('section_b','lyric_size');assert(s:view('section_b').values.lyric_size==3)
s:set('lyric_size',4);assert(s:view('section_b').values.lyric_size==4 and s:view('section_a').values.lyric_size==3)
s:apply();s:close()
s=sessions.open(project);assert(#s.drift==0)
assert(s:view('section_b').origins.lyric_size.scope=='global')
assert(read_spec(project).sections.section_b.settings.lyric_size==nil)
s:inherit('section_a','staff_size');s:inherit('section_a','indent');s:inherit('section_a','hide_tempo_note')
s:apply();s:close()
s=sessions.open(project);assert(#s.drift==0)
assert(s:view('section_a').values.staff_size==s.draft.staff_size)
fails(function()s:set('lyric_size',nil,'section_b')end,'A value is required')
fails(function()s:set('paper','letter','section_b')end,'section scope')
fails(function()s:inherit('section_b','paper')end,'section scope')
s:set('lyric_size',1,'section_b');s:revert();assert(#s:changes()==0);s:close()
-- An unlisted source literal remains an observation during unrelated edits.
local current_style=fs.read(project..'/style.ily')
local b_region=regions.layout(current_style,'sectionBLayout')
current_style=regions.patch(current_style,{{first=b_region.close,last=b_region.close-1,
  text='\n  \\context { \\Lyrics \\override StanzaNumber.font-size = #2 }\n'}})
fs.write(project..'/style.ily',current_style)
s=sessions.open(project)
assert(s:view('section_b').values.stanza_size==2 and s:view('section_b').overrides.stanza_size==nil)
s:set('lyric_size',4)
assert(s:render_sources()['score.yaml']:find('stanza_size: 0',1,true))
assert(read_spec(project).sections.section_b.settings.stanza_size==nil)
s:inherit('section_b','stanza_size');assert(#s:changes()==1,'Removing an observed override must create a change')
s:apply();s:close()
s=sessions.open(project);assert(s:view('section_b').values.stanza_size==0 and #s.drift==0);s:close()
-- Section references, duplicate binding names and schema errors are rejected without guessing.
local unknown=vim.deepcopy(yaml);unknown.sections.missing=unknown.sections.section_b
fails(function()model.read(unknown,'style.ily',{section_a=true,section_b=true})end,'Unknown presentation section')
local invalid=vim.deepcopy(yaml);invalid.sections.section_b.settings.paper='a4'
fails(function()model.read(invalid,'style.ily',{section_a=true,section_b=true})end,'unsupported scope')
invalid=vim.deepcopy(yaml);invalid.sections.section_b.unknown=true
fails(function()model.read(invalid,'style.ily',{section_a=true,section_b=true})end,'Unsupported section presentation field')
local ambiguous=fs.stage(original)
fs.write(ambiguous..'/main.ly',main..'\n\\score { \\staffMusic \\layout { \\scoreLayout } }\n')
s=sessions.open(ambiguous)
assert(s.section_styles.section_a.tag=='unavailable')
assert(vim.deep_equal(fs.snapshot(ambiguous),s.snapshot));s:close()
-- Source disagreement remains a conflict; it never replaces YAML.
local drifted=fs.stage(fs.snapshot(project))
fs.write(drifted..'/style.ily',fs.read(drifted..'/style.ily'):gsub('layout%-set%-staff%-size 16','layout-set-staff-size 18'))
-- Explicitly drift a declared local lyric size instead (A remains size 3).
fs.write(drifted..'/style.ily',fs.read(drifted..'/style.ily'):gsub('LyricText%.font%-size = #3','LyricText.font-size = #5'))
s=sessions.open(drifted);assert(#s.drift>0)
fails(function()s:set('lyric_size',1,'section_a')end,'differs from the YAML specification');s:close()
-- UI scope selection, import, inherited badges, unavailable page controls, reset and retained drafts.
for _,size in ipairs({{72,27},{120,40}}) do
  vim.o.columns,vim.o.lines=unpack(size)
  local ui=require('lilyp.ui').open(project)
  local snapshot=fs.snapshot(project)
  ui.select_scope('section_b');ui.switch_tab(3)
  assert(#ui.session:changes()==0)
  assert(ui.set('lyric_size',2));assert(ui.session:view('section_b').values.lyric_size==2)
  ui.select_scope('section_a');assert(ui.session:view('section_b').values.lyric_size==2)
  ui.select_scope('section_b');assert(ui.inherit('lyric_size'))
  local lines=vim.api.nvim_buf_get_lines(ui.buf,0,-1,false)
  assert(#lines==vim.api.nvim_win_get_height(ui.win) and table.concat(lines,'\n'):find('inherited',1,true))
  for _,line in ipairs(lines) do assert(vim.fn.strdisplaywidth(line)<=vim.api.nvim_win_get_width(ui.win)-2) end
  ui.select_scope(nil);assert(ui.session.draft.lyric_size==4)
  ui.session:revert();assert(#ui.session:changes()==0)
  ui.close();assert(vim.deep_equal(snapshot,fs.snapshot(project)))
end
print('PASS: section import/page parity, version-2 YAML, inheritance/reset, equal/false/zero overrides, source bindings, shared extensions, unchanged music/MIDI, conflicts, and scope UI')
print('Artifacts: '..project)
