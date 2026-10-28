-- Compiler/MIDI oracle for the inspector's resolved source pitches and durations.
local root=vim.fn.fnamemodify(debug.getinfo(1,'S').source:sub(2),':p:h:h')
vim.opt.rtp:prepend(root)
local fs=require('lilyp.fs')
local context=require('lilyp.music_context')
local reader=require('lilyp.music_reader')
local fixtures={
  "music = \\relative c' { c8. d16 e <g b d>4 r8 c,8 }",
  "music = \\relative c' { <c e g>8 <d f a> r4 c2 }",
  "music = \\absolute { c'4 \\tuplet 3/2 { d'8 \\times 2/3 { ees' f' g' } } a'4 }",
  "music = { r8. c'16 d' e' f'4 g' }",
}
fixtures[#fixtures+1]="music = \\fixed c' { <b g>4. <c' a>8 \\tuplet 3/2 { <d' b>4 <c' a> <b g> } }"
fixtures[#fixtures+1]="music = \\relative c' { c8 \\grace { g'16 a } b c4 r8 c }"
fixtures[#fixtures+1]="music = \\relative c' { c8 \\acciaccatura g8({ a4)} c4 r4 }"
fixtures[#fixtures+1]="music = \\relative c' { \\repeat volta 2 { c4 d \\alternative { { e2 } { a2 } } } }"
fixtures[#fixtures+1]="music = \\relative c' { r1*2/4 c d8 e f g }"
local folder=vim.fn.tempname();vim.fn.mkdir(folder,'p')
local function compile(music,name)
  local prefix=folder..'/'..name
  fs.write(prefix..'.ly','\\version "2.26.0"\n'..music..'\n\\score { \\new Staff { \\music } \\layout {} \\midi {} }\n')
  local result=vim.system({'lilypond','-o',prefix,prefix..'.ly'},{text=true}):wait(30000)
  local log=(result.stdout or '')..(result.stderr or '')
  assert(result.code==0 and not log:lower():find('warning:',1,true),log)
  return fs.read(prefix..'.midi')
end
for n,raw in ipairs(fixtures) do
  local analyze=context.analyzer(raw,context.guard({['/music.ly']=raw}))
  local patches={}
  for _,token in ipairs(reader.tokens(raw)) do
    if token.kind=='word' and reader.pitch(token.text) then
      local value=analyze(token.first)
      if value.tag=='supported' then
        value=value.symbol
        patches[#patches+1]={first=value.first,last=value.last,text=value.absolute_pitch}
      end
    end
  end
  assert(#patches>0)
  local oracle=require('lilyp.source_regions').patch(raw,patches)
  oracle=oracle:gsub('\\relative%s+[^%s{]+%s*','\\absolute '):gsub('\\fixed%s+[^%s{]+%s*','\\absolute ')
  assert(compile(raw,'actual-'..n)==compile(oracle,'absolute-'..n),'Inspector pitch mapping differs from compiler MIDI')
end
-- Explicit duration inheritance oracle: rests, dotted values, and chord suffixes.
assert(compile(fixtures[1],'duration-actual')==compile("music = \\absolute { c'8. d'16 e'16 <g' b' d''>4 r8 c'8 }",'duration-oracle'))
print('PASS: '..#fixtures..' inspector pitch mappings match absolute-pitch compiler MIDI; inherited dotted/rest/chord durations match an explicit oracle')
assert(compile(fixtures[6],'grace-duration-actual')==compile("music = \\absolute { c'8 \\grace { g'16 a'16 } b'16 c''4 r8 c''8 }",'grace-duration-oracle'))
assert(compile(fixtures[9],'scaled-duration-actual')==compile("music = \\absolute { r2 c'2 d'8 e'8 f'8 g'8 }",'scaled-duration-oracle'))
-- Aliases really cross include files, including the partial tweak application
-- whose compiler SVG origin points at the helper instead of the note spelling.
local main='keyAndTime = { \\key g \\major \\timeStyle \\time 4/4 }\nglobal = { \\keyAndTime }'
local style='timeStyle = \\numericTimeSignature\ninner = \\tweak font-size #-2 \\etc'
local part="music = \\fixed c' { \\global <b \\inner g>4 <c' \\inner a> <d' \\inner b> <g \\inner d> }"
fs.write(folder..'/globals.ily',main);fs.write(folder..'/style.ily',style);fs.write(folder..'/part.ily',part)
fs.write(folder..'/included.ly','\\version "2.26.0"\n\\include "style.ily"\n\\include "globals.ily"\n\\include "part.ily"\n\\score { \\new Staff { \\music } \\layout {} \\midi {} }')
local result=vim.system({'lilypond','--svg','-o',folder..'/included',folder..'/included.ly'},{text=true}):wait(30000)
assert(result.code==0 and not result.stderr:lower():find('warning:',1,true),result.stderr)
assert(fs.read(folder..'/included.midi')==compile("music = \\absolute { \\key g \\major \\time 4/4 <b' g'>4 <c'' a'> <d'' b'> <g' d'> }",'included-oracle'))
local sources={}
for _,file in ipairs({'included.ly','globals.ily','style.ily','part.ily'}) do sources[folder..'/'..file]=vim.fn.sha256(fs.read(folder..'/'..file)) end
local _,entries=require('lilyp.svg').index({fs.read(folder..'/included.svg')})
local origins=require('lilyp.source_origin').capture(entries,sources,folder)
local helpers=0
for _,origin in ipairs(origins) do
  if origin.focus=='\\inner' then
    assert(origin.inspection.tag=='supported' and origin.inspection.symbol.kind=='note' and origin.inspection.symbol.chord_member==2 and origin.inspection.symbol.mode=='fixed',vim.inspect(origin))
    helpers=helpers+1
  end
end
assert(helpers==4,'Real small notehead compiler origins were not resolved')
print('PASS: grace/scaled-duration MIDI oracles and cross-file fixed chords; all four real helper SVG origins resolve')
