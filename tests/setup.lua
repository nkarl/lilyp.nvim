-- Public setup works with the plugin alone and no personal configuration/assets.
local root=vim.fn.fnamemodify(debug.getinfo(1,'S').source:sub(2),':p:h:h')
vim.opt.rtp:prepend(root)
local app=require('lilyp')
local scaffold=require('lilyp.scaffold')
app.setup({})
assert(vim.fn.exists(':Lylip')==2 and vim.fn.exists(':LilyNewScore')==2)
assert(not package.loaded.nvls and not package.loaded.telescope)
local original=app.options()
assert(original.svg_glyph_cache==true)
app.setup({svg_glyph_cache=false});assert(app.options().svg_glyph_cache==false)
assert(not pcall(app.setup,{svg_glyph_cache='yes'}))
assert(app.options().svg_glyph_cache==false,'Invalid cache configuration replaced settings')
app.setup({})
local glyph_cache=require('lilyp.svg_glyph_cache')
assert(#glyph_cache.arguments('svg',true)==1)
assert(#glyph_cache.arguments('pdf',true)==0 and #glyph_cache.arguments('svg',false)==0)
local hook=glyph_cache.path;glyph_cache.path='/missing/svg-glyph-cache.ily'
assert(#glyph_cache.arguments('svg',true)==0,'A missing hook must retain ordinary engraving')
glyph_cache.path=hook
assert(original.defaults.engraving_mode=='default' and not original.defaults.instrument_inventory)
assert(original.defaults.tempo==84 and original.defaults.style.staff_size==15)
assert(original.defaults.chords==false)
assert(original.defaults.style.lyric_font=='LilyPond Serif')
assert(require('lilyp.creation_settings').defaults().lyric_font=='LilyPond Serif')
local appearance=require('lilyp.creation_settings').values(scaffold.defaults())
assert(appearance.lyric_size==2 and appearance.lyric_shape=='upright')
assert(appearance.title_size==5 and appearance.subtitle_size==3 and appearance.subtitle_shape=='upright')
assert(appearance.section_gap==1)
local fonts=require('lilyp.fonts')
local executable=vim.fn.executable
vim.fn.executable=function(name)return name=='fc-list' and 0 or executable(name)end
assert(fonts.check({lyric_font='LilyPond Serif',lyric_shape='italic',lyric_weight='normal'}))
assert(vim.tbl_contains(fonts.families({lyric_shape='upright'}),'LilyPond Serif'))
vim.fn.executable=executable
local supplied={defaults={tempo=100,chords=false,style={lyric_size=0}},gain=0}
app.setup(supplied)
supplied.defaults.tempo=200
local changed=app.options();changed.defaults.tempo=300
assert(app.options().defaults.tempo==100 and scaffold.defaults().tempo==100)
assert(scaffold.defaults().style.lyric_size==0 and not scaffold.defaults().chords and app.options().gain==0)
assert(scaffold.defaults().style.staff_size==15)
assert(not pcall(app.setup,{defaults={style=false}}))
assert(app.options().defaults.tempo==100,'Rejected configuration replaced active settings')
app.setup({generator={tempo=92}});assert(scaffold.defaults().tempo==92)
app.setup({defaults={tempo=91},generator={tempo=90}});assert(scaffold.defaults().tempo==91)
app.setup({});assert(scaffold.defaults().tempo==84)
app.setup({defaults={style={lyric_font='DejaVu Serif'}}});assert(scaffold.defaults().style.lyric_font=='DejaVu Serif')
app.setup({})
for _,preset in ipairs(scaffold.presets()) do
  local options=scaffold.defaults();options.preset=preset.value
  assert(not scaffold.validate(options),vim.inspect(scaffold.validate(options)))
  assert(scaffold.prepare(options):find('\\score',1,true))
end
local options=scaffold.defaults();options.instrument_inventory='/nonexistent/lilyp-inventory.json'
assert(scaffold.validate(options).field=='category','Explicit missing inventory must remain visible')
options=scaffold.defaults();options.chord_instrument='\n';assert(not scaffold.validate(options))
options.chords=true;assert(scaffold.validate(options).field=='chords')
-- With no catalog, the actual form edits an instrument inline without Telescope.
vim.o.columns,vim.o.lines=120,40
local form=assert(app.new())
assert(form.set('shared_instrument','oboe'))
assert(not form.set('shared_instrument','\n'))
assert(form.set('shared_instrument','flute'))
for _,mapping in ipairs(vim.api.nvim_buf_get_keymap(form.buf,'n')) do
  if mapping.lhs=='<CR>' then mapping.callback();break end
end
assert(form.editing,'Instrument Enter must open the inline editor without an inventory')
form.finish_edit(true)
form.reset();assert(form.options.assignments.piano.shared=='acoustic grand')
local function chord_controls()
  form.switch_tab(3)
  for _,field in ipairs(form.workspace_view.fields) do if field.label=='Chord-name size' then return true end end
  return false
end
assert(not chord_controls(),'Chord controls were shown while disabled')
assert(form.set('chords',true) and chord_controls())
assert(form.set('style:chord_size',1.25))
assert(form.set('presentation_scope','section_a') and form.set('style:chord_size',2.25))
assert(form.set('chords',false) and not chord_controls())
local source=scaffold.prepare(form.options)
assert(not source:find('ChordName',1,true) and not source:find('harmonies',1,true) and not source:find('chordSettings',1,true))
assert(form.set('presentation_scope','section_a') and not chord_controls())
assert(form.options.style.chord_size==1.25 and form.options.sections[1].presentation.chord_size==2.25)
assert(form.set('chords',true) and chord_controls())
source=scaffold.prepare(form.options)
assert(source:find('ChordName.font-size = #1.25',1,true) and source:find('ChordName.font-size = #2.25',1,true))
form.reset();assert(form.options.chords==false and not chord_controls())
form.close()
-- Optional catalog browsing has a native picker fallback.
local instruments=require('lilyp.instruments')
local saved_load,saved_select=instruments.load,vim.ui.select
local entry={lilypond_midi_instrument='flute',category='woodwinds',subcategory='flutes'}
instruments.load=function()return {entries={entry}}end
vim.ui.select=function(items,_,callback)assert(items[1]==entry);callback(items[1])end
local selected
instruments.pick({}, {on_status=function(message)error(message)end,on_select=function(value)selected=value end})
assert(selected==entry)
instruments.load,vim.ui.select=saved_load,saved_select
print('PASS: asset-free setup, nested overrides, copy isolation, legacy options, validation, presets, form reset, and native instrument picker')
