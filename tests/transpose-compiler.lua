-- The compiler is the oracle for relative/chord octaves and preserved timing.
local root=vim.fn.fnamemodify(debug.getinfo(1,'S').source:sub(2),':p:h:h')
vim.opt.rtp:prepend(root)
local fs=require('lilyp.fs')
local transpose=require('lilyp.transpose')
local fixtures={
  {"\\relative c' { c8 d e g e4 c d e }",'c8 d e g e4 c',"e'","{ e'8 fis' gis' b' gis'4 e' d' e' }"},
  {"\\relative c' { c4 d e f }",'d e',"b''","{ c'4 b'' cis''' f' }"},
  {"\\relative c' { <c e g>8 <d f a> r4 c2 }",'<c e g>8 <d f a>',"d'","{ <d' fis' a'>8 <e' g' b'> r4 c'2 }"},
  {"\\absolute { c'8~ c'8-. r8 \\tuplet 3/2 { d'16 e' f' } g'2 }","c'8~ c'8-. r8 \\tuplet 3/2 { d'16 e' f' }","des'","{ des'8~ des'8-. r8 \\tuplet 3/2 { ees'16 f' ges' } g'2 }"},
  {"\\relative c' { c4 <e g b> c, d }",'g b',"fis''","{ c'4 <e' fis'' ais''> c d }"},
  {"\\relative c' { c8 { d e } f g4 c }",'d e',"a","{ c'8 { a b } f' g'4 c'' }"},
  {"\\relative c' { c4 d e f }",'c4 d e',"ces","{ ces4 des ees f' }"},
  {"\\relative c' { c4-. d8-> e8-- f4-! g }",'c4-. d8-> e8-- f4-!',"d'","{ d'4-. e'8-> fis'8-- g'4-! g' }"},
}
local output=vim.fn.tempname();vim.fn.mkdir(output,'p')
local function compile_source(source,name)
  local path=output..'/'..name
  fs.write(path..'.ly',source)
  local result=vim.system({'lilypond','-o',path,path..'.ly'},{text=true}):wait(30000)
  local log=(result.stdout or '')..(result.stderr or '')
  assert(result.code==0 and not log:lower():find('warning:',1,true),log)
  assert(vim.fn.filereadable(path..'.pdf')==1)
  return fs.read(path..'.midi')
end
local function compile(music,name)
  return compile_source('\\version "2.26.0"\n\\score { \\new Staff '..music..' \\layout {} \\midi {} }\n',name)
end
for n,f in ipairs(fixtures) do
  local a,b=assert(f[1]:find(f[2],1,true))
  local actual=transpose.transform(f[1],a,b,f[3])
  assert(compile(actual,'actual-'..n)==compile(f[4],'expected-'..n),'MIDI differs from explicit absolute pitch/timing oracle: '..actual)
end
local scaffold=require('lilyp.scaffold')
local options=scaffold.defaults();options.preset='treble';options.lyrics=false;options.chords=false
local source=scaffold.prepare(options)
local first,last=assert(source:find('r1*4/4',1,true))
source=source:sub(1,first-1)..'c4 d e f'..source:sub(last+1)
local actual=transpose.transform(source,first,first+#'c4 d e f'-1,"d'")
local expected=source:sub(1,first-1)..'d4 e fis g'..source:sub(first+#'c4 d e f')
assert(compile_source(actual,'generated-actual')==compile_source(expected,'generated-expected'),'Generated score globals or instrument routing changed')
print('PASS: '..#fixtures..' transpositions and a generated score compile without warnings and match MIDI oracles')
