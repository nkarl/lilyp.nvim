local root=vim.fs.dirname(vim.fs.dirname(debug.getinfo(1,'S').source:sub(2)))
vim.opt.rtp:prepend(root)
local registry=require('lilyp.settings')
local model=require('lilyp.presentation_model')
local style=require('lilyp.style')
local regions=require('lilyp.source_regions')
local fs=require('lilyp.fs')
local plans=require('lilyp.edit_plan')
local sessions=require('lilyp.session')
local function fails(fn,needle)
  local ok,err=pcall(fn);assert(not ok,'Expected rejection')
  assert(not needle or tostring(err):find(needle,1,true),tostring(err))
end
local defaults={staff_size=13,lyric_size=1,hide_tempo_note=false,indent=8}
local local_values={staff_size=16,lyric_size=1,hide_tempo_note=false,indent=0}
local resolved=model.resolve(defaults,local_values,'section_a')
assert(resolved.values.indent==0 and resolved.values.hide_tempo_note==false)
assert(resolved.origins.lyric_size.scope=='section','Equal explicit overrides must remain explicit')
local_values.lyric_size=nil
local inherited=model.resolve(defaults,local_values,'section_a')
assert(inherited.values.lyric_size==1 and inherited.origins.lyric_size.scope=='global')
assert(defaults.staff_size==13 and model.resolve({}).values.staff_size==nil,'Registry defaults are not implicit project preferences')
fails(function()model.resolve(defaults,{paper='a4'},'section_a')end,'unsupported scope')
fails(function()registry.validate('staff_size',-1)end,'expected')
local converted=require('lilyp.creation_settings').canonical({lyric_italic=false,lyric_word_spacing=0,odd_verse_color='#000080'})
assert(converted.lyric_shape=='upright' and converted.word_spacing==0 and converted.odd_color=='#000080')
fails(function()require('lilyp.creation_settings').canonical({lyric_italic='false'})end,'true or false')
local text=[=[
% ignored = \layout { }
%{ fake = \layout { } %}
quoted = "other = \\layout { }"
#(define brace #\{)
baseLayout = \layout { }
aLayout = \layout {
  \baseLayout
  \context { \Lyrics \override LyricText.font-size = #2 }
}
bLayout = \layout {
  \baseLayout
  \context { \Lyrics \override LyricText.font-size = #5 }
}
]=]
local a=style.inspect_layout(text,'aLayout')
assert(a.entries.lyric_size.value==2 and text:sub(a.entries.lyric_size.location.first,a.entries.lyric_size.location.last)=='2')
assert(style.inspect(text).lyric_size.tag=='custom','Unbound duplicate assignments stay ambiguous')
local changed=style.render_layout(text,{lyric_size=3,staff_size=16,hide_tempo_note=false},a)
assert(style.inspect_layout(changed,'aLayout').entries.lyric_size.value==3)
assert(style.inspect_layout(changed,'aLayout').entries.staff_size.value==16)
assert(style.inspect_layout(changed,'aLayout').entries.hide_tempo_note.value==false)
local old_b,new_b=regions.layout(text,'bLayout'),regions.layout(changed,'bLayout')
assert(text:sub(old_b.first,old_b.close)==changed:sub(new_b.first,new_b.close),'Sibling layout changed')
fails(function()style.inspect_layout(text..'aLayout = \\layout {}','aLayout')end,'one explicit layout')
fails(function()style.inspect_layout(text,'guessedLayout')end,'one explicit layout')
fails(function()style.render_layout(text,{paper='letter'},a)end,'unsupported scope')
fails(function()style.render_layout(text..' ',{lyric_size=2},a)end,'Source changed')
local computed=text:gsub('font%-size = #2','font-size = #(if #t 2 1)')
fails(function()style.render_layout(computed,{lyric_size=3},style.inspect_layout(computed,'aLayout'))end,'custom scoped')
-- Sparse YAML stays sparse; observed source never becomes an implicit declaration.
local fixture=fs.stage(fs.snapshot(root..'/tests/fixtures'))
local metadata=fs.read(fixture..'/score.yaml')..'\npresentation:\n  schema_version: 1\n  style: style.ily\n  settings:\n    staff_size: 15\n'
fs.write(fixture..'/score.yaml',metadata)
local session=sessions.open(fixture)
assert(session.declared.staff_size==15 and session.declared.lyric_size==nil)
assert(session.observed.global.lyric_size.value==1 and session.resolved.values.lyric_size==nil)
session:set('staff_size',16)
local _,yaml=session:render()
local parsed=require('lilyp.spec').call({action='read',text=yaml})
assert(parsed.presentation.settings.staff_size==16 and parsed.presentation.settings.lyric_size==nil)
session:close()
fails(function()model.read({schema_version=1,style='style.ily',settings={},sections={}},'style.ily')end,'Unsupported presentation specification field')
-- One plan may contain three source files; recovery must not assume two.
local project=fs.stage(fs.snapshot(root..'/tests/fixtures'))
fs.write(project..'/auxiliary.ily','extraText = "A"\n')
fs.write(project..'/main.ly', '\\include "auxiliary.ily"\n'..fs.read(project..'/main.ly'):gsub('tagline = ##f','subtitle = \\extraText tagline = ##f'))
session=sessions.open(project);session:apply();session:close()
session=sessions.open(project);session:set('title_size',2)
local plan=session:plan()
plan.sources[#plan.sources+1]={path='auxiliary.ily',before=session.snapshot['auxiliary.ily'],after='extraText = "B"\n',reason='Requested subtitle text style fixture'}
plans.validate(session,plan)
local bad=vim.deepcopy(plan);bad.sources.extra=bad.sources[1]
fails(function()plans.validate(session,bad)end,'ordered list')
bad=vim.deepcopy(plan);bad.sources[1].path='../outside.ily'
fails(function()plans.validate(session,bad)end,'escapes')
bad=vim.deepcopy(plan);bad.sources[1].path='.git';bad.sources[1].before=nil
fails(function()plans.validate(session,bad)end,'Not a source destination')
assert(#plan.sources==3)
local before=fs.snapshot(project)
local transaction=require('lilyp.transaction')
local validated=transaction.validate(session,plan)
local changed_plan=vim.deepcopy(plan);changed_plan.sources[1].after=changed_plan.sources[1].after..'\n'
fails(function()transaction.publish(session,changed_plan,validated)end,'differs from the validated')
assert(vim.deep_equal(before,fs.snapshot(project)))
local atomic=fs.atomic
fs.atomic=function(path,...)
  if path==project..'/auxiliary.ily' then error('injected third source failure') end
  return atomic(path,...)
end
fails(function()transaction.publish(session,plan,validated)end,'Apply failed')
fs.atomic=atomic
assert(vim.deep_equal(before,fs.snapshot(project)),'Three-source rollback failed')
transaction.publish(session,plan,validated)
assert(fs.read(project..'/auxiliary.ily')=='extraText = "B"\n')
assert(fs.read(project..'/style.ily')==plan.sources[1].after)
session:close()
-- A scoped layout edit compiles and preserves actual MIDI bytes.
local compiled=vim.fn.tempname();vim.fn.mkdir(compiled,'p')
local score=[=[\version "2.26.0"
\include "styles.ily"
notes = { c'4 d' e' f' }
\score { << \new Voice = "a" \notes \new Lyrics \lyricsto "a" { One two three four } >> \layout { \aLayout } }
\score { << \new Voice = "b" \notes \new Lyrics \lyricsto "b" { One two three four } >> \layout { \bLayout } }
\score { \notes \midi {} }
]=]
fs.write(compiled..'/main.ly',score)
local function compile(styling,name)
  fs.write(compiled..'/styles.ily',styling)
  local r=vim.system({'lilypond','-I',compiled,'-o',compiled..'/'..name,compiled..'/main.ly'},{text=true}):wait(30000)
  local log=(r.stdout or '')..(r.stderr or '')
  assert(r.code==0 and not log:lower():find('warning:',1,true),log)
end
compile(text,'before');compile(changed,'after')
assert(fs.read(compiled..'/before.midi')==fs.read(compiled..'/after.midi'))
print('PASS: shared registry, explicit inheritance/provenance, scoped literal edits, sparse YAML, generic plans, three-file rollback, and real MIDI preservation')
