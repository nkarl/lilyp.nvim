local plugin=vim.fs.dirname(vim.fs.dirname(debug.getinfo(1,'S').source:sub(2)))
vim.opt.rtp:prepend(plugin)
local spec=require('lilyp.spec')
local function fails(request,needle)
  local ok,err=pcall(spec.call,request)
  assert(not ok,'Expected unsupported YAML to be rejected')
  assert(tostring(err):find(needle,1,true),tostring(err))
end
local prefix='kind: lilypond-score\n# Preserve the prefix.\n'
local suffixes={
  '"notes": ["keep this quoted metadata"]\n',
  "'notes': {custom: keep}\n",
  'ghi_chú: "giữ nguyên"\n',
  '# Preserve this unrelated comment.\n\n"notes": keep\n',
  'notes: |\n  presentation: literal text\n  outputs: literal text\n',
  'custom: &saved {text: preserved}\nnotes: *saved\n',
  '# Preserve trailing comments without another field.\n\n',
  '... # Preserve the document end.\n',
}
for _,key in ipairs({'presentation','outputs'}) do
  local value=key=='presentation' and {schema_version=1,settings={staff_size=16}} or {location='project',directory='build/'}
  local action=key=='presentation' and 'write' or 'write-outputs'
  for _,suffix in ipairs(suffixes) do
    local text=prefix..key..':\n  old: value\n'..suffix
    local result=spec.call({action=action,text=text,[key]=value}).text
    assert(result:sub(1,#prefix)==prefix,'YAML replacement changed the prefix')
    assert(result:sub(-#suffix)==suffix,'YAML replacement lost unrelated metadata: '..suffix)
    assert(vim.deep_equal(spec.call({action='read',text=result})[key],value),'Managed block did not round-trip')
  end
end

-- A managed-key-looking line inside a multiline quoted scalar is not a block.
local text='kind: lilypond-score\nnotes: "first line\npresentation: literal text\nlast line"\n'
local value={schema_version=1,settings={staff_size=16}}
local result=spec.call({action='write',text=text,presentation=value}).text
assert(result:sub(1,#text)==text,'Initialization rewrote a quoted scalar')

-- CRLF metadata stays CRLF outside and inside the rewritten block.
text='kind: lilypond-score\r\npresentation:\r\n  old: value\r\n"notes": keep\r\n'
result=spec.call({action='write',text=text,presentation=value}).text
assert(not result:gsub('\r\n',''):find('\n',1,true),'Replacement mixed CRLF and LF line endings')
assert(result:sub(-#'"notes": keep\r\n')=='"notes": keep\r\n')

-- Complex target keys and flow documents are read-only until explicitly migrated.
fails({action='write',text='kind: lilypond-score\n"presentation": {}\n',presentation=value},'ordinary top-level')
fails({action='write',text='{kind: lilypond-score, presentation: {}}\n',presentation=value},'ordinary top-level')
fails({action='read',text='kind: lilypond-score\nnotes: one\nnotes: two\n'},'Duplicate YAML key')

-- Repeated reads share one in-process parser result, with caller isolation.
local yaml=require('lilyp.yaml');local parse,starts=yaml.request,0
yaml.request=function(...)starts=starts+1;return parse(...)end
local system=vim.system
vim.system=function()error('YAML must not spawn a process')end
local request={action='read',text='kind: lilypond-score\nsource:\n  main: cached-entry.ly\n'}
local parsed=spec.call(request);parsed.source.main='caller mutation'
for _=1,10 do assert(spec.call(request).source.main=='cached-entry.ly') end
assert(starts==1,'Repeated unchanged YAML reads ran duplicate parsers')
local finished=false
spec.call_async(request,function(value,err)
  assert(not err and value.source.main=='cached-entry.ly');value.source.main='async caller mutation';finished=true
end)
assert(not finished,'A cached asynchronous read called back inline')
assert(vim.wait(1000,function()return finished end,5) and starts==1)
assert(spec.call(request).source.main=='cached-entry.ly')
local changed={action='read',text=request.text:gsub('cached%-entry','changed-entry')}
assert(spec.call(changed).source.main=='changed-entry.ly' and starts==2)
assert(spec.call(request).source.main=='cached-entry.ly' and starts==2)

-- Async cache misses warm the same read cache used by synchronous consumers.
local cold={action='read',text=request.text:gsub('cached%-entry','async-entry')}
finished=false
spec.call_async(cold,function(value,err)assert(not err and value.source.main=='async-entry.ly');finished=true end)
assert(vim.wait(5000,function()return finished end,5) and starts==3)
assert(spec.call(cold).source.main=='async-entry.ly' and starts==3)

-- Legacy interpreter options are inert; no configured Python can affect YAML.
local app=require('lilyp');local options=app.options()
app.setup({python='/nonexistent/lilyp-cache-test-python'})
assert(spec.call(request).source.main=='cached-entry.ly' and app.options().python==nil)
app.setup(options)
local invalid={action='read',text='kind: [invalid\n'}
local attempts=starts
fails(invalid,'YAML helper failed');fails(invalid,'YAML helper failed')
assert(starts==attempts+2,'Failed YAML requests were cached')
vim.system=system;yaml.request=parse
print('PASS: YAML metadata/newline preservation, unsupported/duplicate rejection, shared exact-byte reads, caller isolation, in-process parsing, and failure retries')
