local root=vim.fn.fnamemodify(debug.getinfo(1,'S').source:sub(2),':p:h:h')
vim.opt.rtp:prepend(root)
local music=require('lilyp.music_context')
local contract=require('lilyp.inspection')
local function unwrap(result)assert(contract.valid(result));return result.symbol or result end
local function inspect(raw,needle)
  return unwrap(music.analyzer(raw,music.guard({['/score/main.ly']=raw}))(assert(raw:find(needle,1,true))))
end
local relative="music = \\relative c' { c8. d16 e <g b d>4 r8 c,8 }"
local c=inspect(relative,'c8.')
assert(c.kind=='note' and c.pitch=='C4' and c.midi==60 and c.duration.notation=='8.' and not c.duration.inherited)
local e=inspect(relative,'e <')
assert(e.pitch=='E4' and e.duration.notation=='16' and e.duration.inherited)
local b=inspect(relative,'b d>')
assert(b.pitch=='B4' and b.chord_member==2 and b.chord_size==3 and b.duration.notation=='4')
assert(inspect(relative,'c,8').pitch=='C4','Following chord pitch did not use its first member as relative reference')
local tuplet="music = \\absolute { c'4 \\tuplet 3/2 { d'8 \\times 2/3 { ees' f' g' } } a' }"
local f=inspect(tuplet,"f' g'")
assert(f.kind=='note' and f.pitch=='F4' and f.duration.notation=='8' and #f.tuplets==2)
assert(f.tuplets[1].ratio=='3/2' and f.tuplets[2].command=='times')
assert(inspect("music = { r16. cis' }","cis'").duration.notation=='16.')
assert(inspect("music = { ces'4 }","ces'").pitch=='C♭4')
assert(inspect("music = { cisis'4 }","cisis'").midi==62)
assert(inspect("music = { c' }","c'").duration.notation=='4')
local globals="global = { \\key g \\major \\time 4/4 \\tempo 4 = 90 }\nmusic = \\relative c' { \\global c8 d }"
assert(inspect(globals,'d }').pitch=='D4')
local function reject(raw,needle)
  local value=inspect(raw,needle)
  assert(value.tag=='unsupported',vim.inspect(value))
end
reject("music = \\relative c' { c4 \\mystery d }",'c4')
reject("music = { <c' \\smallInnerNote e'>4 }","c'")
reject("music = { << { c'4 } \\\\ { e'4 } >> }","c'")
assert(inspect("music = { c'4*2/3 d' }","c'").duration.notation=="4*2/3")
reject('\\language "english"\nmusic = { c4 }','c4')
reject('\\include "english.ly"\nmusic = { c4 }','c4')
reject("music = { c'4 }\n\\transpose c d \\music","c'")
reject("music = { c'4 }\n\\relative c'' { \\music }","c'")
reject("words = \\lyricmode { do re mi }",'do')
reject("music = { c'4 } % c'4","% c'4")
reject("global = { r16 }\nmusic = { \\global c'4 }","c'")
local separate="wrapped = { c'4 }\nplain = \\relative c' { d4 }\n\\transpose c d \\wrapped"
assert(inspect(separate,'d4').pitch=='D4','An unrelated wrapper blocked independent music')
reject(separate,"c'")
local cross={['/score/main.ly']="\\relative c' { \\music }",['/score/part.ily']="music = { c'4 }"}
local cross_guard=music.guard(cross)
assert(music.analyzer(cross['/score/part.ily'],cross_guard)(assert(cross['/score/part.ily']:find("c'",1,true))).tag=='unsupported')
local defined="base = { c'4 }\nwrapper = { \\base }\n\\relative c' { \\wrapper }"
reject(defined,"c'4")
local fs=require('lilyp.fs')
local folder=vim.fn.tempname();vim.fn.mkdir(folder,'p')
local path=folder..'/music.ily'
local raw="% Người\r\nmusic = \\relative c' { c8. d e }\r\n"
fs.write(path,raw)
local char=assert(raw:match('music[^\n]+'):find('d e',1,true))-1
local entries={{source=path,line=2,char=char},{source=path,line=2,char=char}}
local origins=require('lilyp.source_origin').capture(entries,{[path]=vim.fn.sha256(raw)},folder)
assert(origins[1].inspection.symbol.pitch=='D4' and origins[1].inspection.symbol.duration.notation=='8.')
assert(origins[1].linked_objects==2 and origins[1].occurrence==1 and origins[2].occurrence==2)
assert(fs.read(path)==raw)
print('PASS: literal relative/absolute pitches, chord members, inherited dotted durations, nested tuplets, linked origins, CRLF, and explicit unsupported branch')

-- The captured include set supplies globals and bounded visual helpers. Local
-- names reused in separate section files keep their own preceding definition.
local main='keyAndTime = { \\key g \\major \\timeSignatureStyle \\time 4/4 }\nglobal = { \\keyAndTime \\tempo 4 = 90 }'
local style='timeSignatureStyle = \\numericTimeSignature\nsmallInnerNote = \\tweak font-size #-2 \\etc'
local part="local = { \\global }\nmusic = \\fixed c' { \\local <b \\smallInnerNote g>8. r16 \\slashedGrace { a32 } <c' a>4 }"
local files={['/score/main.ly']=main,['/score/style.ily']=style,['/score/part.ily']=part,
  ['/score/other.ily']='local = { \\key c \\major }'}
local read=music.analyzer(part,music.guard(files))
local function analyze(byte)return unwrap(read(byte))end
local inner=analyze(assert(part:find('\\smallInnerNote',1,true)))
assert(inner.kind=='note' and inner.pitch=='G4' and inner.chord_member==2 and inner.chord_size==2,vim.inspect(inner))
assert(inner.mode=='fixed' and inner.anchor=="c'" and inner.duration.notation=='8.')
assert(analyze(assert(part:find('r16',1,true))).kind=='rest')
local grace=analyze(assert(part:find('a32',1,true)))
assert(grace.grace and grace.pitch=='A4' and grace.duration.notation=='32')
assert(analyze(assert(part:find("c' a>",1,true))).duration.notation=='4')
assert(inspect("music = { s1*2/4 c' }","c'").duration.notation=='1*2/4')
reject("smallInnerNote = \\tweak font-size #(compute-size) \\etc\nmusic = { <c' \\smallInnerNote e'>4 }","c'")
reject("smallInnerNote = \\tweak font-size #-2 \\etc c'\nmusic = { <c' \\smallInnerNote e'>4 }","<c'")
local unknown=inspect("music = { <c' \\notDefined e'>4 }","c'")
assert(unknown.tag=='unsupported')
print('PASS: cross-file globals/style aliases, local section names, verified note tweaks, fixed octaves, grace, rest/skip/scaled durations, and unknown helper refusals')
local inherited=inspect("music = \\relative c' { c8 \\grace { d16 e } f }",'f }')
assert(inherited.duration.notation=='16' and inherited.duration.inherited and not inherited.grace)
reject("music = \\fixed c' { c4 }\n\\transpose c d \\music",'c4')
reject("music = \\fixed d' { c4 }",'c4')
reject("global = { \\global }\nmusic = { \\global c'4 }","c'")
