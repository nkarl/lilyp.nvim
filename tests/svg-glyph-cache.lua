local root=vim.fs.dirname(vim.fs.dirname(debug.getinfo(1,'S').source:sub(2)))
vim.opt.rtp:prepend(root)
local fs=require('lilyp.fs')
local app=require('lilyp')
local adapter=require('lilyp.svg_glyph_cache')
local project=fs.stage({})
local compiler=app.options().lilypond
local version=vim.system({compiler,'--version'},{text=true}):wait(3000)
assert(version.code==0,version.stderr)
local supported=version.stdout:match('(%d+%.%d+%.%d+)')=='2.26.0'
local include='\n\\include '..vim.json.encode(adapter.path)..'\n'
local function direct(name,source,extra)
  local path=project..'/'..name..'.ly'
  fs.write(path,'\\version "2.26.0"\n'..source..'\n{ c\'1 }\n')
  local args={compiler,'--svg'};vim.list_extend(args,extra or {})
  vim.list_extend(args,{'-I',project,'-o',project..'/'..name,path})
  local result=vim.system(args,{cwd=project,text=true}):wait(15000)
  local log=(result.stdout or '')..(result.stderr or '')
  assert(result.code==0 and result.signal==0 and not log:lower():find('warning:',1,true),log)
end
local setup=[=[
#(resolve-interface '(lily output-svg))
#(define test-backend (resolve-module '(lily output-svg)))
#(define test-original (module-ref test-backend 'cache-font))
#(define (test-assert value) (unless value (ly:error "Glyph cache contract failed")))
]=]
if supported then
  direct('behavior',setup..[=[
#(define test-calls 0)
#(module-set! test-backend 'cache-font
   (lambda (font size glyph)
     (set! test-calls (+ test-calls 1))
     (cond ((equal? glyph "empty") "")
           ((equal? glyph "false") #f)
           ((equal? glyph "error") (throw 'test-glyph-error))
           (else (format #f "~s" (list font size glyph))))))
]=]..include..[=[
#(define test-cached (module-ref test-backend 'cache-font))
#(test-assert (procedure-property test-cached 'lilyp-svg-glyph-cache))
#(test-assert (equal? (test-cached "font-a" 20 "note") (test-cached "font-a" 20 "note")))
#(test-assert (= test-calls 1))
#(test-assert (not (equal? (test-cached "font-b" 20 "note") (test-cached "font-a" 21 "note"))))
#(test-cached "font-a" 20 "rest")
#(test-assert (= test-calls 4))
#(test-cached "font-a" 20 '(1 2 3))
#(test-cached "font-a" 20 '(1 2 3))
#(test-assert (= test-calls 6))
#(test-assert (string-null? (test-cached "font-a" 20 "empty")))
#(test-assert (string-null? (test-cached "font-a" 20 "empty")))
#(test-assert (= test-calls 7))
#(test-assert (not (test-cached "font-a" 20 "false")))
#(test-assert (not (test-cached "font-a" 20 "false")))
#(test-assert (= test-calls 9))
#(do ((n 0 (+ n 1))) ((= n 2))
   (test-assert (catch 'test-glyph-error
                  (lambda () (test-cached "font-a" 20 "error") #f)
                  (lambda args #t))))
#(test-assert (= test-calls 11))
#(do ((n 0 (+ n 1))) ((= n 5000))
   (test-cached "font-a" 20 (string-append "key-" (number->string n))))
#(define test-full-calls test-calls)
#(test-cached "font-a" 20 "note")
#(test-assert (= test-calls test-full-calls))
#(test-cached "font-a" 20 "key-4999")
#(test-cached "font-a" 20 "key-4999")
#(test-assert (= test-calls (+ test-full-calls 2)))
]=]..include..[=[
#(test-assert (eq? test-cached (module-ref test-backend 'cache-font)))
#(module-set! test-backend 'cache-font test-original)
]=],{'-ddeterministic'})
  direct('unsupported-version',setup..[=[
#(define test-version ly:version)
#(define ly:version (lambda () '(2 27 0)))
]=]..include..[=[
#(test-assert (eq? test-original (module-ref test-backend 'cache-font)))
#(set! ly:version test-version)
]=])
  direct('unsupported-interface',setup..[=[
#(define test-other (lambda (font size) "other interface"))
#(module-set! test-backend 'cache-font test-other)
]=]..include..[=[
#(test-assert (eq? test-other (module-ref test-backend 'cache-font)))
#(module-set! test-backend 'cache-font test-original)
]=])
  direct('other-backend',setup..[=[
#(ly:set-option 'backend 'ps)
]=]..include..[=[
#(test-assert (eq? test-original (module-ref test-backend 'cache-font)))
#(ly:set-option 'backend 'svg)
]=])
else print('SKIP: private 2.26.0 cache-interface checks; installed compiler uses ordinary engraving') end

-- Actual custom SVG font records exercise path identity and size-dependent
-- scaling without installing any fonts or changing the user's font configuration.
for n=1,2 do
  fs.write(project..'/font-'..n..'.svg','<svg><defs>\n<glyph glyph-name="test" unicode="a" d="M0 0 L'..(100*n)..' 0 L100 100 Z"/>\n</defs></svg>\n')
end
local native_probe=[=[
#(resolve-interface '(lily output-svg))
#(let* ((glyph (module-ref (resolve-module '(lily output-svg)) 'cache-font))
        (paths (list (glyph "font-1.svg" 20 "test")
                     (glyph "font-1.svg" 25 "test")
                     (glyph "font-2.svg" 20 "test")
                     (glyph "font-1.svg" 20 "test"))))
   (unless (and (equal? (car paths) (list-ref paths 3))
                (not (equal? (car paths) (cadr paths)))
                (not (equal? (car paths) (caddr paths))))
     (ly:error "Custom glyph identities or sizes were confused"))
   (with-output-to-file "probe.txt" (lambda () (write paths))))
]=]
local source=[=[\version "2.26.0"
\include "check.ily"
]=]..native_probe..[=[
music = \relative c' { \repeat unfold 8 { c8 d e f g a b c } }
\header { title = "Glyph cache parity" tagline = ##f }
\score { \new Staff \music \layout {} }
\score { \new Staff { \magnifyMusic 0.7 \music } \layout {} }
\score { \new Staff \music \midi {} }
]=]
fs.write(project..'/main.ly',source)
vim.cmd.edit(vim.fn.fnameescape(project..'/main.ly'))
local function build(enabled)
  app.setup({build_location='project',svg_glyph_cache=enabled})
  fs.write(project..'/check.ily',string.format([=[#(resolve-interface '(lily output-svg))
#(unless (eq? (not (not (procedure-property (module-ref (resolve-module '(lily output-svg)) 'cache-font) 'lilyp-svg-glyph-cache))) %s)
   (ly:error "Unexpected native glyph cache state"))
]=],enabled and supported and '#t' or '#f'))
  local before=fs.snapshot(project)
  local outcome,artifact
  app.compile({on_done=function(value)artifact=value end,on_complete=function(value)outcome=value end})
  assert(vim.wait(15000,function()return outcome~=nil end,5),'Cache build timed out')
  assert(outcome.tag=='succeeded' and artifact,vim.inspect(outcome))
  assert(not artifact.log:lower():find('warning:',1,true),artifact.log)
  local after=fs.snapshot(project)
  assert(vim.deep_equal(before,after),'Cache build modified source')
  local pages={};for _,path in ipairs(artifact.pages) do pages[#pages+1]=fs.read(path) end
  local _,entries=require('lilyp.svg').index(pages)
  local context=require('lilyp.score_context').resolve()
  return {pages=pages,midi=fs.read(context.directory..'/main.midi'),entries=entries,probe=fs.read(artifact.directory..'/probe.txt')}
end
local baseline=build(false)
local cached=build(true)
assert(vim.deep_equal(baseline,cached),'Cached SVG, MIDI, source links, or custom glyph paths differ')
assert(vim.deep_equal(cached,build(true)),'A fresh compiler reused stale state')
local bundled=adapter.path
local relocated=fs.stage({['hook with spaces.ily']=fs.read(bundled)})
adapter.path=relocated..'/hook with spaces.ily'
assert(vim.deep_equal(cached,build(true)),'A relocated hook changed compilation')
adapter.path=bundled;vim.fn.delete(relocated,'rf')
-- PDF publication must omit the hook even when the SVG preference is enabled.
fs.write(project..'/check.ily',[=[#(resolve-interface '(lily output-svg))
#(when (procedure-property (module-ref (resolve-module '(lily output-svg)) 'cache-font) 'lilyp-svg-glyph-cache)
   (ly:error "PDF publication loaded the SVG hook"))
]=])
local pdf_outcome,pdf
app.compile({format='pdf',on_done=function(value)pdf=value end,on_complete=function(value)pdf_outcome=value end})
assert(vim.wait(15000,function()return pdf_outcome~=nil end,5))
assert(pdf_outcome.tag=='succeeded' and pdf,vim.inspect(pdf_outcome))
assert(fs.read(pdf.directory..'/main.midi')==baseline.midi,'PDF publication changed MIDI')
vim.fn.delete(project,'rf')
print('PASS: cache key isolation, empty paths, stateful bypass, bounded insertion, exception propagation, idempotency, runtime guards, custom SVG fonts/sizes, process isolation, and byte-identical SVG/MIDI/source links')
