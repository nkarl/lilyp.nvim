local root=vim.fn.fnamemodify(debug.getinfo(1,'S').source:sub(2),':p:h:h')
vim.opt.rtp:prepend(root)
local symbols=require('lilyp.symbol_context')
local music=require('lilyp.music_context')
local function analyzer(raw,files)
  files=files or {};files['/score/part.ily']=raw
  return symbols.analyzer(raw,music.guard(files))
end
local function at(raw,needle,files)
  local result=analyzer(raw,files)(assert(raw:find(needle,1,true)))
  assert(require('lilyp.inspection').valid(result))
  return result.symbol
end
local words=[=[words = \lyricmode {
  \set stanza = \markup { \bold "1." }
  \override LyricText.color = \evenVerseColor
  Người đã "cất bước" -- __ _ Chúa.
  \revert LyricText.color
  Bình an
  % ignored syllables and \p
}]=]
assert(at(words,'Người').text=='Người')
assert(at(words,'"cất bước"').text=='cất bước')
assert(at(words,'--').form=='hyphen')
assert(at(words,'__').form=='extender')
assert(at(words,'_ Chúa').form=='skip')
assert(at(words,'\\set').form=='stanza')
assert(at(words,'Bình').text=='Bình')
assert(not at(words,'LyricText.color'))
assert(not at(words,'ignored'))
local english='\\language "english"\n'..words
assert(at(english,'Người').text=='Người','Pitch-language guard blocked literal lyric text')
local unknown='words = \\lyricmode { before \\markup \\unknown after }'
assert(not at(unknown,'after'),'Unknown markup arguments were called lyric syllables')
local safe='words = \\lyricmode { "<img src=x onerror=bad()>" }'
assert(at(safe,'"<img').text=='<img src=x onerror=bad()>')
local long='words = \\lyricmode { "'..string.rep('ế',300)..'" }'
assert(vim.str_utfindex(at(long,'"').text,'utf-32')==240)
assert(pcall(vim.json.encode,at(long,'"')),'Truncation broke UTF-8')
local chords=[=[chords = \chordmode {
  \repeat volta 2 { d1*2/4:m/a | g:m | c4.:7 f8 |
    \alternative { { a2:m } { d:m } }
  }
}]=]
local d=at(chords,'d1')
assert(d.form=='name' and d.root=='D' and d.modifier=='m' and d.bass=='A')
assert(d.written=='d1*2/4:m/a')
assert(at(chords,'g:m').duration.notation=='1*2/4' and at(chords,'g:m').duration.inherited)
assert(at(chords,'c4.').modifier=='7')
assert(at(chords,'f8').modifier=='Major (default)')
assert(at(chords,'{ a2').ending==1)
assert(at(chords,'{ d:m').ending==2)
assert(not at('chords = \\chordmode { c4 \\mystery d }','c4'),'Unknown chord duration state was guessed')
assert(not at('\\language "deutsch"\nchords = \\chordmode { b4 }','b4').root)
local notation=[=[music = \relative c' {
  \key bes \major \time 3/4 \tempo "Vui hoạt" 4. = 82
  \clef "treble" \partial 8 c8\p( d)[ e~ e]-. f-> g_\fermata
  \tuplet 3/2 { a8 b c } \bar "|."
  \mark \markup \musicglyph "scripts.segno"
  \textEndMark \markup \fontsize #2 \bold "D.S."
}]=]
assert(at(notation,'\\key').key=='B♭ major')
assert(at(notation,'\\time').meter=='3/4')
local tempo=at(notation,'\\tempo')
assert(tempo.text=='Vui hoạt' and tempo.beat_unit=='4.' and tempo.bpm=='82')
assert(at(notation,'\\p(').kind=='dynamic')
assert(at(notation,'(').kind=='slur')
assert(at(notation,'[').kind=='beam')
assert(at(notation,'~').kind=='tie')
assert(at(notation,'-.').name=='Staccato')
assert(at(notation,'->').name=='Accent')
assert(at(notation,'\\fermata').name=='Fermata')
assert(at(notation,'\\tuplet').ratio=='3/2')
assert(at(notation,'\\mark').glyph=='Segno')
assert(at(notation,'\\textEndMark').mark:find('D.S.',1,true))
assert(at(notation,'\\bar').kind=='barline')
assert(at(notation,'\\partial').kind=='pickup')
local aliases={['/score/main.ly']='partKey = \\key fis \\minor'}
assert(at('music = { \\partKey c4 }','\\partKey',aliases).key=='F♯ minor')
assert(not at("partKey = \\key fis \\minor\npartKey = { c4 }\nmusic = { \\partKey d4 }",'\\partKey'))
assert(not at("p = { c4 }\nmusic = { \\p d4 }",'\\p'))
assert(not at('text = "\\p \\key g \\major"','\\p'))
assert(not at('#(display "x") % \\p\nmusic = { c4 }','\\p'))
assert(not at('#(list \\p) music = { c4 }','\\p'))
assert(not at('heading = \\markup { \\bold "hello" }','hello'))
-- Capture combines lexical symbols and musical metadata against one frozen
-- Unicode/CRLF snapshot, without moving the editor or modifying any bytes.
local fs=require('lilyp.fs');local folder=vim.fn.tempname();vim.fn.mkdir(folder,'p')
local path=folder..'/words.ily';local raw='% Việt\r\n'..words:gsub('\n','\r\n')..'\r\n'
fs.write(path,raw)
local entries={}
for _,needle in ipairs({'Người','\\set','__'}) do
  local byte=assert(raw:find(needle,1,true));local before=raw:sub(1,byte-1)
  local _,lines=before:gsub('\n','');local line=before:match('[^\n]*$'):gsub('\r$','')
  entries[#entries+1]={source=path,line=lines+1,char=vim.str_utfindex(line,'utf-32')}
end
local origins=require('lilyp.source_origin').capture(entries,{[path]=vim.fn.sha256(raw)},folder)
for _,origin in ipairs(origins) do assert(origin.inspection.tag=='supported' and origin.inspection.symbol.kind=='lyric') end
assert(fs.read(path)==raw)
print('PASS: Unicode lyrics/stanzas/alignment, literal chord spelling/bass/inherited duration, score marks, dynamics/articulations, structure, cross-file aliases, safe fallbacks, and frozen source capture')
