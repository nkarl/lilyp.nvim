-- Lightweight preferences only; no fonts, templates, inventories, or SoundFonts are bundled.
return {
  lilypond = "lilypond",
  svg_glyph_cache = true,
  gain = 0.6,
  build_location = "temporary",
  build_integration = false,
  score_viewer = {browser={}},
  navigation = {enabled=false},
  defaults = {
    title = "Untitled",
    subtitle = "", -- Printed upright when supplied.
    project_mode = "project", -- "project" writes a score folder; "standalone" creates an unsaved buffer.
    project_directory = "", -- Empty uses the title under the form's starting directory.
    lyrics_language = "", -- Optional language code recorded in score.yaml, such as "vi".
    composer = "",
    preset = "piano", -- "piano", "treble", "bass", or "satb" (four staves).
    key = "c", -- LilyPond Dutch pitch names: c, g, fis, bes, ees, etc.
    mode = "major", -- "major" or "minor".
    meter = "4/4", -- Other examples: "3/4", "6/8", "5/4", "7/8".
    tempo = 84, -- Quarter notes per minute, including in compound meters.
    pickup = "none", -- "none", "4", "8", "4.", "8*3", etc.; shorter than a bar.
    lyrics = false, -- true adds numbered lyric rows attached to the first staff.
    lyric_verses = 3, -- Numbered rows, alternating odd/even verse colors (1–3).
    chords = false, -- Opt in to chord names in the PDF and accompaniment in MIDI.
    chord_instrument = "acoustic grand",
    paper = "a4", -- "a4" or "letter".
    midi = true, -- false omits MIDI playback output.
    -- Optional external templates can be enabled with "embed" or "include".
    engraving_mode = "default",

    -- Defaults learned from the completed transcription; copied into new scores.
    -- These apply with every staff preset and every engraving-template mode.
    style = {
      staff_size = 15,
      numeric_time = true, -- Show 4/4 rather than the common-time symbol.
      title_size = 5,
      subtitle_size = 3,
      subtitle_italic = false,
      lyric_font = "LilyPond Serif",
      lyric_size = 2,
      lyric_italic = false,
      lyric_word_spacing = 2,
      odd_verse_color = "#00007f",
      even_verse_color = "#55007f",
      chord_size = 0.5,
      chord_padding = 2,
      inner_note_size = -2,
      section_gap = 1, -- Reusable sectionGap markup for separate layout scores.
    },

    -- Shared is the initial mode for grand staff and SATB; the form also allows
    -- separate sounds per staff. Printed labels remain independent of playback.
    instruments = {
      piano = { mode = "shared", instrument = "acoustic grand", group_label = "Piano" },
      treble = { instrument = "flute", label = "Flute" },
      bass = { instrument = "cello", label = "Cello" },
      satb = { mode = "shared", instrument = "choir aahs", group_label = "Choir" },
      -- To start with different piano sounds, replace the piano entry with:
      -- piano = { mode = "separate", instrument = "acoustic grand",
      --   group_label = "Piano", staves = {
      --     upper = { instrument = "flute", label = "Flute" },
      --     lower = { instrument = "cello", label = "Cello" },
      --   },
      -- },
    },
    -- Preferred starting entries when the current instrument is outside a filter.
    -- Category/type browsing never changes an assignment until you select a sound.
    category_defaults = {
      keyboards = "acoustic grand", strings = "violin", woodwinds = "flute",
      brass = "trumpet", free_reeds = "accordion", voices = "choir aahs",
      percussion = "vibraphone", synthesizers = "pad 2 (warm)", sound_effects = false,
    },
    subcategory_defaults = {
      ["strings.bowed_strings"] = "violin",
      ["strings.acoustic_guitars"] = "acoustic guitar (nylon)",
      ["woodwinds.single_reeds"] = "clarinet",
      ["keyboards.organs"] = "church organ",
      -- Add overrides using "category_id.subcategory_id" from the JSON inventory.
    },
  },
}
