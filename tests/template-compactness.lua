local this=debug.getinfo(1,'S').source:sub(2)
local root=vim.env.LILYP_TEMPLATE_PLUGIN or vim.fs.dirname(vim.fs.dirname(this))
vim.opt.rtp:prepend(root)
local fs=require('lilyp.fs')
local scaffold=require('lilyp.scaffold')
local parent=vim.env.LILYP_TEMPLATE_OUTPUT or vim.fn.tempname()
vim.fn.mkdir(parent,'p')
-- Optional frozen setup values let local runs exercise the user's configured fonts.
local captured=vim.env.LILYP_TEMPLATE_DEFAULTS and vim.json.decode(fs.read(vim.env.LILYP_TEMPLATE_DEFAULTS)) or {}
captured.engraving_template = captured.engraving_template or root .. '/tests/engraving-fixture.ily'
scaffold.setup(captured)
local defaults_path=parent..'/defaults.json';fs.write(defaults_path,vim.json.encode(captured))
local cases={'default','satb','mixed','treble','bass','pdf-only'}
local counts={}
local function run(args)
  local r=vim.system(args,{text=true}):wait(30000)
  local log=(r.stdout or '')..(r.stderr or '')
  assert(r.code==0 and not log:lower():find('warning:',1,true),log)
end
for _,case in ipairs(cases) do
  local o=scaffold.defaults()
  o.title='Template review';o.project_directory=parent..'/'..case
  if case=='satb' then o.preset='satb';o.lyrics=true;o.lyric_verses=2 end
  if case=='mixed' then
    o.lyrics=true;o.sections={{id='section_a',type='refrain',name='Section A',verses=1,staff_preset='piano'},
      {id='section_b',type='verse',name='Section B',verses=2,staff_preset='satb'}}
  end
  if case=='treble' then o.preset='treble';o.lyrics=true;o.lyric_verses=3;o.chords=false;o.pickup='8';o.engraving_mode='default' end
  if case=='bass' then o.preset='bass';o.lyrics=true;o.lyric_verses=1;o.chords=false;o.engraving_mode='include' end
  if case=='pdf-only' then o.preset='piano';o.lyrics=false;o.chords=false;o.midi=false;o.engraving_mode='default' end
  local source=scaffold.prepare(o)
  local path=require('lilyp.build').create(source,o)
  local snapshot=fs.snapshot(o.project_directory)
  local lines=0
  for rel,text in pairs(snapshot) do
    if rel:match('%.i?ly$') then
      for _ in text:gmatch('\n') do lines=lines+1 end
      if vim.env.LILYP_TEMPLATE_CHILD~='1' then
        assert(not text:find('\n\n\n',1,true),'Repeated blank lines: '..case..'/'..rel)
        assert(not text:find('\\with {%s*}'),'Empty settings block: '..rel)
        assert(not text:find('Replace this full-bar placeholder',1,true),'Repeated per-voice instructions')
      end
    end
  end
  if vim.env.LILYP_TEMPLATE_CHILD~='1' then
    local main,styling=snapshot['main.ly'],snapshot['style.ily']
    assert(not main:find('Shared palette',1,true) and styling:find('Shared palette',1,true))
    assert(not main:find('Insert between separate layout',1,true) and styling:find('Insert between separate layout',1,true))
    if o.engraving_mode=='embed' then assert(not main:find('Snapshot of engraving',1,true) and styling:find('Snapshot of engraving',1,true)) end
  end
  counts[case]=lines
  vim.fn.mkdir(o.project_directory..'/build','p')
  run({'lilypond','-o',o.project_directory..'/build/main',path})
  run({'pdftoppm','-r','72','-png',o.project_directory..'/build/main.pdf',o.project_directory..'/build/page'})
end
fs.write(parent..'/counts.json',vim.json.encode(counts))
if vim.env.LILYP_TEMPLATE_CHILD=='1' then return end
local format=require('lilyp.generated_format')
local protected='value = "a\n\n\nb"\n%{\na\n\n\nb\n%}\n'
assert(format.normalize(protected)==protected,'Whitespace inside strings/comments changed')
assert(format.normalize('\n\na\n\n\nb\n\n')=='a\n\nb\n')
local reference=vim.env.LILYP_TEMPLATE_REFERENCE
if reference then
  local previous=parent..'/reference'
  local r=vim.system({'nvim','--headless','-u','NONE','-i','NONE','-l',this},{text=true,env={
    LILYP_TEMPLATE_PLUGIN=reference,LILYP_TEMPLATE_OUTPUT=previous,LILYP_TEMPLATE_DEFAULTS=defaults_path,LILYP_TEMPLATE_CHILD='1'}}):wait(30000)
  assert(r.code==0,(r.stdout or '')..(r.stderr or ''))
  local previous_counts=vim.json.decode(fs.read(previous..'/counts.json'))
  local function pages(path)
    local result={}
    for name,kind in vim.fs.dir(path) do if kind=='file' and name:match('^page%-%d+%.png$') then result[name]=fs.read(path..'/'..name) end end
    return result
  end
  for _,case in ipairs(cases) do
    local after,before=parent..'/'..case,previous..'/'..case
    assert(vim.deep_equal(pages(before..'/build'),pages(after..'/build')),'PDF changed: '..case)
    local old_midi=vim.fn.filereadable(before..'/build/main.midi')==1
    assert(old_midi==(vim.fn.filereadable(after..'/build/main.midi')==1))
    if old_midi then assert(fs.read(before..'/build/main.midi')==fs.read(after..'/build/main.midi'),'MIDI changed: '..case) end
    assert(fs.read(before..'/score.yaml')==fs.read(after..'/score.yaml'),'Specification changed: '..case)
    assert(counts[case]<previous_counts[case],case..': line count did not improve')
    print(case..': '..previous_counts[case]..' -> '..counts[case]..' LilyPond lines; identical pages and MIDI')
  end
end
print('PASS: compact templates, attached comments, protected literal whitespace, all presets/font modes, and optional reference PDF/MIDI parity')
print('Artifacts: '..parent)
