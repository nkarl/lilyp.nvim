local root=vim.fs.dirname(vim.fs.dirname(debug.getinfo(1,'S').source:sub(2)))
vim.opt.rtp:prepend(root)
local spec=require('lilyp.spec')
local fs=require('lilyp.fs')
local document=require('lilyp.project_document')
local diagnostic=require('lilyp.yaml_diagnostic')
local prefix='schema_version: 1\nkind: lilypond-score\n'
local function valid(text)
  local result=spec.inspect(text)
  assert(result.tag=='valid',result.diagnostics and tostring(result.diagnostics[1]))
  return document.assert_valid(result.document)
end
local function invalid(text,kind,path,line,column)
  local result=spec.inspect(text)
  assert(result.tag=='invalid' and not result.document,'Invalid document leaked usable values')
  local value=result.diagnostics[1]
  assert(value.kind==kind,tostring(value))
  assert(vim.deep_equal(value.path,path),vim.inspect(value))
  if line then assert(value.location.line==line,vim.inspect(value)) end
  if column then assert(value.location.column==column,vim.inspect(value)) end
  return value
end
local empty=valid('kind: lilypond-score\n')
assert(empty.schema_version==1 and empty.source.main=='main.ly' and empty.source.style=='style.ily')
assert(empty.staff_preset==nil)
assert(empty.presentation.tag=='absent' and empty.outputs.tag=='inherited' and #empty.sections==0)
assert(empty.text=='kind: lilypond-score\n','Normalization must retain exact original bytes')
local nullable=valid('kind: lilypond-score\nsource: null\nsections: null\noutputs: null\npresentation: null\n')
assert(nullable.source.main=='main.ly' and nullable.presentation.tag=='absent')
invalid('kind: [unterminated\n','Syntax',{})
invalid('# header\nkind: wrong\n','InvalidKind',{'kind'},2,7)
invalid(prefix..'source:\n  main: a.ly\n  main: b.ly\n','DuplicateKey',{'source','main'},5,3)
invalid('schema_version: 99\nkind: lilypond-score\n','UnsupportedVersion',{'schema_version'},1,17)
invalid(prefix..'source: [one]\n','InvalidShape',{'source'},3)
invalid(prefix..'source:\n  main: ../outside.ly\n','InvalidPath',{'source','main'},4,9)
invalid(prefix..'outputs:\n  location: somewhere\n','InvalidValue',{'outputs','location'},4,13)
invalid(prefix..'sections:\n  - id: a\n  - id: a\n','DuplicateId',{'sections',2,'id'},5,9)
invalid(prefix..'voices: [not-a-record]\n','InvalidShape',{'voices',1},3)
local base=prefix..'presentation:\n  schema_version: 1\n  style: style.ily\n  settings:\n'
invalid(base..'    staff_size: false\n','InvalidValue',{'presentation','settings','staff_size'},7,17)
invalid(base..'    nonexistent: 2\n','UnknownField',{'presentation','settings','nonexistent'},7)
invalid(prefix..'presentation:\n  schema_version: 99\n','UnsupportedVersion',{'presentation','schema_version'},4)
invalid(prefix..'sections: [{id: a, verses: false}]\n','InvalidValue',{'sections',1,'verses'},3)
invalid(prefix..'staff_preset: false\n','InvalidValue',{'staff_preset'},3)
local missing=invalid(prefix..'presentation:\n  schema_version: 1\n  style: style.ily\n','InvalidShape',{'presentation','settings'},4)
assert(missing.location.line==4,'A missing field must fall back to its containing mapping location')
local text=prefix..[[source:
  main: missing.ly
  custom: preserved
sections:
  - id: "intro.one"
    name: "Điệp khúc"
    source: sections/intro.ily
    arbitrary: keep
outputs:
  directory: legacy-output/
  custom: keep
presentation:
  schema_version: 2
  style: style.ily
  settings: {indent: 0, hide_tempo_note: false}
  sections:
    intro.one:
      layout: introLayout
      settings: {indent: 0, hide_tempo_note: false}
notes:
  date: 2020-01-01
  unusual: !!set {a: null}
]]
local value=valid(text)
assert(value.sections[1].name=='Điệp khúc' and value.section_ids['intro.one'])
assert(value.sections[1].arbitrary=='keep' and value.outputs.tag=='inherited')
assert(value.outputs.declarations.directory=='legacy-output/' and value.outputs.declarations.custom=='keep')
assert(value.presentation.value.settings.indent==0 and value.presentation.value.settings.hide_tempo_note==false)
assert(value.presentation.value.sections['intro.one'].settings.hide_tempo_note==false)
assert(value.presentation.value.settings.staff_size==nil,'No registry default may enter sparse declarations')
assert(diagnostic.path({'presentation','sections','intro.one','settings','indent'})=='presentation.sections["intro.one"].settings.indent')
-- Parsing/semantic validation do not touch the filesystem or require sources to exist.
local project=fs.stage({['score.yaml']=text})
local before=fs.snapshot(project)
valid(text)
assert(not pcall(require('lilyp.project').validate,project))
assert(vim.deep_equal(before,fs.snapshot(project)) and not vim.uv.fs_lstat(project..'/build'))
-- The exact-byte cache serves the raw compatibility adapter and typed reads.
local system,starts=vim.system,0
vim.system=function(...)starts=starts+1;return system(...)end
local cached_text=prefix..'# shared cache\nsource: {main: cached.ly}\n'
local raw=spec.call({action='read',text=cached_text})
local typed=spec.read(cached_text);typed.source.main='mutated';typed.locations[1].value.line=999
assert(spec.read(cached_text).source.main=='cached.ly' and starts==0)
local done=false
spec.read_async(cached_text,function(parsed,err)
  assert(not err and parsed.source.main=='cached.ly');done=true
end)
assert(not done and vim.wait(1000,function()return done end,5) and starts==0)
assert(spec.read(cached_text).locations[1].value.line==1)
vim.system=system
-- Unicode columns count characters, with CRLF preserved in the retained text.
local unicode='kind: lilypond-score\r\n"ghi chú": "giữ nguyên"\r\nsource: {main: ../bad.ly}\r\n'
invalid(unicode,'InvalidPath',{'source','main'},3,16)
local unicode_line='source: {note: "mẹ", main: ../bad.ly}'
local unicode_column=vim.str_utfindex(unicode_line,'utf-32',assert(unicode_line:find('../bad.ly',1,true))-1)+1
invalid(prefix..unicode_line..'\n','InvalidPath',{'source','main'},3,unicode_column)
-- Invalid syntax is a structured result on the typed async path and remains
-- a nil/error pair on the compatibility callback boundary.
local invalid_text='kind: lilypond-score\nsource: [broken\n'
done=false
spec.inspect_async(invalid_text,function(result,err)
  assert(not err and result.tag=='invalid' and result.diagnostics[1].kind=='Syntax');done=true
end)
assert(vim.wait(3000,function()return done end,5))
done=false
spec.call_async({action='read',text=invalid_text},function(value,err)
  assert(value==nil and type(err)=='string' and err:find('YAML helper failed',1,true));done=true
end)
assert(vim.wait(3000,function()return done end,5))
local explicit=valid(prefix..'outputs: {location: project}\n')
assert(explicit.outputs.tag=='explicit' and explicit.outputs.value=='project')
vim.fn.delete(project,'rf')
print('PASS: normalized project contracts, located syntax/semantic failures, sparse/false/zero values, descriptive metadata, filesystem separation, read-only behavior, and shared sync/async parse cache')
