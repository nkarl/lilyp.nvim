-- Read PCM16 RIFF/WAVE directly; no audio device or external interpreter.
local M={}
function M.inspect(path)
  local file=assert(io.open(path,'rb'));local raw=file:read('*a');file:close()
  local function u16(at)local a,b=raw:byte(at,at+1);assert(b,'Truncated WAV');return a+b*256 end
  local function u32(at)return u16(at)+u16(at+2)*65536 end
  assert(raw:sub(1,4)=='RIFF' and raw:sub(9,12)=='WAVE','Expected RIFF/WAVE')
  assert(u32(5)+8<=#raw,'Truncated RIFF payload')
  local channels,rate,align,bits,data
  local cursor=13
  while cursor+7<=#raw do
    local id,size=raw:sub(cursor,cursor+3),u32(cursor+4)
    local first=cursor+8
    assert(first+size-1<=#raw,'Truncated WAV chunk')
    if id=='fmt ' then
      assert(size>=16 and u16(first)==1,'Expected uncompressed PCM WAV')
      channels,rate,align,bits=u16(first+2),u32(first+4),u16(first+12),u16(first+14)
    elseif id=='data' then data=raw:sub(first,first+size-1) end
    cursor=first+size+size%2
  end
  assert(channels and channels>0 and rate>0 and bits==16 and align==channels*2,'Expected 16-bit PCM samples')
  assert(data and #data>0 and #data%align==0,'Empty or truncated WAV payload')
  local peak,sum=0,0
  for n=1,#data,2 do
    local sample=data:byte(n)+data:byte(n+1)*256
    if sample>=32768 then sample=sample-65536 end
    peak=math.max(peak,math.abs(sample));sum=sum+sample*sample
  end
  local frames=#data/align
  return {channels=channels,sample_rate=rate,frames=frames,duration=frames/rate,
    peak=peak/32768,rms=math.sqrt(sum/(#data/2))/32768,pcm_sha256=vim.fn.sha256(data)}
end
return M
