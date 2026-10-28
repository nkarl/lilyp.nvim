local root=vim.fn.fnamemodify(debug.getinfo(1,'S').source:sub(2),':p:h:h')
vim.opt.rtp:prepend(root)
local fs=require('lilyp.fs')
local folder=vim.fn.tempname();vim.fn.mkdir(folder,'p')
local main=[=[\version "2.26.0"
melody = \relative c' {
  \key g \major \time 4/4 \tempo "Andante" 4 = 90
  \mark \markup \musicglyph "scripts.segno"
  \repeat volta 2 {
    c4\mf( d) e8[ fis] g4-> |
    \alternative { { c,2~ c2\fermata } { d1 } }
  }
  \bar "|."
  \textEndMark \markup \bold "D.C."
}
words = \lyricmode { \set stanza = "1." Người -- đã cất bước __ bình an }
harmonies = \chordmode { \repeat volta 2 { c1:maj7/e \alternative { { g1:7 } { c1 } } } }
\score {
  <<
    \new ChordNames { \harmonies }
    \new Voice = "melody" { \melody }
    \new Lyrics \lyricsto "melody" { \words }
  >>
  \layout {} \midi {}
}
]=]
local path=folder..'/main.ly';fs.write(path,main)
local result=vim.system({'lilypond','--svg','-o',folder..'/main',path},{text=true}):wait(30000)
assert(result.code==0 and not result.stderr:lower():find('warning:',1,true),result.stderr)
local svg=fs.read(folder..'/main.svg');local midi=fs.read(folder..'/main.midi')
local _,entries=require('lilyp.svg').index({svg})
local origins=require('lilyp.source_origin').capture(entries,{[path]=vim.fn.sha256(main)},folder)
local kinds,labels={},{}
for _,origin in ipairs(origins) do
  local symbol=origin.inspection.symbol
  if symbol then
    kinds[symbol.kind]=(kinds[symbol.kind] or 0)+1
    assert(require('lilyp.inspection').valid(origin.inspection))
  end
end
for _,kind in ipairs({'lyric','chord','key','meter','tempo','mark','dynamic','articulation','beam','slur','tie','alternative'}) do
  assert(kinds[kind],'No real compiler origin described for '..kind..': '..vim.inspect(kinds))
end
-- Stanza-label positions are covered in the source test; LilyPond does not
-- emit point-and-click links for the printed stanza number in this fixture.
assert(fs.read(path)==main and fs.read(folder..'/main.svg')==svg and fs.read(folder..'/main.midi')==midi,'Inspection changed source, SVG, or MIDI')
print('PASS: warning-free real SVG origins for lyrics, chords, signatures, tempo/marks, dynamics/articulations, beams/slurs/ties, and endings; unchanged source/SVG/MIDI')
