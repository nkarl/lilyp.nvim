#(set-global-staff-size 15)
\paper { #(set-paper-size "a4") }
titleFontSize = #1
subtitleFontSize = #0
subtitleFontShape = #'italic
composerFontSize = #0
headerGap = \markup \vspace #1
sectionGap = \markup \vspace #3
oddVerseColor = "#00007f"
evenVerseColor = "#55007f"
% Custom Scheme and comments must survive specification import and edits.
#(define curator-custom-value 42)
% LyricText.font-size = #99
scoreLayout = \layout {
  \context {
    \Lyrics
    \override LyricText.fonts.serif = "Noto Serif"
    \override LyricText.font-shape = #'italic
    \override LyricText.font-size = #1
    \override LyricSpace.minimum-distance = #2
  }
  \context {
    \ChordNames
    \override ChordName.font-size = #0.5
    \override VerticalAxisGroup.nonstaff-relatedstaff-spacing.padding = #2
  }
}
