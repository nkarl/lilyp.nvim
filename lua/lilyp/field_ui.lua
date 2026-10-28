-- Display metadata only; semantics and LilyPond recipes are separate.
local M={tabs={'Page','Headers','Lyrics','Colors','Spacing'},list={
  {id="staff_size",tab=1,label="Staff size (pt)"},
  {id="paper",tab=1,label="Paper size"},
  {id="top_margin",tab=1,label="Top margin (mm)"},
  {id="bottom_margin",tab=1,label="Bottom margin (mm)"},
  {id="left_margin",tab=1,label="Left margin (mm)"},
  {id="right_margin",tab=1,label="Right margin (mm)"},
  {id="page_count",tab=1,label="Target page count"},
  {id="title_size",tab=2,label="Title size"},
  {id="subtitle_size",tab=2,label="Subtitle size"},
  {id="subtitle_shape",tab=2,label="Subtitle shape"},
  {id="composer_size",tab=2,label="Composer size"},
  {id="lyric_font",tab=3,label="Font family"},
  {id="lyric_size",tab=3,label="Lyric font size"},
  {id="lyric_shape",tab=3,label="Font shape"},
  {id="word_spacing",tab=3,label="Word spacing"},
  {id="stanza_size",tab=3,label="Stanza-number size"},
  {id="stanza_shape",tab=3,label="Stanza-number shape"},
  {id="row_spacing",tab=3,label="Lyric row distance"},
  {id="odd_color",tab=4,label="Odd stanza color"},
  {id="even_color",tab=4,label="Even stanza color"},
  {id="header_gap",tab=5,label="Header gap"},
  {id="section_gap",tab=5,label="Section gap"},
  {id="chord_size",tab=5,label="Chord-name size"},
  {id="chord_padding",tab=5,label="Chord-name padding"},
  {id="ragged_last_bottom",tab=1,label="Ragged last page bottom"},
  {id="hide_tempo_note",tab=2,label="Hide tempo note"},
  {id="metronome_color",tab=4,label="Tempo-mark color"},
  {id="rehearsal_color",tab=4,label="Rehearsal-mark color"},
  {id="text_mark_color",tab=4,label="Text-mark color"},
  {id="indent",tab=5,label="First-system indent (mm)"},
  {id="short_indent",tab=5,label="Later-system indent (mm)"},
}}
M.list[#M.list+1]={id='lyric_weight',tab=3,label='Lyric weight',choice_labels={normal='Regular',medium='Medium',semibold='Semibold',bold='Bold'},
  help='Select an installed font weight. Regular, Medium, Semibold, and Bold are distinct font faces.'}
local names={distance='preferred',minimum='minimum',padding='clearance',stretch='stretch'}
for _,relationship in ipairs(require('lilyp.spacing')) do
  for _,part in ipairs({'distance','minimum','padding','stretch'}) do
    local id=part=='distance' and relationship.preferred or nil
    id=id or relationship.id..'_'..part
    if id~='row_spacing' then
      M.list[#M.list+1]={id=id,tab=5,label=relationship.label..': '..names[part],
        help=relationship.label..' · '..(part=='stretch' and 'Relative willingness to stretch; zero disables discretionary stretching.'
          or part=='padding' and 'Minimum collision clearance, in staff spaces.'
          or part=='minimum' and 'Minimum reference-point distance, in staff spaces.'
          or 'Preferred reference-point distance, in staff spaces; collision clearance and justification can increase it.')}
    end
  end
end
return M
