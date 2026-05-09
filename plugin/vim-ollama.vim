" ====== Local OpenAI-compatible (lemonade) integration for Vim ======
if !exists('g:llm_host')
  let g:llm_host = 'http://localhost:11434'
endif
if !exists('g:llm_model')
  let g:llm_model = 'Gemma-4-E4B-it-GGUF'
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

let s:running_jobs = {}
let s:req_seq = 0

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
  if a:msg isnot# ''
    call add(a:ctx.stdout, a:msg)
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
  if has_key(a:ctx, 'req_id')
    call remove(s:running_jobs, a:ctx.req_id)
  endif

  let err = join(a:ctx.stderr, "\n")

  let body = ''
  if has_key(a:ctx, 'resp') && filereadable(a:ctx.resp)
    let body = join(readfile(a:ctx.resp, 'b'), "\n")
  endif

  if has_key(a:ctx, 'tmp') && filereadable(a:ctx.tmp)
    call delete(a:ctx.tmp)
  endif
  if has_key(a:ctx, 'resp') && filereadable(a:ctx.resp)
    call delete(a:ctx.resp)
  endif

  if a:status != 0
    call s:DeferCall(a:ctx.on_done, [v:false, 'LLM request failed (exit=' . a:status . ")\n" . err . "\n" . body])
    return
  endif

  if empty(body)
    call s:DeferCall(a:ctx.on_done, [v:false, "Empty response body.\n" . err])
    return
  endif

  try
    let res = json_decode(body)
  catch
    call s:DeferCall(a:ctx.on_done, [v:false, "Invalid JSON response:\n" . body])
    return
  endtry

  if type(res) == v:t_dict
        \ && has_key(res, 'choices') && len(res.choices) > 0
        \ && has_key(res.choices[0], 'message')
        \ && has_key(res.choices[0].message, 'content')
    call s:DeferCall(a:ctx.on_done, [v:true, res.choices[0].message.content])
    return
  endif

  call s:DeferCall(a:ctx.on_done, [v:true, body])
endfunction

" Defers the execution of a function call by scheduling it to run after a short
" delay using `timer_start`.
function! s:DeferCall(Fn, args) abort
  call timer_start(0, {-> call(a:Fn, a:args)})
endfunction

" Asynchronously calls the OpenAI Chat API endpoint. It constructs the request
" payload using predefined global variables (model, system prompt), writes it
" to a temporary file, executes 'curl' to send the request, and manages the
" execution job. It notifies the provided callback function upon completion."
function! s:CallOpenAIChatAsync(userText, on_done) abort
  let payload = {
        \ 'model': g:llm_model,
        \ 'messages': [
        \   {'role': 'system', 'content': g:llm_system},
        \   {'role': 'user', 'content': a:userText},
        \ ],
        \ 'stream': v:false
        \ }

  let json = json_encode(payload)
  let url  = g:llm_host . g:llm_openai_prefix . '/chat/completions'

  let tmp_req = tempname()
  call writefile([json], tmp_req, 'b')

  let tmp_resp = tempname()
  let cmd = [
        \ 'curl', '-sS', '--fail',
        \ '-H', 'Content-Type: application/json',
        \ url,
        \ '--data-binary', '@' . tmp_req,
        \ '--output', tmp_resp,
        \ ]

  let ctx = {'stdout': [], 'stderr': [], 'tmp_req': tmp_req, 'resp': tmp_resp, 'on_done': a:on_done}

  let opts = {
        \ 'out_cb':  function('s:OnCurlOut',  [ctx]),
        \ 'err_cb':  function('s:OnCurlErr',  [ctx]),
        \ 'exit_cb': function('s:OnCurlExit', [ctx]),
        \ }

  let job = job_start(cmd, opts)

  if type(job) != v:t_job
    if filereadable(tmp_req) | call delete(tmp_req) | endif
    throw 'Failed to start job (curl)'
  endif

  let s:req_seq += 1
  let ctx.req_id = s:req_seq
  let ctx.job = job
  let s:running_jobs[ctx.req_id] = ctx

  return job
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
    execute 'vertical resize 60'

    return bn
  endif

  let wnr = bufwinnr(bn)
  if wnr == -1
    execute 'silent keepalt keepjumps botright vsplit'
    execute 'buffer ' . bn
    setlocal winfixwidth
    execute 'vertical resize 60'
  endif

  return bn
endfunction

function! s:RenderResultWithInput(title, input, output_text) abort
  let bn = s:EnsureResultPane()

  let inp = substitute(a:input, "\r\n", "\n", 'g')
  let inp = substitute(inp, "\r", "\n", 'g')
  let out = substitute(a:output_text, "\r\n", "\n", 'g')
  let out = substitute(out, "\r", "\n", 'g')

  let in_lines  = split(inp, "\n", 1)
  let out_lines = split(out, "\n", 1)

  let lines =
        \ ['# ' . a:title,
        \  '',
        \  '## Input (folded)',
        \  ''] + in_lines +
        \ ['',
        \  '## Output',
        \  ''] + out_lines

  call setbufvar(bn, '&modifiable', 1)
  call setbufline(bn, 1, lines)

  let new_last = len(lines)
  let old_last = len(getbufline(bn, 1, '$'))
  if old_last > new_last
    call deletebufline(bn, new_last + 1, '$')
  endif
  call setbufvar(bn, '&modifiable', 0)

  call s:ApplyInputFold(bn)

  let wnr = bufwinnr(bn)
  if wnr != -1
    call win_execute(wnr, 'normal! gg')
  endif
endfunction

function! s:ApplyInputFold(bn) abort
  let wnr = bufwinid(a:bn)
  if wnr == -1
    call setbufvar(a:bn, 'llm_pending_fold', 1)
    return
  endif

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

  let start = lnum + 1
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

  let start = lnum
  call win_execute(wnr, printf('silent! %d,%dfold', start, end))
  call win_execute(wnr, printf('silent! %dnormal! zC', lnum))
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
  if &l:buftype ==# 'nofile' && bufname('%') ==# g:llm_result_bufname
    call s:ApplyInputFold(bufnr('%'))
    call setbufvar(bufnr('%'), 'llm_pending_fold', 0)
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

    let title = 'LLM Q&A (' . g:llm_model . ')'

    call s:RunLLMRequest(title, prompt)

  catch
    echohl ErrorMsg | echom v:exception | echohl None
  endtry
endfunction

function! s:OnLLMDoneWrapper(title, prompt, ok, text) abort
  if a:ok
    call s:RenderResultWithInput(a:title, a:prompt, a:text)
  else
    call s:RenderResultWithInput(a:title, a:prompt, "ERROR\n\n" . a:text)
  endif
endfunction

function! s:RunLLMRequest(title, prompt) abort
  call s:RenderResultWithInput(a:title, a:prompt, "Thinking...")

  let s:last_job = s:CallOpenAIChatAsync(
        \ a:prompt,
        \ function('s:OnLLMDoneWrapper', [a:title, a:prompt])
        \ )

  echo ''
endfunction

function! s:LogToFile(line) abort
  call writefile([strftime('%Y-%m-%d %H:%M:%S ') . a:line], expand('~/vim_llm.log'), 'a')
endfunction

xnoremap <silent> <leader>q :<C-u>call LLMAskFromVisual()<CR>
xnoremap <silent> <leader>o :<C-u>call LLMFromVisual()<CR>
