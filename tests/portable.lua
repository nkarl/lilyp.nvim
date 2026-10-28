-- Compile all shipped staff presets using LilyPond's native font defaults.
local root=vim.fn.fnamemodify(debug.getinfo(1,'S').source:sub(2),':p:h:h')
vim.opt.rtp:prepend(root)
local app=require('lilyp')
app.setup({})
local scaffold,fs=require('lilyp.scaffold'),require('lilyp.fs')
local output=vim.fn.tempname();vim.fn.mkdir(output,'p')
local count=0
for _,preset in ipairs(scaffold.presets())do
  for _,chords in ipairs({false,true}) do
    local options=scaffold.defaults()
    options.preset,options.lyrics,options.chords=preset.value,true,chords
    local source=scaffold.prepare(options)
    assert((source:find('ChordNames',1,true)~=nil)==chords)
    assert((source:find('harmonies =',1,true)~=nil)==chords)
    local path=output..'/'..preset.value..(chords and '-chords' or '-plain')
    fs.write(path..'.ly',source)
    local result=vim.system({'lilypond','-o',path,path..'.ly'},{text=true}):wait(30000)
    local log=(result.stdout or '')..(result.stderr or '')
    assert(result.code==0 and not log:lower():find('warning:',1,true),preset.value..'\n'..log)
    assert(vim.fn.filereadable(path..'.pdf')==1 and vim.fn.filereadable(path..'.midi')==1)
    count=count+1
  end
end
assert(not package.loaded.telescope and not package.loaded.nvls)
print('PASS: '..count..' preset/chord variants compile with PDF/MIDI and no personal resources or optional editor plugins')
