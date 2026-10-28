local root=vim.fn.fnamemodify(debug.getinfo(1,'S').source:sub(2),':p:h:h')
vim.opt.rtp:prepend(root)
local fs=require('lilyp.fs')
local index=require('lilyp.source_index')
local folder=vim.fn.tempname();vim.fn.mkdir(folder,'p')
local source=folder..'/tiếng Việt.ily'
local text='%{ Việt %} <c e g>4'
fs.write(source,text..'\n')
local byte=assert(text:find('c e',1,true))-1
local char=vim.str_utfindex(text,'utf-32',byte)
local uri='textedit://'..source..':1:'..char..':0'
local raw='<svg xmlns="http://www.w3.org/2000/svg" xmlns:z="http://www.w3.org/1999/xlink"><style><![CDATA[tspan { white-space: pre; }]]></style><g title="5 &gt; 3 &amp; 2"><a z:href="'..uri..'" onclick="bad()"><text>Người &amp; &#x1EA1; &#7841;</text></a><script>bad()</script><foreignObject><text>hidden</text></foreignObject><use z:href="#glyph"/><a href="https://example.org">external</a></g></svg>'
local pages,entries=require('lilyp.svg').index({raw,raw})
assert(#entries==2 and entries[1].key==0 and entries[2].key==1)
assert(entries[1].source==source and entries[1].line==1 and entries[1].char==char)
assert(pages[1]:find('5 &gt; 3 &amp; 2',1,true) and pages[1]:find('Người &amp; ạ ạ',1,true))
assert(pages[1]:find('xlink:href="#glyph"',1,true))
assert(not pages[1]:find('bad',1,true) and not pages[1]:find('hidden',1,true) and not pages[1]:find('https://',1,true))
assert(index.byte_column(entries[1])==byte)
assert(index.locate(entries,source,1,byte,2).key==1)
assert(not pcall(index.locate,entries,source,1,byte,3))
assert(not pcall(index.locate,entries,source,1,0,1))
for _,invalid in ipairs({'<svg xmlns="http://www.w3.org/2000/svg"><g></svg>','<!DOCTYPE svg><svg/>','<html/>','<svg xmlns="http://www.w3.org/2000/svg"/><svg xmlns="http://www.w3.org/2000/svg"/>'}) do
  assert(not pcall(require('lilyp.svg').index,{invalid}),'Invalid SVG accepted')
end
local hashes={[source]=vim.fn.sha256(fs.read(source))}
local cache={};assert(index.fresh(hashes,cache))
local original_read=fs.read
local reads=0
fs.read=function(path)reads=reads+1;return original_read(path)end
assert(index.fresh(hashes,cache) and reads==0,'Unchanged source was rehashed')
fs.write(source,text..' % edit\n');assert(not index.fresh(hashes,cache) and reads==1)
fs.read=original_read
-- Static eye tests share the Lua parser/launcher and need no Python process.
local path=folder..'/page.svg';fs.write(path,raw)
require('lilyp').setup({python='/not-used/python',score_viewer={browser={'/test/browser'}}})
local jobstart,arguments=vim.fn.jobstart,arg
local launched
vim.fn.jobstart=function(command,opts)
  assert(command[1]=='/test/browser' and opts.detach)
  local url=assert(command[2]:match('^%-%-app=(file://.*)$'))
  local html=fs.read(vim.uri_to_fname(url));assert(html:find('<svg',1,true))
  launched=true;return 123
end
arg={path};dofile(root..'/scripts/svg_preview.lua')
vim.fn.jobstart,arg=jobstart,arguments
assert(launched)
print('PASS: namespace-aware SVG XML, entity/CDATA handling, passive content, Unicode positions, repeated occurrences, malformed-document rejection, and cached source hashing')
