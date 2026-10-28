-- Learning support reads inspected source; it never invents an effective value.
local M={}
local observation=require('lilyp.source_observation')
local binding=require('lilyp.source_binding')
M.explanations={
  staff_size='Staff height in points, scaling notation and associated fonts together. Section values affect that printed layout only.',
  paper='Sets the PDF paper size. Margins determine the usable area on that page.',
  top_margin='Space between the top page edge and the printable area, in millimeters.',
  bottom_margin='Space reserved below the printable area, in millimeters.',
  left_margin='Space reserved at the left page edge, in millimeters.',
  right_margin='Space reserved at the right page edge, in millimeters.',
  page_count='Asks LilyPond to fit the score into this many pages. Dense music can still produce layout warnings.',
  title_size='Changes the title font size through the score’s titleFontSize helper; title text stays intact.',
  subtitle_size='Changes the subtitle font size through subtitleFontSize, without changing its text.',
  subtitle_shape='Selects the subtitle’s italic or upright face through subtitleFontShape.',
  composer_size='Changes the composer credit’s font size through composerFontSize.',
  lyric_font='Chooses the serif font family used by lyric text. The family and required glyphs must be installed.',
  lyric_size='Changes lyric text size in LilyPond font steps: 0 is normal, positive values are larger, and negative values are smaller. This is relative sizing, not points.',
  lyric_shape='Selects an installed upright, italic, or oblique lyric face. Shape is a named face, not a numeric angle. Explicit handwritten font-name overrides are preserved.',
  lyric_weight='Selects an available static font weight. Regular, Medium, Semibold, and Bold are named faces, not a continuous numeric weight axis.',
  word_spacing='Sets the minimum horizontal spacing between lyric words; syllable alignment stays attached to the music.',
  stanza_size='Changes the size of stanza numbers, independently of lyric text.',
  stanza_shape='Chooses italic or upright stanza numbers.',
  row_spacing='Sets the basic vertical distance between lyric rows. LilyPond may increase it to avoid collisions.',
  odd_color='Changes the existing odd-stanza palette helper. Existing ending assignments and local colors stay intact.',
  even_color='Changes the existing even-stanza palette helper. Existing ending assignments and local colors stay intact.',
  header_gap='Changes the vertical-space markup in the existing headerGap helper.',
  section_gap='Changes the vertical-space markup in the existing sectionGap helper; it adds no playback silence.',
  chord_size='Changes printed chord-name size; sounding chord instruments and notes stay intact.',
  chord_padding='Sets padding between the chord-name context and its related staff.',
  ragged_last_bottom='Allows the last page to end naturally instead of stretching systems toward the bottom margin.',
  hide_tempo_note='Hides the note symbol in the printed tempo mark. Playback tempo is preserved.',
  metronome_color='Changes the printed tempo mark’s color, without changing tempo.',
  rehearsal_color='Changes rehearsal-mark color; mark text and placement stay intact.',
  text_mark_color='Changes TextMark color; handwritten mark text stays intact.',
  indent='Sets the first system’s indentation in millimeters.',
  short_indent='Sets later systems’ indentation in millimeters.',
}

local function excerpt(source,at,path)
  local before=source:sub(1,at-1)
  local _,newlines=before:gsub('\n','')
  local first=(before:match('.*\n()') or 1)
  local last=source:find('\n',at,true) or #source+1
  return path..':'..(newlines+1),source:sub(first,last-1):gsub('^%s+','')
end

function M.source(session,scope,field)
  local current=session:view(scope)
  local entry=current.entries[field.id]
  local path=scope and binding.path(current.source) or session.style_path
  local origin=current.origins and current.origins[field.id]
  if scope and (not origin or origin.scope~='section') then
    entry=session.inspected[field.id];path=session.style_path
  end
  return entry and entry.context.path or path,entry
end
function M.presentation(session,scope,field)
  local path,entry=M.source(session,scope,field)
  local lines={'YAML setting: presentation.'..(scope and 'sections.'..scope..'.' or '')..'settings.'..field.id}
  if scope then lines[#lines+1]='Score default: '..tostring(session.draft[field.id]==nil and 'not declared' or session.draft[field.id]) end
  local at=observation.locate(entry)
  if at and path and session.snapshot[path] then
    local location,code=excerpt(session.snapshot[path],at.first,path)
    lines[#lines+1]='Current source: '..location
    lines[#lines+1]=code
  else
    lines[#lines+1]='Source: '..tostring(path or 'no unique layout binding')
    lines[#lines+1]=observation.reason(entry) or 'No unique source literal is available.'
  end
  lines[#lines+1]='d shows the exact planned LilyPond and YAML diff; o opens the style source.'
  return lines
end

local creation_patterns={title='title%s*=',subtitle='subtitle%s*=',composer='composer%s*=',
  key='\\key%s',mode='\\key%s',meter='\\time%s',tempo='\\tempo%s',pickup='\\partial%s',
  paper='set%-paper%-size',lyric_verses='\\lyricmode',lyrics='\\lyricmode',midi='\\midi%s*{',
  chords='\\chordmode',group_label='instrumentName',section_name='\\markup',
  section_staff_preset='\\new%s',preset='\\new%s'}
function M.creation(options,field)
  local lines={'Creation setting: '..field.key,'These settings initialize a new score; existing music is not regenerated.'}
  local pattern=creation_patterns[field.key]
  if field.id then pattern=require('lilyp.style_bindings').for_scope(field.id,field.scope~='score' and 'section' or 'global').pattern end
  if field.kind=='instrument' then pattern='midiInstrument%s*=' end
  if field.key:match('^label:') then pattern='instrumentName%s*=' end
  if pattern then
    local ok,source=pcall(require('lilyp.scaffold').prepare,options)
    if ok then
      local at=source:find(pattern)
      if field.id and field.scope and field.scope~='score' then
        at=nil
        for i,section in ipairs(require('lilyp.sections').plan(options)) do if section.id==field.scope then
          local region=require('lilyp.source_regions').blocks(source,'score')[i]
          if region then
            local found=source:sub(region.first,region.close):find(pattern)
            if found then at=region.first+found-1 end
          end
        end end
      end
      if at then
        local location,code=excerpt(source,at,'generated source')
        lines[#lines+1]='Example from '..location;lines[#lines+1]=code
      else lines[#lines+1]='No matching expression is emitted by this draft.' end
    else lines[#lines+1]='Source preview needs a valid creation draft.' end
  end
  lines[#lines+1]='p opens the complete generated LilyPond source before creation.'
  return lines
end
return M
