local root=vim.fs.dirname(vim.fs.dirname(debug.getinfo(1,'S').source:sub(2)))
local probe=dofile(root..'/tests/support/audio_probe.lua')
local function u16(n)return string.char(n%256,math.floor(n/256)%256)end
local function u32(n)return u16(n%65536)..u16(math.floor(n/65536))end
local function chunk(id,data)return id..u32(#data)..data..(#data%2==1 and '\0' or '')end
local samples={0,32767,-32768,1234,-2345,0}
local bytes={};local sum=0
for _,n in ipairs(samples) do bytes[#bytes+1]=u16(n%65536);sum=sum+n*n end
local pcm=table.concat(bytes)
local fmt=u16(1)..u16(2)..u32(44100)..u32(176400)..u16(4)..u16(16)
local body='WAVE'..chunk('JUNK','x')..chunk('fmt ',fmt)..chunk('data',pcm)
local path=vim.fn.tempname()
local function write(raw)local f=assert(io.open(path,'wb'));f:write(raw);f:close()end
local raw='RIFF'..u32(#body)..body
write(raw)
local value=probe.inspect(path)
assert(value.channels==2 and value.sample_rate==44100 and value.frames==3)
assert(value.duration==3/44100 and value.peak==1 and value.rms==math.sqrt(sum/#samples)/32768)
assert(value.pcm_sha256=='94b5698a1a4afd6afab9d8cd42b3fd1d599478bea7c353a4caa74649b3d14e34',value.pcm_sha256)
for _,broken in ipairs({raw:sub(1,-2),'not wave',raw:gsub('WAVE','AIFF',1)}) do
  write(broken);assert(not pcall(probe.inspect,path),'Malformed audio was accepted')
end
assert(vim.uv.fs_unlink(path))
print('PASS: PCM WAV channels/rate/frames, signed extrema, RMS, binary SHA-256, padded chunks, and malformed/truncated payload rejection')
