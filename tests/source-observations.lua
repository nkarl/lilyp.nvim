-- Characterization of the decisions at the source-reading boundary. Keep these
-- cases stable while replacing the observation and binding representations.
local root=vim.fn.fnamemodify(debug.getinfo(1,'S').source:sub(2),':p:h:h')
vim.opt.rtp:prepend(root)
local style=require('lilyp.style')
local model=require('lilyp.presentation_model')
local scoped=require('lilyp.section_presentation')
local fs=require('lilyp.fs')
local observation=require('lilyp.source_observation')
local binding=require('lilyp.source_binding')
local function kind(e)return e.tag end
local function reason(e)return observation.reason(e)end
local function location(e)local at=observation.locate(e);return at.first,at.last end
local function font(e)return observation.font_override(e)end
local function assignments(e)return e.evidence.assignments end
local function inspect(text,id)return style.inspect(text)[id] end
local function rejects(fn)local ok=pcall(fn);assert(not ok)end
local literal=inspect('titleFontSize = #2','title_size')
assert(kind(literal)=='recognized' and literal.value==2 and assignments(literal)==1)
local a,b=location(literal);assert(('titleFontSize = #2'):sub(a,b)=='2')
assert(kind(inspect('titleFontSize = #(compute-title-size)','title_size'))=='custom')
assert(kind(inspect('titleFontSize = #2\ntitleFontSize = #3','title_size'))=='custom')
assert(kind(inspect('% titleFontSize = #2\ntext = "titleFontSize = #3"','title_size'))=='custom')
assert(kind(inspect('titleFontSize = #99999','title_size'))=='custom')
local absent=inspect('scoreLayout = \\layout {}','hide_tempo_note')
assert(kind(absent)=='available' and reason(absent):find('Not declared',1,true))
assert(kind(inspect('','hide_tempo_note'))=='custom')
assert(inspect('indent = 0\\mm','indent').value==0)
assert(inspect('tempoHideNote = ##f','hide_tempo_note').value==false)
local compound=inspect('system-system-spacing.basic-distance = #12\nsystem-system-spacing = #custom','system_distance')
assert(kind(compound)=='custom' and reason(compound):find('Compound',1,true))
local face=inspect('LyricText.fonts.serif = "Noto Serif"\nLyricText.font-name = "custom"','lyric_font')
assert(kind(face)=='custom' and font(face) and assignments(face)==1)
assert(model.import({lyric_font=face}).lyric_font==nil)
rejects(function()style.render('LyricText.font-name = "custom"',{lyric_font='Noto Serif'},{lyric_font=face})end)
local conflicts=model.compare({lyric_font='Other'},{lyric_font=face})
assert(#conflicts==1 and conflicts[1].status=='custom')
-- Bounded layouts preserve source spans and explicit zero/false values.
local source='aLayout = \\layout { \\scoreLayout \\context { \\Lyrics \\override LyricText.font-size = #0 } \\context { \\Score tempoHideNote = ##f } }'
local observed=style.inspect_layout(source,'aLayout')
assert(observed.entries.lyric_size.value==0 and observed.entries.hide_tempo_note.value==false)
a,b=location(observed.entries.lyric_size);assert(source:sub(a,b)=='0')
assert(kind(observed.entries.paper)=='custom')
local snapshot={['style.ily']='scoreLayout = \\layout {}', ['sections/a.ily']="partMusic = { c'4 }", ['main.ly']='\\score { \\partMusic \\layout { \\scoreLayout } }'}
local sections={{id='section_a',name='A',source='sections/a.ily'}}
local found,spans=scoped.discover(snapshot,sections,nil,'style.ily')
assert(found.section_a.tag=='inline')
assert(found.section_a.path=='main.ly' and spans['main.ly'])
local named=vim.deepcopy(snapshot)
named['style.ily']=named['style.ily']..'\naLayout = \\layout { \\scoreLayout }'
named['main.ly']='\\score { \\partMusic \\layout { \\aLayout } }'
found=scoped.discover(named,sections,nil,'style.ily')
assert(found.section_a.tag=='named' and found.section_a.layout=='aLayout')
local ambiguous=vim.deepcopy(snapshot);ambiguous['main.ly']=ambiguous['main.ly']..'\n'..ambiguous['main.ly']
found=scoped.discover(ambiguous,sections,nil,'style.ily')
assert(found.section_a.tag=='unavailable' and binding.reason(found.section_a):find('one printed score',1,true))
-- Additional assignments block local controls regardless of display wording;
-- source discovery/open/cancel remain read-only.
local folder=fs.stage(fs.snapshot(root..'/tests/fixtures'))
local extra='\n\\layout { \\context { \\Lyrics \\override LyricText.font-size = #2 } }\n'
fs.write(folder..'/sections/refrain.ily',fs.read(folder..'/sections/refrain.ily')..extra)
local before=fs.snapshot(folder)
local session=require('lilyp.session').open(folder)
assert(kind(session.inspected.lyric_size)=='custom' and reason(session.inspected.lyric_size):find('Additional styling',1,true))
assert(kind(session:view('refrain').entries.lyric_size)=='custom')
session:close();assert(vim.deep_equal(before,fs.snapshot(folder)))
print('PASS: characterization of literal/custom/absent decisions, diagnostic evidence, source spans, bindings, import/conflict/edit eligibility, and read-only opening')

-- Contract guarantees go beyond the old mutable statuses: rejected literals are
-- diagnostic only and cannot be mistaken for an editable recognized value.
assert(face.value==nil and face.location==nil and face.raw==nil and face.status==nil)
assert(face.cause.kind=='ExplicitFontFace' and face.evidence.location.display=='Noto Serif')
assert(compound.value==nil and compound.cause.kind=='CompoundSpacing')
assert(model.compare({lyric_font='Other'},{lyric_font=face})[1].actual=='Noto Serif')
for _,entry in pairs(style.inspect('titleFontSize = #2\nscoreLayout = \\layout {}')) do observation.assert_valid(entry) end
local invalid=vim.deepcopy(face);invalid.value='Noto Serif';rejects(function()observation.assert_valid(invalid)end)
invalid=vim.deepcopy(literal);invalid.tag='custom';rejects(function()observation.assert_valid(invalid)end)
rejects(function()observation.recognized('title_size',nil,literal.location,literal.evidence,literal.context)end)
rejects(function()observation.recognized('title_size',2,literal.location,{assignments=2})end)
rejects(function()observation.available('title_size',{kind='paper'},{assignments=1})end)
rejects(function()observation.custom('title_size',{kind='Future'},{assignments=0})end)
rejects(function()observation.with_context(literal,{scope='future'})end)
local blocked=observation.block(literal,observation.cause('AdditionalAssignment',{path='part.ily'}))
assert(blocked.value==nil and blocked.evidence.location.display=='2' and literal.tag=='recognized')
assert(not observation.editable(blocked) and observation.editable(literal) and observation.editable(absent))
local moved=observation.with_context(face,{path='style.ily'},17)
assert(moved.evidence.location.first==face.evidence.location.first+17)
assert(moved.evidence.font_override.first==face.evidence.font_override.first+17)
assert(face.context.path==nil)
local available=observed.entries.indent
assert(available.tag=='available' and available.insertion.kind=='section_layout' and available.insertion.at==observed.region.close)
assert(available.context.binding=='aLayout')
-- A late rejection of otherwise valid discovery loses editable payloads while
-- keeping enough evidence to explain and navigate the failure.
local multiple={
  ['style.ily']='scoreLayout = \\layout {}',
  ['a.ily']="aMusic = { c'4 }", ['b.ily']="bMusic = { d'4 }",
  ['main.ly']='\\score { << \\aMusic \\bMusic >> \\layout { \\scoreLayout } }',
}
local claimed=scoped.discover(multiple,{{id='a',source='a.ily'},{id='b',source='b.ily'}},nil,'style.ily')
for _,entry in pairs(claimed) do
  assert(entry.tag=='unavailable' and entry.cause.kind=='SharedPrintedScore')
  assert(entry.path==nil and entry.layout==nil and entry.observed==nil and entry.import_candidate==nil)
  assert(entry.evidence.printed and binding.path(entry)=='main.ly')
  binding.assert_valid(entry)
end
local saved_named=scoped.discover(named,sections,nil,'style.ily').section_a
assert(binding.available(saved_named))
invalid=vim.deepcopy(saved_named);invalid.tag='unavailable';rejects(function()binding.assert_valid(invalid)end)
invalid=vim.deepcopy(saved_named);invalid.import_candidate.extra=1;rejects(function()binding.assert_valid(invalid)end)
local rejected=binding.reject(saved_named,binding.cause('SharedLayout'))
assert(not binding.available(rejected) and binding.available(saved_named))
-- Text is presentation only. Rewording messages cannot re-enable blocked global
-- or local settings, or change which font overrides bypass family validation.
local original_reason=observation.reason
observation.reason=function(entry)return entry.tag=='custom' and 'Different explanatory wording' or original_reason(entry)end
session=require('lilyp.session').open(folder)
assert(session.inspected.lyric_size.cause.kind=='AdditionalAssignment')
assert(session:view('refrain').entries.lyric_size.cause.kind=='AdditionalAssignment')
assert(not observation.editable(session:view('refrain').entries.lyric_size))
session:close();observation.reason=original_reason
assert(vim.deep_equal(before,fs.snapshot(folder)))
print('PASS: validated observation/binding variants, preserved diagnostics, blocked edit authority, immutable transformations, and message-independent decisions')
