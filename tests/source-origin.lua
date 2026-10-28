local root=vim.fn.fnamemodify(debug.getinfo(1,'S').source:sub(2),':p:h:h')
vim.opt.rtp:prepend(root)
local fs=require('lilyp.fs')
local origin=require('lilyp.source_origin')
local index=require('lilyp.source_index')
local folder=vim.fn.tempname();vim.fn.mkdir(folder,'p')
local path=folder..'/tiếng Việt.ily'
local lines={
  "music = { c'4 r8 <b \\smallInnerNote g>8 \\tuplet 3/2 { c d e } }",
  'words = \\lyricmode { Người đã cất bước }',
  'custom = \\someUnknown c4',
  'quoted = "not a pitch"',
  'long = '..string.rep('á',180)..' c4 '..string.rep('đ',180),
  'text = c4 % </pre><img src=x onerror=bad()>',
}
local raw=table.concat(lines,'\r\n')..'\r\n';fs.write(path,raw)
local entries={}
local function add(line,needle)
  local byte=assert(lines[line]:find(needle,1,true))-1
  entries[#entries+1]={source=path,line=line,char=vim.str_utfindex(lines[line],'utf-32',byte),key=#entries,page=0}
  return #entries
end
local note=add(1,"c'4")
local rest=add(1,'r8')
local macro=add(1,'\\smallInnerNote')
local tuplet=add(1,'\\tuplet')
local brace=add(1,'{')
local word=add(2,'Người')
local custom=add(3,'\\someUnknown')
local quoted=add(4,'"')
local long=add(5,'c4')
local markup=add(6,'c4')
entries[#entries+1]={source=path,line=999,char=0,key=#entries,page=0}
local sources={[path]=vim.fn.sha256(raw)}
local descriptions=origin.capture(entries,sources,folder)
assert(descriptions[note].kind=='token' and descriptions[note].focus=="c'4")
assert(descriptions[rest].kind=='token' and descriptions[rest].focus=='r8')
assert(descriptions[macro].kind=='macro' and descriptions[macro].focus=='\\smallInnerNote')
assert(descriptions[tuplet].kind=='structural' and descriptions[brace].kind=='structural')
assert(descriptions[word].kind=='token' and descriptions[word].focus=='Người')
assert(descriptions[word].path=='tiếng Việt.ily' and descriptions[word].column==entries[word].char+1)
assert(descriptions[custom].kind=='macro' and descriptions[quoted].kind=='unknown')
assert(descriptions[long].truncated_left and descriptions[long].truncated_right)
assert(vim.str_utfindex(descriptions[long].before,'utf-32')==60)
assert(vim.str_utfindex(descriptions[long].after,'utf-32')==120)
assert(descriptions[markup].after:find('<img',1,true),'Source text was incorrectly treated as markup')
assert(not descriptions[#descriptions].available and descriptions[#descriptions].kind=='unknown')
assert(fs.read(path)==raw,'Inspection changed source bytes')
fs.write(path,raw..'% later saved edit\n')
assert(not pcall(origin.capture,entries,sources,folder),'Mismatched saved source was called a compiled preview')
assert(descriptions[word].focus=='Người','Captured source preview changed after a saved edit')
local main=folder..'/main.ly'
local generated=folder..'/main.ly.otter.scm'
fs.write(main,'{ c4 }\n');fs.write(generated,'generated editor helper')
assert(not index.snapshot(folder,main,{})[generated],'Unreferenced generated helper invalidates compiled source')
fs.write(main,'\\include "main.ly.otter.scm"\n{ c4 }\n')
assert(index.snapshot(folder,main,{})[generated],'Explicitly included dependency was ignored')
print('PASS: conservative origin classes, UTF-8/CRLF excerpts, bounded previews, frozen source hashes, literal markup, unknown positions, and generated-helper dependency handling')
