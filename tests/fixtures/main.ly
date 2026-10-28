\version "2.26.0"
\include "style.ily"
\include "sections/refrain.ily"
\header { title = \markup \fontsize #titleFontSize "Curator fixture" tagline = ##f }
\score {
  <<
    \new Voice = "melody" { \refrainMusic }
    \new Lyrics \lyricsto "melody" { \refrainWords }
  >>
  \layout { \scoreLayout }
}
\score {
  \unfoldRepeats \new Staff \with { midiInstrument = "violin" } { \refrainMusic }
  \midi { }
}
