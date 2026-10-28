-- Keep the lock inode stable. Kernel flock tracks active holders and releases
-- automatically on descriptor close/process exit, including after a crash.
local ffi=require('ffi')
ffi.cdef[[int flock(int fd, int operation);]]
local uv=vim.uv
local M={}
function M.acquire(path)
  local previous=uv.fs_lstat(path)
  assert(not previous or previous.type=='file','Build lock must be a regular file: '..path)
  local fd,open_error=uv.fs_open(path,'a+',384)
  assert(fd,'Could not open build lock: '..path..' ('..tostring(open_error)..')')
  local ok,err=pcall(function()
    local target=assert(uv.fs_lstat(path))
    local actual=assert(uv.fs_fstat(fd))
    assert(target.type=='file' and actual.type=='file' and actual.nlink==1
      and target.dev==actual.dev and target.ino==actual.ino,'Build lock changed while opening: '..path)
    -- LOCK_EX | LOCK_NB. A pre-existing marker alone is not a held lock.
    assert(ffi.C.flock(fd,6)==0,'Another score build is running: '..path..' (flock errno '..ffi.errno()..')')
    actual=assert(uv.fs_fstat(fd))
    assert(actual.size<=4096,'Unrecognized build lock contents: '..path)
    local contents=assert(uv.fs_read(fd,actual.size,0))
    if contents~='' then
      local parsed,owner=pcall(vim.json.decode,contents)
      assert(parsed and type(owner)=='table','Unrecognized build lock contents: '..path)
      if owner.locking~='flock' then
        -- Earlier Lua versions used file existence and PID metadata instead of
        -- a kernel lock. Never take over a live or unverifiable legacy holder.
        assert(type(owner.pid)=='number' and owner.pid>=1 and owner.pid%1==0 and type(owner.token)=='string',
          'Unrecognized legacy build lock: '..path)
        local alive,reason=uv.kill(owner.pid,0)
        assert(not alive and reason and reason:find('ESRCH',1,true),
          'A legacy build may still be running in process '..owner.pid..': '..path..'. Finish that build and restart its editor.')
      end
    end
    local metadata=vim.json.encode({locking='flock',pid=vim.fn.getpid(),token=tostring(uv.hrtime())})
    assert(uv.fs_ftruncate(fd,0))
    local written,failure=uv.fs_write(fd,metadata,0)
    assert(written==#metadata,failure or 'Incomplete build lock write')
  end)
  if not ok then uv.fs_close(fd);error(err,0) end
  local released=false
  return function()
    if released then return end
    released=true
    assert(uv.fs_close(fd)) -- Close releases flock; never unlink a shared inode.
  end
end
return M
