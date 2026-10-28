-- LilyPond recipes keyed by canonical setting IDs.
local M={list={
  {id="staff_size",pattern="#%(set%-global%-staff%-size%s+([%d%.]+)%)"},
  {id="paper",pattern="#%(set%-paper%-size%s+(\"[^\"\n]+\")%)"},
  {id="top_margin",pattern="top%-margin%s*=%s*([%d%.]+)%s*\\mm"},
  {id="bottom_margin",pattern="bottom%-margin%s*=%s*([%d%.]+)%s*\\mm"},
  {id="left_margin",pattern="left%-margin%s*=%s*([%d%.]+)%s*\\mm"},
  {id="right_margin",pattern="right%-margin%s*=%s*([%d%.]+)%s*\\mm"},
  {id="page_count",paper="page-count",pattern="page%-count%s*=%s*([%d]+)"},
  {id="title_size",pattern="titleFontSize%s*=%s*#([%-%.%d]+)"},
  {id="subtitle_size",pattern="subtitleFontSize%s*=%s*#([%-%.%d]+)"},
  {id="subtitle_shape",pattern="subtitleFontShape%s*=%s*#'([%a]+)"},
  {id="composer_size",pattern="composerFontSize%s*=%s*#([%-%.%d]+)"},
  {id="lyric_font",pattern="LyricText%.fonts%.serif%s*=%s*(\"[^\"\n]+\")"},
  {id="lyric_size",pattern="LyricText%.font%-size%s*=%s*#([%-%.%d]+)"},
  {id="lyric_shape",pattern="LyricText%.font%-shape%s*=%s*#'([%a]+)"},
  {id="word_spacing",pattern="LyricSpace%.minimum%-distance%s*=%s*#([%-%.%d]+)"},
  {id="stanza_size",pattern="StanzaNumber%.font%-size%s*=%s*#([%-%.%d]+)",layout="StanzaNumber.font-size"},
  {id="stanza_shape",pattern="StanzaNumber%.font%-shape%s*=%s*#'([%a]+)",layout="StanzaNumber.font-shape"},
  {id="row_spacing",pattern="VerticalAxisGroup%.nonstaff%-nonstaff%-spacing%.basic%-distance%s*=%s*#([%-%.%d]+)",layout="VerticalAxisGroup.nonstaff-nonstaff-spacing.basic-distance"},
  {id="odd_color",pattern="oddVerseColor%s*=%s*(\"[^\"\n]+\")"},
  {id="even_color",pattern="evenVerseColor%s*=%s*(\"[^\"\n]+\")"},
  {id="header_gap",pattern="headerGap%s*=%s*\\markup%s+\\vspace%s+#([%-%.%d]+)"},
  {id="section_gap",pattern="sectionGap%s*=%s*\\markup%s+\\vspace%s+#([%-%.%d]+)"},
  {id="chord_size",pattern="ChordName%.font%-size%s*=%s*#([%-%.%d]+)"},
  {id="chord_padding",pattern="VerticalAxisGroup%.nonstaff%-relatedstaff%-spacing%.padding%s*=%s*#([%-%.%d]+)"},
  {id="ragged_last_bottom",paper="ragged-last-bottom",pattern="ragged%-last%-bottom%s*=%s*(##[tf])"},
  {id="hide_tempo_note",layout="tempoHideNote",pattern="tempoHideNote%s*=%s*(##[tf])",context="Score",property=true},
  {id="metronome_color",pattern="MetronomeMark%.color%s*=%s*(\"[^\"\n]+\")",layout="MetronomeMark.color",context="Score"},
  {id="rehearsal_color",pattern="RehearsalMark%.color%s*=%s*(\"[^\"\n]+\")",layout="RehearsalMark.color",context="Score"},
  {id="text_mark_color",pattern="TextMark%.color%s*=%s*(\"[^\"\n]+\")",layout="TextMark.color",context="Score"},
  {id="indent",pattern="indent%s*=%s*([%d%.]+)%s*\\mm",setting="indent",unit="\\mm"},
  {id="short_indent",pattern="short%-indent%s*=%s*([%d%.]+)%s*\\mm",setting="short-indent",unit="\\mm"},
}}
M.list[#M.list+1]={id='lyric_weight',pattern="LyricText%.font%-series%s*=%s*#'([%a]+)",layout='LyricText.font-series',context='Lyrics',creation_extra=true}
local suffixes={distance='basic-distance',minimum='minimum-distance',padding='padding',stretch='stretchability'}
for _,relationship in ipairs(require('lilyp.spacing')) do
  for _,part in ipairs({'distance','minimum','padding','stretch'}) do
    local id=part=='distance' and relationship.preferred or nil
    id=id or relationship.id..'_'..part
    if id~='row_spacing' then
      local property=relationship.property..'.'..suffixes[part]
      local recipe={id=id,pattern=property:gsub('([%.%-])','%%%1')..'%s*=%s*#?([%-%.%d]+)',
        spacing_parent=relationship.property:gsub('([%.%-])','%%%1'),creation_extra=true}
      if relationship.paper then recipe.paper=property else recipe.layout=property;recipe.context=relationship.context end
      M.list[#M.list+1]=recipe
    end
  end
end
M.by_id={}
for _,binding in ipairs(M.list) do M.by_id[binding.id]=binding end
M.by_id.staff_size.anchor='#%(set%-global%-staff%-size'
M.by_id.chord_padding.context='ChordNames'
M.by_id.chord_padding.inspect_context=true
for _,recipe in ipairs(M.list) do if recipe.id:match('^lyric_staff_') then recipe.inspect_context=true end end
M.by_id.row_spacing.spacing_parent='VerticalAxisGroup%.nonstaff%-nonstaff%-spacing'
local section_layout={lyric_font='LyricText.fonts.serif',lyric_size='LyricText.font-size',
  lyric_shape='LyricText.font-shape',word_spacing='LyricSpace.minimum-distance',
  chord_size='ChordName.font-size',chord_padding='VerticalAxisGroup.nonstaff-relatedstaff-spacing.padding'}
function M.for_scope(id,scope)
  local recipe=assert(M.by_id[id],'No LilyPond recipe: '..id)
  if scope=='section' and id=='staff_size' then
    return {id=id,pattern='#%(layout%-set%-staff%-size%s+([%d%.]+)%)',
      anchor='#%(layout%-set%-staff%-size',layout_function='layout-set-staff-size'}
  end
  if scope=='section' and section_layout[id] then
    return vim.tbl_extend('force',recipe,{layout=section_layout[id],context=id:match('^chord_') and 'ChordNames' or 'Lyrics'})
  end
  return recipe
end
function M.literal(f,value)
  if f.kind=='boolean' then return value and '##t' or '##f' end
  return f.kind=='string' and vim.json.encode(value) or tostring(value)
end
return M
