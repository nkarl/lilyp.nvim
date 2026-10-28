-- Own the actual LilyPond child, generation publication, and cancellation in Lua.
local M={}
local jobs={}
local stopping=false
local life=require('lilyp.operation_lifecycle')
local out=require('lilyp.operation_outcome')
local resources=require('lilyp.operation_resources')
local function signal(job,number)resources.signal(job.process,number)end
local function key(main)return require('lilyp.source_index').canonical(main)end
function M.running(main)return jobs[key(main)]~=nil end
function M.cancel(main)
  local job=jobs[key(main)]
  if not job or not life.cancellable(job.lifecycle) then return false end
  life.move(job.lifecycle,'cancelling')
  if job.process then
    signal(job,15)
    local ok,err=pcall(function()
      job.escalation=assert(vim.uv.new_timer())
      job.escalation:start(500,0,function()if job.process then signal(job,9)end end)
    end)
    if not ok then job.issues[#job.issues+1]='Cancellation timer: '..tostring(err);signal(job,9) end
  end
  return true
end
function M.compile(opts)
  opts=opts or {}
  assert(not stopping,'Compiler is shutting down')
  local context=opts.context or require('lilyp.score_context').resolve(opts.buf)
  local identity=key(context.main)
  assert(not vim.uv.fs_lstat(context.root..'/.lilypond-curator.lock'),'An Apply operation lock exists; wait for publication to finish before compiling')
  assert(not jobs[identity],'A score build is already running')
  local format=opts.format or 'svg'
  assert(format=='svg' or format=='pdf','Build format must be svg or pdf')
  if opts.save==false then require('lilyp.score_context').assert_clean(context) end
  for _,buf in ipairs(opts.save==false and {} or vim.api.nvim_list_bufs()) do
    local name=vim.api.nvim_buf_get_name(buf)
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified and vim.bo[buf].buftype==''
      and (name==context.main or (vim.startswith(name,context.root..'/') and name:match('%.i?ly$'))) then
      vim.api.nvim_buf_call(buf,function()vim.cmd('write')end)
    end
  end
  local settings=require('lilyp').options()
  context.directory=require('lilyp.output').ensure(context.root,not context.project and context.main or nil)
  if context.project then require('lilyp.output').record(context.root) end
  local includes,extra={},{}
  if require('lilyp.integrations.nvls').enabled then
    local utils=require('nvls.utils')
    extra[#extra+1]='-dinclude-settings='..utils.ensure_midi_helper()
    includes=utils.format_include_dirs(require('nvls').get_nvls_options().lilypond.options.include_dir)
    for _,directory in ipairs(includes) do vim.list_extend(extra,{'-I',directory}) end
  end
  local artifacts=require('lilyp.build_artifacts')
  local release=artifacts.lock(context.directory)
  local job={lifecycle=life.new('build'),context=context,tasks={},issues={}};jobs[identity]=job
  local function defer(label,fn)job.tasks[#job.tasks+1]={label=label,run=fn}end
  defer('Build lock',release)
  defer('Build watchdog',function()resources.timer(job.watchdog)end)
  defer('Cancellation timer',function()resources.timer(job.escalation)end)
  local function finish(result)
    if job.lifecycle.phase=='completed' or job.lifecycle.phase=='cleaning' then return end
    life.move(job.lifecycle,'cleaning')
    resources.clean(job.tasks,result)
    for _,issue in ipairs(job.issues) do result.cleanup[#result.cleanup+1]=issue end
    job.process=nil
    if jobs[identity]==job then jobs[identity]=nil end
    life.complete(job.lifecycle,result)
    -- Completion facts survive observer failures. Notify every independent
    -- observer; none may prevent another observer from seeing publication.
    local function report(message,level)pcall(vim.notify,message,level)end
    local function notify(fn,...)
      local ok,err=pcall(fn,...)
      if not ok then report('Build completion observer failed: '..tostring(err),vim.log.levels.ERROR) end
    end
    if not stopping then
      if result.tag=='succeeded' then
        local response=result.value
        notify(vim.api.nvim_exec_autocmds,'User',{pattern='LylipBuildComplete',data={main=context.main,manifest=context.manifest,format=format}})
        if format=='svg' and require('lilyp.integrations.nvls').enabled and vim.api.nvim_buf_is_valid(context.buf) then
          notify(vim.api.nvim_buf_call,context.buf,function()require('nvls.player').refresh_if_open()end)
        end
        report(format=='svg' and 'SVG score rebuilt' or 'Built PDF: '..response.pdf)
        if opts.on_done then notify(opts.on_done,response,context) end
      else
        local message=result.tag=='cancelled' and 'Build cancelled; previous output retained' or out.message(result)
        if opts.on_error then notify(opts.on_error,message) else report(message,vim.log.levels.ERROR) end
      end
      if #result.cleanup>0 then report(out.message(result),vim.log.levels.WARN) end
    end
    if opts.on_complete then notify(opts.on_complete,result,context) end
  end
  job.finish=finish
  local ok,process=pcall(function()
    local before,signatures=require('lilyp.source_index').snapshot(context.root,context.main,includes)
    local generation=artifacts.generation(context.directory,format)
    defer('Unpublished generation',function(result)
      if result.tag~='succeeded' and result.publication~='partial' then
        assert(vim.fn.delete(generation,'rf')==0,'Could not remove '..generation)
      end
    end)
    local started=vim.uv.fs_stat(generation).mtime
    local args={settings.lilypond,format=='svg' and '--svg' or '--pdf'}
    vim.list_extend(args,require('lilyp.svg_selection').arguments(format,generation,settings.svg_glyph_cache))
    vim.list_extend(args,extra)
    vim.list_extend(args,{'-I',context.root,'-o',generation..'/'..context.name,context.main})
    local child=vim.system(args,{cwd=context.root,text=true,timeout=90000,detach=true},function(result)
      vim.schedule(function()
        if job.lifecycle.phase=='completed' or job.lifecycle.phase=='cleaning' then return end
        job.process=nil
        local success,response=pcall(function()
          if job.lifecycle.phase=='cancelling' then error(out.cancelled(),0) end
          local failure=require('lilyp.process').failure(args,result,90000)
          local log=(result.stdout or '')..(result.stderr or '')
          if require('lilyp.integrations.nvls').enabled then
            vim.fn.setqflist({},'r');require('nvls.errors').process('lilypond',log)
            vim.api.nvim_exec_autocmds('QuickFixCmdPost',{})
          end
          assert(not failure,failure)
          life.move(job.lifecycle,'publishing')
          return artifacts.publish(context,generation,format,before,signatures,log,started,function()life.move(job.lifecycle,'recovering')end)
        end)
        finish(success and out.succeeded(response,'published') or out.from_error(response))
      end)
    end)
    job.process=child
    life.move(job.lifecycle,'running')
    job.watchdog=assert(vim.uv.new_timer())
    job.watchdog:start(90500,0,function()if job.process then signal(job,9)end end)
    return child
  end)
  if not ok then
    -- A setup failure after spawn still owns a live compiler group.
    if job.process then signal(job,9);job.process:wait(1000) end
    finish(out.from_error(process));error(process)
  end
  return process
end
function M.shutdown()
  stopping=true
  local pending={};for _,job in pairs(jobs) do pending[#pending+1]=job end
  for _,job in ipairs(pending) do
    if life.cancellable(job.lifecycle) then life.move(job.lifecycle,'cancelling') end
    if job.lifecycle.phase=='cancelling' then
      signal(job,9)
      if job.process then job.process:wait(1000) end
      job.finish(out.cancelled())
    end
  end
end
vim.api.nvim_create_autocmd('VimLeavePre',{callback=M.shutdown})
return M
