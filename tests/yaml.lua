local root=vim.fs.dirname(vim.fs.dirname(debug.getinfo(1,'S').source:sub(2)))
vim.opt.rtp:prepend(root)
local yaml=require('lilyp.yaml')
local spec=require('lilyp.spec')
local function parse(text)return yaml.parse(text).data end
local function invalid(text,kind)
  local value=spec.inspect(text)
  assert(value.tag=='invalid' and value.diagnostics[1].kind==kind,vim.inspect(value))
  return value.diagnostics[1]
end
-- Characterize YAML 1.1 resolution independently of managed block emission.
local values=parse([[values: [true, FALSE, Yes, OFF, yEs, nUlL, null, ~, 0, 012, 08, -0x10, 0b101, 1_000, 1:20, 1:99, 1.5, .5, 1.0e+3, 1e3, "false", '012']
]])
assert(vim.deep_equal(values.values,{true,false,true,false,'yEs','nUlL',vim.NIL,vim.NIL,0,10,'08',-16,5,1000,80,'1:99',1.5,.5,1000,'1e3','false','012'}),vim.inspect(values))
invalid('kind: lilypond-score\nschema_version: false\n','UnsupportedVersion')
for _,key in ipairs({'source','sections','voices','printed_order','outputs','presentation'}) do
  invalid('kind: lilypond-score\n'..key..': false\n',key=='presentation' and 'UnsupportedVersion' or 'InvalidShape')
end
local merged=parse([[kind: lilypond-score
one: &one {main: first.ly, style: shared.ily}
two: &two {main: second.ly, custom: keep}
source: {<<: [*one, *two], main: explicit.ly}
]])
assert(merged.source.main=='explicit.ly' and merged.source.style=='shared.ily' and merged.source.custom=='keep')
local alias=invalid('kind: lilypond-score\nbase: &base {main: ../escape.ly}\nsource: *base\n','InvalidPath')
assert(vim.deep_equal(alias.path,{'source','main'}) and alias.location.line==2 and alias.location.column==20,vim.inspect(alias))
local duplicate=invalid('kind: lilypond-score\nsource: {main: a.ly, main: b.ly}\n','DuplicateKey')
assert(vim.deep_equal(duplicate.path,{'source','main'}) and duplicate.location.column==22,vim.inspect(duplicate))
for _,text in ipairs({
  'kind: lilypond-score\nnotes: *missing\n',
  'kind: lilypond-score\nnotes: &cycle [*cycle]\n',
  'kind: lilypond-score\nnotes: !!python/object {}\n',
  'kind: lilypond-score\nnotes: !!python/object []\n',
  'kind: lilypond-score\nnotes: !custom value\n',
  'kind: lilypond-score\n---\nkind: lilypond-score\n',
  'kind: lilypond-score\nnotes: '..string.rep('[',258)..'0'..string.rep(']',258)..'\n',
}) do invalid(text,'Syntax') end
local block=parse('folded: >-\n  first\n  second\nliteral: |+\n  line\n\nquoted: "first\\nsecond"\n')
assert(block.folded=='first second' and block.literal=='line\n\n' and block.quoted=='first\nsecond')
local text='kind: lilypond-score\nnotes: {date: 2020-01-01, binary: !!binary SGk=, tags: !!set {a: null}, ordered: !!omap [{a: b}], pairs: !!pairs [{a: b}, {a: c}]}\n'
local output=spec.call({action='write-outputs',text=text,outputs={location='project',custom='false'}}).text
assert(output:sub(1,#text)==text and spec.read(output).outputs.value=='project')
local emitted=spec.call({action='write',text=text,presentation={schema_version=1,style='style.ily',settings={hide_tempo_note=false,indent=0,lyric_font='on'}}}).text
local presentation=spec.read(emitted).presentation.value.settings
assert(presentation.hide_tempo_note==false and presentation.indent==0 and presentation.lyric_font=='on')
-- Native errors cannot poison later parser instances or deferred delivery.
for _=1,30 do invalid('kind: [broken\n','Syntax');assert(spec.read('kind: lilypond-score\n').source.main=='main.ly') end
local request={action='read',text='kind: lilypond-score\nsource: {main: captured.ly}\n'}
local delivered=false
spec.call_async(request,function(value,err)assert(not err and value.source.main=='captured.ly');delivered=true end)
request.text='kind: wrong\n'
assert(not delivered and vim.wait(1000,function()return delivered end,5))
print('PASS: native YAML scalar/collection syntax, aliases/merges, located failures, false/null handling, passive tags, scoped writes, parser recovery, and deferred input snapshots')
