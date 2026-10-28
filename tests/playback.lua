-- Optional real F3 integration: explicit suite/SoundFont; no personal config,
-- device playback, GUI, downloads, or edits to either external resource.
local plugin=vim.fs.dirname(vim.fs.dirname(debug.getinfo(1,'S').source:sub(2)))
vim.opt.rtp:prepend(plugin)
local suite_path=assert(vim.env.LILYP_TEST_NVLS,'Supply --nvls-path through scripts/test.lua')
local soundfont=assert(vim.env.LILYP_TEST_SOUNDFONT,'Supply --soundfont through scripts/test.lua')
assert(vim.fn.filereadable(soundfont)==1,'Test SoundFont is missing')
vim.opt.rtp:append(suite_path)
for _,name in ipairs({'lilypond','fluidsynth','ffmpeg'}) do
  assert(vim.fn.executable(name)==1,'Playback regression requires '..name)
end
local fs=require('lilyp.fs')
local suite=require('nvls')
local function configure(font,extra)
  suite.setup({player={options={midi_synth='fluidsynth',audio_format='wav',
    fluidsynth_flags={'-i','-r','44100','-g','0.2','-R','0','-C','0',font or soundfont},
    ffmpeg_flags=extra or {'-y','-ar','44100'}}}})
end
configure()
require('lilyp').setup({build_integration=true})
local player=require('nvls.player')
local queue=require('nvls.job')
local run_job,counts=queue.run_job,{}
queue.run_job=function(self,job)
  counts[job.cmd]=(counts[job.cmd] or 0)+1
  return run_job(self,job)
end
local opened={}
player.load_or_open=function(path)opened[#opened+1]=path end
local function wait_for(predicate,label)
  assert(vim.wait(30000,predicate,10),(label or 'Playback')..' timed out: '..vim.inspect(suite.debug))
end
local function idle()return not queue.running and #queue.queue==0 end
local parent=vim.fn.tempname();vim.fn.mkdir(parent,'p')
local function project(name,music)
  local root=parent..'/'..name;vim.fn.mkdir(root..'/sections','p')
  fs.write(root..'/score.yaml','kind: lilypond-score\nsource:\n  main: main.ly\n  style: style.ily\n')
  fs.write(root..'/style.ily','% Handwritten fixture style\n')
  fs.write(root..'/sections/part.ily','partMusic = { '..music..' }\n')
  fs.write(root..'/main.ly',[=[\version "2.26.0"
\include "sections/part.ily"
\score {
  \new Staff \with { midiInstrument = "flute" } \partMusic
  \layout { }
  \midi { \tempo 4 = 120 }
}
]=])
  return root
end
local function select(root)
  local path=root..'/sections/part.ily'
  if vim.api.nvim_buf_get_name(0)~=path then vim.cmd.edit(vim.fn.fnameescape(path)) end
  vim.bo.filetype='lilypond'
  return suite.get_file_infos()
end
local function compile(root)
  local file=root and select(root) or suite.get_file_infos()
  -- F5 now belongs to Lylip's compiler rather than the suite's job queue.
  -- Observe its completion while still exercising the real buffer command.
  local compiler=require('lilyp.compiler')
  local original=compiler.compile
  local completion,artifact
  compiler.compile=function(opts)
    return original(vim.tbl_extend('force',opts or {},{
      on_done=function(value)artifact=value end,
      on_complete=function(value)completion=value end,
    }))
  end
  vim.cmd.LilyCmp()
  compiler.compile=original
  wait_for(function()return completion~=nil end,'Compilation')
  assert(completion.tag=='succeeded' and artifact,vim.inspect(completion))
  assert(not artifact.log:lower():find('warning:',1,true),artifact.log)
  assert(vim.fn.filereadable(file.midi)==1)
  return file
end
local function play(root)
  local file=root and select(root) or suite.get_file_infos();local previous=#opened
  suite.debug.exit=nil
  vim.cmd.LilyPlayer()
  wait_for(function()return #opened>previous and idle() end,'Audio conversion')
  assert(opened[#opened]==file.audio,'F3 opened the wrong project audio')
  return file
end
local function inspect(path)
  local audio=dofile(plugin..'/tests/support/audio_probe.lua').inspect(path)
  assert(audio.channels==2 and audio.sample_rate==44100 and audio.frames>0,vim.inspect(audio))
  assert(audio.duration>1.5 and audio.duration<15,vim.inspect(audio))
  assert(audio.peak>0.001 and audio.rms>0.00001,'Rendered note fixture is silent: '..vim.inspect(audio))
  assert(audio.peak<0.99,'Rendered fixture clipped: '..vim.inspect(audio))
  return audio
end

local first=project('Score A with spaces',"a'1")
local second=project('Score B – independent',"c''1")
local file=compile(first)
vim.cmd('runtime ftplugin/lilypond.lua')
assert(vim.fn.maparg('<F3>','n'):find('LilyPlayer',1,true))
local source=fs.snapshot(first)
local midi=fs.read(file.midi)
play(first)
local initial=inspect(file.audio)
assert(counts.fluidsynth==1 and counts.ffmpeg==1)
assert(fs.read(file.midi)==midi and vim.deep_equal(source,fs.snapshot(first)),'F3 modified source or MIDI')
print('PASS: real FluidSynth/FFmpeg F3 produced '..initial.duration..'s of non-silent stereo PCM')

-- Make ordering explicit so the cache check does not depend on wall-clock sleeps
-- or how long this machine takes to render the fixture.
local stamp=os.time()-100
assert(vim.uv.fs_utime(file.midi,stamp,stamp))
assert(vim.uv.fs_utime(file.audio,stamp+1,stamp+1))
local cached=fs.read(file.audio)
play(first)
assert(counts.fluidsynth==1 and counts.ffmpeg==1 and fs.read(file.audio)==cached,'Unchanged MIDI was needlessly resynthesized')

-- Enter different pitches/durations in an included source, rebuild, then F3 must
-- regenerate the old audio and leave the newly compiled MIDI untouched.
vim.api.nvim_buf_set_lines(0,0,-1,false,{"partMusic = { a''1 a''1 }"})
compile(first)
local changed_midi=fs.read(file.midi)
assert(changed_midi~=midi,'Fixture edit did not change MIDI')
assert(vim.uv.fs_utime(file.audio,stamp-1,stamp-1))
play(first)
local changed=inspect(file.audio)
assert(changed.duration>initial.duration+1.5 and changed.pcm_sha256~=initial.pcm_sha256)
assert(fs.read(file.midi)==changed_midi and counts.fluidsynth==2 and counts.ffmpeg==2)
source=fs.snapshot(first)
print('PASS: unchanged MIDI reuses cached audio; changed pitches/durations rebuild it')

-- A missing bank must fail without opening an audio artifact. Correcting the
-- settings must allow another F3 request without restarting Neovim.
assert(vim.uv.fs_unlink(file.audio))
configure(parent..'/missing-bank.sf2')
select(first);suite.debug.exit=nil
local previous=#opened
local encoded=counts.ffmpeg
vim.cmd.LilyPlayer()
wait_for(function()return suite.debug.exit~=nil and idle() end,'Missing SoundFont failure')
assert(#opened==previous,'Missing SoundFont produced playable output: '..vim.inspect(suite.debug))
assert(not suite.debug.exit:find('code 0, signal 0',1,true),'Missing bank was accepted')
assert(suite.debug.exit:find('fluidsynth exit',1,true) and (suite.debug.stdout or ''):find('missing-bank.sf2',1,true))
assert(counts.ffmpeg==encoded,'Failed synthesis still executed encoding')
configure();play(first);inspect(file.audio)

-- An actual FFmpeg argument failure must not call the player, and the conversion
-- queue must recover for the next valid request.
assert(vim.uv.fs_unlink(file.audio))
configure(nil,{'-y','-lilyp-invalid-option'})
select(first);suite.debug.exit=nil;previous=#opened
vim.cmd.LilyPlayer()
wait_for(function()return idle() and (suite.debug.exit or ''):find('ffmpeg exit',1,true) end,'FFmpeg failure')
assert(#opened==previous and not suite.debug.exit:find('code 0, signal 0',1,true))
assert((suite.debug.stdout or ''):find('lilyp-invalid-option',1,true),'Expected the deliberate FFmpeg option error')
configure();play(first);inspect(file.audio)
assert(fs.read(file.midi)==changed_midi and vim.deep_equal(source,fs.snapshot(first)))
print('PASS: missing-bank and FFmpeg failures recover on the next valid F3 request')

-- Queue two projects back-to-back. A completed first result must remain intact
-- while the second project converts, even though their output basenames match.
local other=compile(second)
assert(other.audio~=file.audio and other.midi~=file.midi)
local other_source=fs.snapshot(second);local other_midi=fs.read(other.midi)
assert(vim.uv.fs_unlink(file.audio))
select(first);previous=#opened;vim.cmd.LilyPlayer()
select(second);vim.cmd.LilyPlayer()
wait_for(function()return #opened==previous+2 and idle() end,'Concurrent project conversion')
assert(opened[previous+1]==file.audio and opened[previous+2]==other.audio)
local queued_first,queued_second=inspect(file.audio),inspect(other.audio)
assert(queued_first.duration>queued_second.duration+1.5,'Project audio used the wrong MIDI duration')
assert(queued_first.pcm_sha256~=queued_second.pcm_sha256,'Different project music produced identical PCM')
local first_audio=fs.read(file.audio)
assert(vim.uv.fs_utime(other.midi,stamp,stamp))
assert(vim.uv.fs_utime(other.audio,stamp+1,stamp+1))
play(second)
assert(fs.read(file.audio)==first_audio,'Second project replaced the first project audio')
assert(fs.read(file.midi)==changed_midi and fs.read(other.midi)==other_midi)
assert(vim.deep_equal(source,fs.snapshot(first)) and vim.deep_equal(other_source,fs.snapshot(second)))
print('PASS: separate project outputs, back-to-back conversion, and source/MIDI preservation')

-- Standalone scores use their own basename and source identity, including spaces.
local solo=parent..'/Solo score with spaces.ly'
fs.write(solo,[=[\version "2.26.0"
\score {
  \new Staff \with { midiInstrument = "flute" } { d''1 }
  \layout { }
  \midi { \tempo 4 = 120 }
}
]=])
vim.cmd.edit(vim.fn.fnameescape(solo));vim.bo.filetype='lilypond'
local solo_file=compile()
assert(solo_file.audio:sub(-#'Solo score with spaces.wav')=='Solo score with spaces.wav')
assert(solo_file.audio~=file.audio and solo_file.audio~=other.audio)
local solo_source,solo_midi=fs.read(solo),fs.read(solo_file.midi)
play();inspect(solo_file.audio)
assert(fs.read(solo)==solo_source and fs.read(solo_file.midi)==solo_midi)
assert(fs.read(file.audio)==first_audio,'Standalone conversion replaced project audio')
print('PASS: standalone F3 preserves basename, spaced paths, source, MIDI, and other projects')
