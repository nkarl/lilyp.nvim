local root=vim.fs.dirname(vim.fs.dirname(debug.getinfo(1,'S').source:sub(2)))
vim.opt.rtp:prepend(root)
local generator=require('lilyp.generator')
local build=require('lilyp.build')
local fs=require('lilyp.fs')
for _,preset in ipairs(generator.presets()) do
  generator.setup({title='Generated '..preset.value,composer='',subtitle='New project',preset=preset.value,
    key='g',mode='major',meter='4/4',tempo=90,pickup='4',lyrics=true,lyric_verses=3,chords=true,midi=true,
    paper='a4',engraving_mode='default'})
  local options=generator.defaults();options.project_directory=vim.fn.tempname()
  local path=build.create(generator.render(options),options)
  local project=vim.fs.dirname(path)
  assert(fs.read(path):find('\\include "style.ily"',1,true))
  local s=require('lilyp.session').open(path)
  assert(s.values.staff_size==15 and s.values.title_size==5)
  assert(not s.specified)
  s:apply();s:close()
  assert(vim.fn.filereadable(require('lilyp.output').directory(project)..'/main.pdf')==1)
end
print('PASS: all generated project presets have a separate, specifiable style include and unchanged initial rendering/MIDI')
