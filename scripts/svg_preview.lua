-- Static eye test: nvim --headless -u NONE -i NONE -l scripts/svg_preview.lua PAGE.svg ...
local root=vim.fn.fnamemodify(debug.getinfo(1,'S').source:sub(2),':p:h:h')
vim.opt.rtp:prepend(root)
local fs=require('lilyp.fs')
assert(#arg>0,'Supply SVG pages in display order')
local raw={}
for _,path in ipairs(arg) do assert(path:lower():match('%.svg$'),'Preview pages must be SVG');raw[#raw+1]=fs.read(path) end
local pages=require('lilyp.svg').index(raw)
local directory=assert(vim.uv.fs_mkdtemp('/tmp/lilyp-svg-preview-XXXXXX'))
local objects={}
for _,page in ipairs(pages) do
  objects[#objects+1]=page
end
local html='<!doctype html><html lang="en"><meta charset="utf-8"><title>Lylip SVG eye test</title>'
  ..'<style>body{margin:0;background:#ddd}main{width:max-content;min-width:100%;box-sizing:border-box;padding:24px}'
  ..'main>svg{display:block;max-width:none;background:white;margin:0 auto 24px;box-shadow:0 2px 8px #aaa}'
  ..fs.read(root..'/scripts/svg_viewer/fonts.css')..'</style>'
  ..'<main>'..table.concat(objects)..'</main></html>'
local path=directory..'/index.html';fs.write(path,html)
require('lilyp.viewer_launch').open(vim.uri_from_fname(path))
print(path)
