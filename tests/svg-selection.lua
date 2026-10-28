local root=vim.fn.fnamemodify(debug.getinfo(1,'S').source:sub(2),':p:h:h')
vim.opt.rtp:prepend(root)
local fs=require('lilyp.fs')
local folder=vim.fn.tempname();vim.fn.mkdir(folder,'p')
local source=[=[\version "2.26.0"
music = \relative c' { \time 4/4 \partial 4 c4 | <c e g>2 \tuplet 3/2 { d4 e f } | \break \grace { a16 b } g1 }
\score { << \new Staff \music \new Staff \music >> \layout {} }
\score { \new Staff \music \layout {} }
\score { \new Staff { \cadenzaOn c'4 d' e' \cadenzaOff } \layout {} }
\score { <<
  \new Staff \with { \consists Timing_translator } { \time 3/4 c'2. d' }
  \new Staff \with { \consists Timing_translator } { \time 2/4 c'2 d' }
>> \layout { \context { \Score \remove Timing_translator } } }
\score { \new Staff \music \midi {} }
]=]
fs.write(folder..'/main.ly',source)
local function compile(name,hook)
  local args={'lilypond','--svg','-o',folder..'/'..name}
  if hook then vim.list_extend(args,require('lilyp.svg_selection').arguments('svg',folder,false)) end
  args[#args+1]=folder..'/main.ly'
  local result=vim.system(args,{text=true}):wait()
  assert(result.code==0,result.stderr)
  assert(not result.stderr:lower():find('warning:',1,true),result.stderr)
  return fs.read(folder..'/'..name..'.svg'),fs.read(folder..'/'..name..'.midi')
end
local baseline,midi=compile('baseline',false)
local metadata,observed_midi=compile('metadata',true)
assert(midi==observed_midi,'Selection metadata changed MIDI')
assert(metadata:gsub('<g data%-measure=[^\n]+>\n(.-</a>)\n</g>\n','%1\n')==baseline,'Selection metadata changed engraving')
local pages=require('lilyp.svg').index({metadata})
assert(pages[1]:find('data-measure=',1,true),'Compiler metadata was stripped')
local counts={}
for key in metadata:gmatch('data%-measure="([^"]+)"') do counts[key]=(counts[key] or 0)+1 end
-- Two staves share a timing context; the second printed score has its own.
assert(counts['1:1:1/4:1']==12 and counts['2:1:1/4:1']==6,vim.inspect(counts))
assert(counts['1:1:-3/4:1']==2 and counts['2:1:-3/4:1']==1,'Pickup measure identity was lost')
assert(counts['3:1:0/1:3/4']==1 and counts['4:1:0/1:1/2']==1,'Independent timing contexts were merged')
local note_count=0;for _,count in pairs(counts) do note_count=note_count+count end
assert(note_count==34,'Cadenza acquired invented measure boundaries')
assert(fs.read(folder..'/main.ly')==source,'Read-only metadata changed source')
local corrupt=metadata:gsub('data%-measure="[^"]+"','data-measure="ambiguous"')
local invalid=require('lilyp.svg').index({corrupt})
assert(not invalid[1]:find('data-measure=',1,true),'Invalid compiler tuple was accepted')
assert(#require('lilyp.svg_selection').arguments('pdf',folder,true)==0,'PDF build acquired viewer settings')
vim.fn.delete(folder,'rf')
print('PASS: compiler-proven measure/pitch metadata, cross-staff and separate-score identity, pickup/tuplet/grace/system-break boundaries, cadenza rejection, tuple validation, unchanged SVG engraving/MIDI/source, and PDF exclusion')
