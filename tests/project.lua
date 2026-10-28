-- Run: nvim --headless -u NONE -i NONE -l tests/project.lua
local config = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(config)
local suite_path = vim.fn.stdpath('data') .. '/lazy/nvim-lilypond-suite'
vim.opt.rtp:append(suite_path)
local templates, project = require('lilyp.generator'), require('lilyp.build')
templates.setup({title='Người "Đã" Cất Bước', subtitle='Project test', composer='Test', preset='treble',
  key='g', mode='major', meter='4/4', tempo=120, pickup='none', lyrics=true, lyric_verses=3,
  chords=true, midi=true, paper='a4', engraving_mode='default', lyrics_language='vi'})
local options = templates.defaults()
local parent = vim.fn.tempname(); vim.fn.mkdir(parent, 'p')
options.project_parent = parent
local source = templates.render(options)
local main = project.create(source, options)
local root = vim.fs.dirname(main)
assert(root == parent .. '/Người "Đã" Cất Bước')
for _, dir in ipairs({'sections'}) do assert(vim.fn.isdirectory(root .. '/' .. dir) == 1) end
assert(vim.uv.fs_lstat(root..'/build').type=='link')
local output=require('lilyp.output')
assert(vim.fn.filereadable(root .. '/score.yaml') == 1)
local before = table.concat(vim.fn.readfile(main), '\n')
local ok = pcall(project.create, 'DO NOT OVERWRITE', options)
assert(not ok and table.concat(vim.fn.readfile(main), '\n') == before, 'Existing project must not be overwritten')

-- Use a real included section to check source-root and working-directory handling.
local music = root .. '/sections/music.ily'
vim.fn.writefile({'sectionMusic = { g\'4 a b c }'}, music)
vim.fn.writefile({'\\version "2.26.0"', '\\include "sections/music.ily"',
  '\\score { \\new Staff { \\sectionMusic } \\layout { } \\midi { } }'}, main)
local suite = require('nvls')
local soundfont = vim.env.LILYP_TEST_SOUNDFONT
if soundfont then soundfont=vim.fn.expand(soundfont);assert(vim.fn.filereadable(soundfont)==1,'Test SoundFont not found') end
suite.setup({player={options={audio_format='wav', fluidsynth_flags={'-i','-r','44100','-g','0.2',soundfont or ''},
  ffmpeg_flags={'-y','-ar','44100'}}}})
project.setup()
vim.cmd.edit(vim.fn.fnameescape(music)); vim.bo.filetype = 'lilypond'
vim.cmd('runtime ftplugin/lilypond.lua')
assert(vim.fn.maparg('<F5>', 'n'):find('LilyCmp',1,true))
assert(vim.fn.maparg('<F6>', 'n'):find('Viewer',1,true))
assert(vim.fn.maparg('<F3>', 'n'):find('LilyPlayer',1,true))
-- Delete only the test directory: every action must recreate it when missing.
local build_dir=output.ensure(root)
assert(vim.fn.delete(build_dir,'d') == 0)
local infos = suite.get_file_infos()
assert(infos.main == main and infos.pdf == build_dir .. '/main.pdf')
assert(infos.midi == build_dir .. '/main.midi' and infos.audio == build_dir .. '/main.wav')
assert(vim.fn.isdirectory(build_dir) == 1)
-- F5's command saves modified includes and compiles the project entry point.
vim.api.nvim_buf_set_lines(0,0,-1,false,{'sectionMusic = { g\'4 a b d }'})
vim.cmd.LilyCmp()
assert(vim.wait(30000,function() return vim.fn.filereadable(infos.pdf)==1 and suite.debug.exit ~= nil end,20),
  'Project compilation timed out: '..vim.inspect(suite.debug))
assert(suite.debug.exit:find('code 0',1,true), vim.inspect(suite.debug))
assert(table.concat(vim.fn.readfile(music),'\n'):find('b d',1,true), 'Modified include was not saved')
assert(vim.fn.filereadable(infos.midi)==1 and vim.fn.filereadable(root..'/main.pdf')==0)
-- F6 opens the resolved PDF without launching a GUI in this test.
local viewed
require('nvls.viewer').open = function(path) viewed=path end
vim.cmd.Viewer(); assert(viewed==infos.pdf)
-- F3 uses the same output directory without opening the player.
local played
require('nvls.player').load_or_open = function(path) played=path end
if soundfont then
  vim.cmd.LilyPlayer()
  assert(vim.wait(30000,function() return played ~= nil end,20), 'Audio conversion timed out: '..vim.inspect(suite.debug))
  assert(played==infos.audio and vim.fn.getfsize(played)>44)
else
  print('SKIP: real audio conversion; set LILYP_TEST_SOUNDFONT to an installed bank to exercise F3')
end

-- Standalone scores retain their basename in a private temporary directory.
local standalone = parent .. '/standalone'; vim.fn.mkdir(standalone,'p')
local solo = standalone .. '/A score with spaces.ly'
vim.fn.writefile({'\\version "2.26.0"','\\score { { c\'1 } \\layout {} \\midi {} }'},solo)
vim.cmd.edit(vim.fn.fnameescape(solo)); vim.bo.filetype='lilypond'
project.attach(vim.api.nvim_get_current_buf())
infos=suite.get_file_infos()
assert(infos.main==solo and infos.pdf==output.directory(standalone,solo)..'/A score with spaces.pdf')
suite.debug.exit=nil
vim.cmd.LilyCmp()
assert(vim.wait(30000,function() return vim.fn.filereadable(infos.pdf)==1 and suite.debug.exit~=nil end,20), 'Standalone compilation timed out')
assert(suite.debug.exit:find('code 0',1,true),vim.inspect(suite.debug))
assert(vim.fn.filereadable(infos.midi)==1)
vim.cmd.Viewer(); assert(viewed==infos.pdf)

-- Standalone uses the setup default; a project's explicit spec takes precedence.
require('lilyp').setup({build_location='project'})
assert(suite.get_file_infos().pdf==standalone..'/build/A score with spaces.pdf')
vim.cmd.edit(vim.fn.fnameescape(music));vim.bo.filetype='lilypond'
assert(suite.get_file_infos().pdf==build_dir..'/main.pdf')
local spec_path=root..'/score.yaml'
assert(vim.uv.fs_unlink(root..'/build'))
vim.fn.mkdir(root..'/build','p')
local spec_buf=vim.fn.bufadd(spec_path);vim.fn.bufload(spec_buf)
assert(suite.get_file_infos().pdf==root..'/build/main.pdf')
assert(table.concat(vim.fn.readfile(spec_path),'\n'):find('location: temporary',1,true),'Inspection changed the spec')
suite.debug.exit=nil
vim.cmd.LilyCmp()
assert(vim.wait(30000,function()return vim.fn.filereadable(root..'/build/main.pdf')==1 and suite.debug.exit~=nil end,20))
assert(suite.debug.exit:find('code 0',1,true),vim.inspect(suite.debug))
assert(table.concat(vim.fn.readfile(spec_path),'\n'):find('location: project',1,true),'Rebuild did not adopt the local directory')
assert(table.concat(vim.api.nvim_buf_get_lines(spec_buf,0,-1,false),'\n'):find('location: project',1,true),'Loaded spec buffer was not refreshed')
assert(not vim.bo[spec_buf].modified)
require('lilyp').setup({})

-- Form project generation creates and opens main.ly; errors keep the form alive.
vim.o.columns,vim.o.lines=120,40
local form=assert(require('lilyp.generator_form').open())
assert(form.set('project_directory',parent..'/From form'))
form.switch_tab(4)
assert(vim.api.nvim_buf_line_count(form.buf)==vim.api.nvim_win_get_height(form.win))
local generated=assert(form.generate())
assert(vim.api.nvim_buf_get_name(generated)==parent..'/From form/main.ly')
assert(not vim.bo[generated].modified and vim.fn.filereadable(parent..'/From form/score.yaml')==1)
form=assert(require('lilyp.generator_form').open())
assert(form.set('project_directory',parent..'/From form'))
assert(form.generate()==nil and not form.closed)
form.close()
print('PASS: project creation, includes, temporary output recreation, F5/F6/F3, standalone and project-local builds, and form generation.')
