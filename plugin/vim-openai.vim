" ====== Local OpenAI-compatible (lemonade) integration for Vim ======
if !exists('g:llm_host')
  let g:llm_host = 'http://localhost:11434'
endif
if !exists('g:llm_model')
  let g:llm_model = 'gemma-4-E4B-it-qat-GGUF-UD-Q4_K_XL'
endif
if !exists('g:llm_system')
  let g:llm_system = 'You are a helpful assistant. Answer concisely.'
endif
if !exists('g:llm_openai_prefix')
  let g:llm_openai_prefix = '/v1'
endif
if !exists('g:llm_result_bufname')
  let g:llm_result_bufname = '__LLM_RESULT__'
endif
if !exists('g:llm_auth_token')
  let g:llm_auth_token = ''
endif
if !exists('g:llm_additional_prompt')
  let g:llm_additional_prompt = ''
endif

let s:running_jobs = {}
let s:req_seq = 0

" Conversation state for follow-up questions
let s:llm_conv_title      = ''
let s:llm_conv_pane_input = ''
let s:llm_conv_pane_out   = ''
let s:llm_conv_follow_ups = []   " [{q: '...', a: '...'}]
let s:llm_conv_api_msgs   = []   " full messages array for API context

" Returns the visual selection as a string.
function! s:GetVisualSelection() abort
  let [l1, c1] = getpos("'<")[1:2]
  let [l2, c2] = getpos("'>")[1:2]
  if l1 > l2 || (l1 == l2 && c1 > c2)
    let [l1, c1, l2, c2] = [l2, c2, l1, c1]
  endif
  let lines = getline(l1, l2)
  if empty(lines)
    return ''
  endif
  let lines[0] = lines[0][c1 - 1 :]
  let lines[-1] = lines[-1][: c2 - 1]
  return join(lines, "\n")
endfunction

" This function opens a new scratch buffer with a specified title and text
" content, formatted as a Markdown heading.
function! s:OpenScratch(title, text) abort
  botright new
  setlocal buftype=nofile bufhidden=wipe nobuflisted noswapfile
  setlocal filetype=markdown
  call setline(1, ['# ' . a:title, '', a:text])
  normal! gg
endfunction

" Function to handle the curl-out event.  It checks if a message is present
" and, if so, appends it to the context's standard output.
function! s:OnCurlOut(ctx, job, msg) abort
endfunction

function! s:PollStreamFile(ctx, timer_id) abort
  if !filereadable(a:ctx.resp)
    return
  endif

  let all_lines = readfile(a:ctx.resp)
  let new_lines = all_lines[a:ctx.file_lines_done :]
  if empty(new_lines)
    return
  endif

  let changed = 0
  for line in new_lines
    let a:ctx.file_lines_done += 1
    if line !~# '^data:\s*'
      continue
    endif
    let json_str = substitute(line, '^data:\s*', '', '')
    if json_str ==# '[DONE]'
      continue
    endif
    try
      let chunk = json_decode(json_str)
      if has_key(chunk, 'choices') && len(chunk.choices) > 0
            \ && has_key(chunk.choices[0], 'delta')
        let delta = chunk.choices[0].delta
        if has_key(delta, 'content') && type(delta.content) == v:t_string
          let a:ctx.accumulated .= delta.content
          let changed = 1
        endif
      endif
    catch
    endtry
  endfor

  if changed && a:ctx.on_chunk isnot v:null
    call call(a:ctx.on_chunk, [a:ctx.accumulated])
  endif
endfunction

" Defines a function `s:OnCurlErr` to handle cURL errors. It checks if the
" error message (`a:msg`) is not empty; if so, it appends the message to the
" context's standard error output (`a:ctx.stderr`) and then aborts.
function! s:OnCurlErr(ctx, job, msg) abort
  if a:msg isnot# ''
    call add(a:ctx.stderr, a:msg)
  endif
endfunction

" This function handles the completion of an external process or job after an
" operation (likely an LLM request). It cleans up temporary files, checks the
" exit status and response body, parses the response as JSON if possible, and
" finally calls a callback function with the result (success/failure and
" content/error details).
function! s:OnCurlExit(ctx, job, status) abort
  if has_key(a:ctx, 'timer')
    call timer_stop(a:ctx.timer)
  endif

  call s:PollStreamFile(a:ctx, -1)

  if has_key(a:ctx, 'req_id')
    call remove(s:running_jobs, a:ctx.req_id)
  endif

  if has_key(a:ctx, 'tmp_req') && filereadable(a:ctx.tmp_req)
    call delete(a:ctx.tmp_req)
  endif
  if has_key(a:ctx, 'resp') && filereadable(a:ctx.resp)
    call delete(a:ctx.resp)
  endif

  let err = join(a:ctx.stderr, "\n")

  if a:status != 0
    call s:DeferCall(a:ctx.on_done, [v:false, 'LLM request failed (exit=' . a:status . ")\n" . err])
    return
  endif

  if empty(a:ctx.accumulated)
    call s:DeferCall(a:ctx.on_done, [v:false, "Empty response.\n" . err])
    return
  endif

  call s:DeferCall(a:ctx.on_done, [v:true, a:ctx.accumulated])
endfunction

" Defers the execution of a function call by scheduling it to run after a short
" delay using `timer_start`.
function! s:DeferCall(Fn, args) abort
  call timer_start(0, {-> call(a:Fn, a:args)})
endfunction

" Core async function: accepts a full messages array and sends to the API.
function! s:CallOpenAIChatAsyncMsgs(messages, on_done, ...) abort
  let On_chunk = a:0 >= 1 ? a:1 : v:null

  let payload = {
        \ 'model': g:llm_model,
        \ 'messages': a:messages,
        \ 'stream': v:true
        \ }

  let json = json_encode(payload)
  let url  = g:llm_host . g:llm_openai_prefix . '/chat/completions'

  let tmp_req = tempname()
  call writefile([json], tmp_req, 'b')
  let tmp_resp = tempname()

  let cmd = ['curl', '-sS', '--fail', '--no-buffer']

  if !empty(g:llm_auth_token)
    call extend(cmd, ['-H', 'Authorization: Bearer ' . g:llm_auth_token])
  endif

  call extend(cmd, [
        \ '-H', 'Content-Type: application/json',
        \ url,
        \ '--data-binary', '@' . tmp_req,
        \ '--output', tmp_resp,
        \ ])

  let ctx = {'stderr': [], 'tmp_req': tmp_req, 'resp': tmp_resp,
        \    'on_done': a:on_done, 'on_chunk': On_chunk,
        \    'accumulated': '', 'file_lines_done': 0}

  let opts = {
        \ 'err_cb':  function('s:OnCurlErr',  [ctx]),
        \ 'exit_cb': function('s:OnCurlExit', [ctx]),
        \ }

  let job = job_start(cmd, opts)

  if type(job) != v:t_job
    if filereadable(tmp_req)  | call delete(tmp_req)  | endif
    if filereadable(tmp_resp) | call delete(tmp_resp) | endif
    throw 'Failed to start job (curl)'
  endif

  let s:req_seq += 1
  let ctx.req_id = s:req_seq
  let ctx.job = job
  let s:running_jobs[ctx.req_id] = ctx

  let ctx.timer = timer_start(100, function('s:PollStreamFile', [ctx]), {'repeat': -1})

  return job
endfunction

" Convenience wrapper: single user message with system prompt.
function! s:CallOpenAIChatAsync(userText, on_done, ...) abort
  let On_chunk = a:0 >= 1 ? a:1 : v:null
  let messages = [
        \ {'role': 'system', 'content': g:llm_system},
        \ {'role': 'user',   'content': a:userText},
        \ ]
  return s:CallOpenAIChatAsyncMsgs(messages, a:on_done, On_chunk)
endfunction

function! s:EnsureResultPane() abort
  let bn = bufnr(g:llm_result_bufname)

  if bn == -1
    execute 'silent keepalt keepjumps botright vsplit ' . fnameescape(g:llm_result_bufname)
    let bn = bufnr('%')

    setlocal buftype=nofile bufhidden=hide nobuflisted noswapfile
    setlocal filetype=markdown
    setlocal nomodifiable
    setlocal winfixwidth
    silent execute 'vertical resize 60'

    return bn
  endif

  let wnr = bufwinnr(bn)
  if wnr == -1
    execute 'silent keepalt keepjumps botright vsplit'
    execute 'buffer ' . bn
    setlocal winfixwidth
    silent execute 'vertical resize 60'
  endif

  return bn
endfunction

" Build display lines from the current conversation state.
" a:mode: 'stream' (no folds) or 'final' (apply folds)
function! s:BuildConvLines(input, output_text, follow_ups) abort
  let inp = substitute(a:input, "\r\n", "\n", 'g')
  let inp = substitute(inp, "\r", "\n", 'g')
  let out = substitute(a:output_text, "\r\n", "\n", 'g')
  let out = substitute(out, "\r", "\n", 'g')
  let out = substitute(out, '\(<\/think>\)\ze.', "\\1\n", 'g')

  let lines =
        \ ['# ' . s:llm_conv_title,
        \  '',
        \  '## Input (folded)',
        \  ''] + split(inp, "\n", 1) +
        \ ['',
        \  '## Output',
        \  ''] + split(out, "\n", 1)

  let n = 1
  for fu in a:follow_ups
    let fu_q = substitute(fu.q, "\r\n", "\n", 'g')
    let fu_q = substitute(fu_q, "\r", "\n", 'g')
    let fu_a = substitute(fu.a, "\r\n", "\n", 'g')
    let fu_a = substitute(fu_a, "\r", "\n", 'g')
    let fu_a = substitute(fu_a, '\(<\/think>\)\ze.', "\\1\n", 'g')
    let lines += ['', '## Follow-up ' . n, '']
          \ + split(fu_q, "\n", 1)
          \ + ['', '## Answer ' . n, '']
          \ + split(fu_a, "\n", 1)
    let n += 1
  endfor

  return lines
endfunction

function! s:WriteLinesToResultBuf(bn, lines) abort
  call setbufvar(a:bn, '&modifiable', 1)
  call setbufline(a:bn, 1, a:lines)
  let new_last = len(a:lines)
  let old_last = len(getbufline(a:bn, 1, '$'))
  if old_last > new_last
    call deletebufline(a:bn, new_last + 1, '$')
  endif
  call setbufvar(a:bn, '&modifiable', 0)
endfunction

" Render result pane with folds applied (final state).
function! s:RenderResultWithInput(title, input, output_text, ...) abort
  let follow_ups = a:0 >= 1 ? a:1 : []
  let bn = s:EnsureResultPane()

  let lines = s:BuildConvLines(a:input, a:output_text, follow_ups)
  call s:WriteLinesToResultBuf(bn, lines)

  call s:ApplyInputFold(bn)
  call s:ApplyThinkFold(bn)

  let winid = bufwinid(bn)
  if winid != -1
    call win_execute(winid, 'normal! G')
  endif
endfunction

" Render result pane during streaming (no folds, scroll to bottom).
function! s:RenderStreamChunk(title, input, output_text, ...) abort
  let follow_ups = a:0 >= 1 ? a:1 : []
  let bn = bufnr(g:llm_result_bufname)
  if bn == -1
    return
  endif

  let lines = s:BuildConvLines(a:input, a:output_text, follow_ups)
  call s:WriteLinesToResultBuf(bn, lines)

  let wnr = bufwinnr(bn)
  if wnr != -1
    call win_execute(wnr, 'normal! G')
  endif
endfunction

" Move the result pane so that "## Follow-up N" is at the top of the window.
function! s:ScrollToFollowUp(bn, n) abort
  let winid = bufwinid(a:bn)
  if winid == -1
    return
  endif
  let target = '## Follow-up ' . a:n
  let all = getbufline(a:bn, 1, '$')
  for i in range(0, len(all) - 1)
    if all[i] ==# target
      call win_execute(winid, printf('call cursor(%d, 1) | normal! zt', i + 1))
      return
    endif
  endfor
endfunction

function! s:ApplyInputFold(bn) abort
  let wnr = bufwinid(a:bn)
  if wnr == -1
    call setbufvar(a:bn, 'llm_pending_fold', 1)
    return
  endif

  " zE and zC move the cursor; save/restore so callers control final position
  call win_execute(wnr, 'let s:_fold_view = winsaveview()')
  call win_execute(wnr, 'setlocal foldmethod=manual')
  call win_execute(wnr, 'silent! normal! zE')

  let lnum = 0
  let all = getbufline(a:bn, 1, '$')
  for i in range(0, len(all)-1)
    if all[i] ==# '## Input (folded)'
      let lnum = i + 1
      break
    endif
  endfor
  if lnum == 0
    return
  endif

  let start = lnum
  let end = 0
  let out_lnum = 0
  for i in range(lnum, len(all))
    if all[i-1] ==# '## Output'
      let out_lnum = i
      let end = (i - 1) - 1  " "## Output"
      break
    endif
  endfor
  if end <= start
    return
  endif

  call win_execute(wnr, printf('silent! %d,%dfold', start, end))
  call win_execute(wnr, printf('silent! %dnormal! zC', lnum))
  call win_execute(wnr, 'call winrestview(s:_fold_view)')
endfunction

function! s:ApplyThinkFold(bn) abort
  let wnr = bufwinid(a:bn)
  if wnr == -1
    return
  endif

  call win_execute(wnr, 'let s:_think_fold_view = winsaveview()')

  let all = getbufline(a:bn, 1, '$')
  let think_start = 0

  for i in range(0, len(all)-1)
    if all[i] =~# '<think>'
      let think_start = i + 1
    elseif all[i] =~# '</think>' && think_start > 0
      let think_end = i + 1
      if think_end > think_start
        call win_execute(wnr, printf('silent! %d,%dfold', think_start, think_end))
        call win_execute(wnr, printf('silent! %dnormal! zC', think_start))
      endif
      let think_start = 0
    endif
  endfor

  call win_execute(wnr, 'call winrestview(s:_think_fold_view)')
endfunction

augroup llm_result_pane
  autocmd!
  autocmd BufWinEnter,BufEnter __LLM_RESULT__ call s:ForceResultWinOptions()
augroup END

function! s:ForceResultWinOptions() abort
  setlocal wrap
  setlocal linebreak
  setlocal nonumber
  setlocal norelativenumber
  setlocal foldmethod=manual
  setlocal foldenable
  setlocal foldlevel=0
  call s:MaybeApplyPendingFold()
endfunction

function! s:MaybeApplyPendingFold() abort
  let bn = bufnr('%')
  if &l:buftype ==# 'nofile' && bufname('%') ==# g:llm_result_bufname
        \ && getbufvar(bn, 'llm_pending_fold', 0)
    call s:ApplyInputFold(bn)
    call s:ApplyThinkFold(bn)
    call setbufvar(bn, 'llm_pending_fold', 0)
  endif
endfunction

function! LLMFromVisual() range abort
  try
    let text = s:GetVisualSelection()
    if empty(text)
      echohl WarningMsg | echom 'No selection' | echohl None
      return
    endif

    let title  = 'LLM Result (OpenAI compat: ' . g:llm_model . ')'
    let prompt = text
    call s:RunLLMRequest(title, prompt)

  catch
    echohl ErrorMsg | echom v:exception | echohl None
  endtry
endfunction

function! LLMAskFromVisual(...) range abort
  try
    let selected = s:GetVisualSelection()
    if empty(selected)
      echohl WarningMsg | echom 'No selection' | echohl None
      return
    endif

    if a:0 >= 1
      let q = a:1
    else
      let q = input('Question for selection: ')
    endif

    if empty(q)
      echohl WarningMsg | echom 'Canceled' | echohl None
      return
    endif

    let prompt =
          \ "You are given a text selection.\n"
          \ . "=== SELECTION BEGIN ===\n"
          \ . selected . "\n"
          \ . "=== SELECTION END ===\n\n"
          \ . "Question: " . q . "\n"
          \ . "Answer based on the selection (if insufficient, say so)."

    if exists('g:llm_additional_prompt') && !empty(g:llm_additional_prompt)
      let prompt .= "\n\n" . g:llm_additional_prompt
    endif

    let title = 'LLM Q&A (' . g:llm_model . ')'

    call s:RunLLMRequest(title, prompt)

  catch
    echohl ErrorMsg | echom v:exception | echohl None
  endtry
endfunction

function! s:OnLLMChunkWrapper(title, prompt, text) abort
  call s:RenderStreamChunk(a:title, a:prompt, a:text, s:llm_conv_follow_ups)
endfunction

function! s:OnLLMDoneWrapper(title, prompt, ok, text) abort
  if a:ok
    let s:llm_conv_pane_out = a:text
    call add(s:llm_conv_api_msgs, {'role': 'assistant', 'content': a:text})
    call s:RenderResultWithInput(a:title, a:prompt, a:text, s:llm_conv_follow_ups)
  else
    call s:RenderResultWithInput(a:title, a:prompt, "ERROR\n\n" . a:text, s:llm_conv_follow_ups)
  endif
endfunction

function! s:RunLLMRequest(title, prompt) abort
  " Initialize conversation state for a new request
  let s:llm_conv_title      = a:title
  let s:llm_conv_pane_input = a:prompt
  let s:llm_conv_pane_out   = ''
  let s:llm_conv_follow_ups = []
  let s:llm_conv_api_msgs   = [
        \ {'role': 'system', 'content': g:llm_system},
        \ {'role': 'user',   'content': a:prompt},
        \ ]

  call s:RenderResultWithInput(a:title, a:prompt, 'Thinking...')

  let s:last_job = s:CallOpenAIChatAsync(
        \ a:prompt,
        \ function('s:OnLLMDoneWrapper', [a:title, a:prompt]),
        \ function('s:OnLLMChunkWrapper', [a:title, a:prompt])
        \ )

  echo ''
endfunction

" Ask a follow-up question in the currently open result pane.
function! LLMFollowUp(...) abort
  try
    if empty(s:llm_conv_api_msgs)
      echohl WarningMsg
      echom 'LLM: No active conversation. Use <leader>q or <leader>o first.'
      echohl None
      return
    endif

    let q = a:0 >= 1 ? a:1 : input('Follow-up: ')
    if empty(q)
      echohl WarningMsg | echom 'Canceled' | echohl None
      return
    endif

    call add(s:llm_conv_api_msgs, {'role': 'user', 'content': q})
    call add(s:llm_conv_follow_ups, {'q': q, 'a': 'Thinking...'})

    call s:RenderStreamChunk(s:llm_conv_title, s:llm_conv_pane_input,
          \ s:llm_conv_pane_out, s:llm_conv_follow_ups)
    call s:ScrollToFollowUp(bufnr(g:llm_result_bufname), len(s:llm_conv_follow_ups))

    let s:last_job = s:CallOpenAIChatAsyncMsgs(
          \ deepcopy(s:llm_conv_api_msgs),
          \ function('s:OnFollowUpDone'),
          \ function('s:OnFollowUpChunk')
          \ )

    echo ''
  catch
    echohl ErrorMsg | echom v:exception | echohl None
  endtry
endfunction

function! s:OnFollowUpChunk(accumulated) abort
  if !empty(s:llm_conv_follow_ups)
    let s:llm_conv_follow_ups[-1].a = a:accumulated
  endif
  let n = len(s:llm_conv_follow_ups)
  call s:RenderStreamChunk(s:llm_conv_title, s:llm_conv_pane_input,
        \ s:llm_conv_pane_out, s:llm_conv_follow_ups)
  call s:ScrollToFollowUp(bufnr(g:llm_result_bufname), n)
endfunction

function! s:OnFollowUpDone(ok, text) abort
  if a:ok
    if !empty(s:llm_conv_follow_ups)
      let s:llm_conv_follow_ups[-1].a = a:text
    endif
    call add(s:llm_conv_api_msgs, {'role': 'assistant', 'content': a:text})
  else
    if !empty(s:llm_conv_follow_ups)
      let s:llm_conv_follow_ups[-1].a = "ERROR\n\n" . a:text
    endif
    " Remove the failed user message so the conversation stays consistent
    if !empty(s:llm_conv_api_msgs) && s:llm_conv_api_msgs[-1].role ==# 'user'
      call remove(s:llm_conv_api_msgs, -1)
    endif
  endif
  let n = len(s:llm_conv_follow_ups)
  call s:RenderResultWithInput(s:llm_conv_title, s:llm_conv_pane_input,
        \ s:llm_conv_pane_out, s:llm_conv_follow_ups)
  call s:ScrollToFollowUp(bufnr(g:llm_result_bufname), n)
endfunction

function! s:LogToFile(line) abort
  call writefile([strftime('%Y-%m-%d %H:%M:%S ') . a:line], expand('~/vim_llm.log'), 'a')
endfunction

function! s:FetchModelNames() abort
  let cmd = ['curl', '-sS', '--max-time', '5']
  if !empty(g:llm_auth_token)
    call extend(cmd, ['-H', 'Authorization: Bearer ' . g:llm_auth_token])
  endif
  call add(cmd, g:llm_host . g:llm_openai_prefix . '/models')

  let out = system(cmd)
  if v:shell_error != 0
    echohl ErrorMsg | echom 'LLM: /v1/models fetch failed' | echohl None
    return []
  endif

  try
    let res = json_decode(out)
  catch
    echohl ErrorMsg | echom 'LLM: JSON parse failed' | echohl None
    return []
  endtry

  if type(res) != v:t_dict || !has_key(res, 'data')
    return []
  endif
  return map(copy(res.data), {_, m -> m.id})
endfunction

function! LLMSelectModel() abort
  let names = s:FetchModelNames()
  if empty(names)
    echohl WarningMsg | echom 'LLM: No models found' | echohl None
    return
  endif

  let items = ['Select LLM model (0 to cancel):']
  let i = 1
  for name in names
    let mark = (name ==# g:llm_model) ? ' [current]' : ''
    call add(items, printf('%2d. %s%s', i, name, mark))
    let i += 1
  endfor

  let choice = inputlist(items)
  if choice < 1 || choice > len(names)
    echom 'LLM: Canceled'
    return
  endif

  let g:llm_model = names[choice - 1]
  echom 'LLM: model -> ' . g:llm_model
endfunction

command! LLMSelectModel call LLMSelectModel()
command! LLMFollowUp    call LLMFollowUp()

xnoremap <silent> <leader>q :<C-u>call LLMAskFromVisual()<CR>
xnoremap <silent> <leader>o :<C-u>call LLMFromVisual()<CR>
nnoremap <silent> <leader>f :call LLMFollowUp()<CR>
