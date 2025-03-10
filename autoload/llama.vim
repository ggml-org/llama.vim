" vim: ts=4 sts=4 expandtab
" colors (adjust to your liking)
highlight llama_hl_hint guifg=#ff772f ctermfg=202
highlight llama_hl_info guifg=#77ff2f ctermfg=119

" general parameters:
"
"   endpoint:         llama.cpp server endpoint
"   api_key:          llama.cpp server api key (optional)
"   n_prefix:         number of lines before the cursor location to include in the local prefix
"   n_suffix:         number of lines after  the cursor location to include in the local suffix
"   n_predict:        max number of tokens to predict
"   t_max_prompt_ms:  max alloted time for the prompt processing (TODO: not yet supported)
"   t_max_predict_ms: max alloted time for the prediction
"   show_info:        show extra info about the inference (0 - disabled, 1 - statusline, 2 - inline)
"   auto_fim:         trigger FIM completion automatically on cursor movement
"   max_line_suffix:  do not auto-trigger FIM completion if there are more than this number of characters to the right of the cursor
"   max_cache_keys:   max number of cached completions to keep in result_cache
"
" ring buffer of chunks, accumulated with time upon:
"
"  - completion request
"  - yank
"  - entering a buffer
"  - leaving a buffer
"  - writing a file
"
" parameters for the ring-buffer with extra context:
"
"   ring_n_chunks:    max number of chunks to pass as extra context to the server (0 to disable)
"   ring_chunk_size:  max size of the chunks (in number of lines)
"                     note: adjust these numbers so that you don't overrun your context
"                           at ring_n_chunks = 64 and ring_chunk_size = 64 you need ~32k context
"   ring_scope:       the range around the cursor position (in number of lines) for gathering chunks after FIM
"   ring_update_ms:   how often to process queued chunks in normal mode
"
" keymaps parameters:
"
"   keymap_accept_full: accept full suggestion keymap, default: <Tab>
"   keymap_accept_line: accept line suggestion keymap, default: <S-Tab>
"   keymap_accept_word: accept word suggestion keymap, default: <C-B>
"
let s:default_config = {
    \ 'endpoint':           'http://127.0.0.1:8012/infill',
    \ 'api_key':            '',
    \ 'n_prefix':           256,
    \ 'n_suffix':           64,
    \ 'n_predict':          128,
    \ 't_max_prompt_ms':    500,
    \ 't_max_predict_ms':   1000,
    \ 'show_info':          2,
    \ 'auto_fim':           v:true,
    \ 'max_line_suffix':    8,
    \ 'max_cache_keys':     250,
    \ 'ring_n_chunks':      16,
    \ 'ring_chunk_size':    64,
    \ 'ring_scope':         1024,
    \ 'ring_update_ms':     1000,
    \ 'keymap_accept_full': "<Tab>",
    \ 'keymap_accept_line': "<S-Tab>",
    \ 'keymap_accept_word': "<C-B>",
    \ }

let llama_config = get(g:, 'llama_config', s:default_config)
let g:llama_config = extendnew(s:default_config, llama_config, 'force')

let s:llama_enabled = v:true

" containes cached responses from the server
" used to avoid re-computing the same completions and to also create new completions with similar context
" ref: https://github.com/ggml-org/llama.vim/pull/18
let g:cache_data = {}

" TODO: Currently the cache uses a random eviction policy. A more clever policy could be implemented (eg. LRU).
function! s:cache_insert(key, value)
    if len(keys(g:cache_data)) > (g:llama_config.max_cache_keys - 1)
        let l:keys = keys(g:cache_data)
        let l:hash = l:keys[rand() % len(l:keys)]
        call remove(g:cache_data, l:hash)
    endif

    let g:cache_data[a:key] = a:value
endfunction

" get the number of leading spaces of a string
function! s:get_indent(str)
    let l:count = 0
    for i in range(len(a:str))
        if a:str[i] == "\t"
            let l:count += &tabstop - 1
        else
            break
        endif
    endfor

    return l:count
endfunction

function! s:rand(i0, i1) abort
    return a:i0 + rand() % (a:i1 - a:i0 + 1)
endfunction

function! llama#disable()
    call llama#fim_hide()
    autocmd! llama
    silent! iunmap <C-F>
endfunction

function! llama#toggle()
    if s:llama_enabled
        call llama#disable()
    else
        call llama#init()
    endif
    let s:llama_enabled = !s:llama_enabled
endfunction

function llama#setup_commands()
    command! LlamaEnable  call llama#init()
    command! LlamaDisable call llama#disable()
    command! LlamaToggle  call llama#toggle()
endfunction

function! llama#init()
    if !executable('curl')
        echohl WarningMsg
        echo 'llama.vim requires the "curl" command to be available'
        echohl None
        return
    endif

    call llama#setup_commands()

    let s:fim_data = {}

    let s:ring_chunks = [] " current set of chunks used as extra context
    let s:ring_queued = [] " chunks that are queued to be sent for processing
    let s:ring_n_evict = 0

    let s:hint_shown = v:false
    let s:pos_y_pick = -9999 " last y where we picked a chunk
    let s:indent_last = -1   " last indentation level that was accepted (TODO: this might be buggy)

    let s:timer_fim = -1
    let s:t_last_move = reltime() " last time the cursor moved

    let s:current_job = v:null

    let s:ghost_text_nvim = exists('*nvim_buf_get_mark')
    let s:ghost_text_vim = has('textprop')

    if s:ghost_text_vim
        if version < 901
            echom 'Warning: llama.vim requires version 901 or greater. Current version: ' . version
        endif
        let s:hlgroup_hint = 'llama_hl_hint'
        let s:hlgroup_info = 'llama_hl_info'

        if empty(prop_type_get(s:hlgroup_hint))
            call prop_type_add(s:hlgroup_hint, {'highlight': s:hlgroup_hint})
        endif
        if empty(prop_type_get(s:hlgroup_info))
            call prop_type_add(s:hlgroup_info, {'highlight': s:hlgroup_info})
        endif
    endif

    augroup llama
        autocmd!
        autocmd InsertEnter     * inoremap <expr> <silent> <C-F> llama#fim_inline(v:false, v:false)
        autocmd InsertLeavePre  * call llama#fim_hide()

        autocmd CursorMoved     * call s:on_move()
        autocmd CursorMovedI    * call s:on_move()

        autocmd CompleteChanged * call llama#fim_hide()
        autocmd CompleteDone    * call s:on_move()

        if g:llama_config.auto_fim
            autocmd CursorMovedI * call llama#fim(-1, -1, v:true, [], v:true)
        endif

        " gather chunks upon yanking
        autocmd TextYankPost    * if v:event.operator ==# 'y' | call s:pick_chunk(v:event.regcontents, v:false, v:true) | endif

        " gather chunks upon entering/leaving a buffer
        autocmd BufEnter        * call timer_start(100, {-> s:pick_chunk(getline(max([1, line('.') - g:llama_config.ring_chunk_size/2]), min([line('.') + g:llama_config.ring_chunk_size/2, line('$')])), v:true, v:true)})
        autocmd BufLeave        * call                      s:pick_chunk(getline(max([1, line('.') - g:llama_config.ring_chunk_size/2]), min([line('.') + g:llama_config.ring_chunk_size/2, line('$')])), v:true, v:true)

        " gather chunk upon saving the file
        autocmd BufWritePost    * call s:pick_chunk(getline(max([1, line('.') - g:llama_config.ring_chunk_size/2]), min([line('.') + g:llama_config.ring_chunk_size/2, line('$')])), v:true, v:true)
    augroup END

    silent! call llama#fim_hide()

    " init background update of the ring buffer
    if g:llama_config.ring_n_chunks > 0
        call s:ring_update()
    endif
endfunction

" compute how similar two chunks of text are
" 0 - no similarity, 1 - high similarity
" TODO: figure out something better
function! s:chunk_sim(c0, c1)
    let l:lines0 = len(a:c0)
    let l:lines1 = len(a:c1)

    let l:common = 0

    for l:line0 in a:c0
        for l:line1 in a:c1
            if l:line0 == l:line1
                let l:common += 1
                break
            endif
        endfor
    endfor

    return 2.0 * l:common / (l:lines0 + l:lines1)
endfunction

" pick a random chunk of size g:llama_config.ring_chunk_size from the provided text and queue it for processing
"
" no_mod   - do not pick chunks from buffers with pending changes
" do_evict - evict chunks that are very similar to the new one
"
function! s:pick_chunk(text, no_mod, do_evict)
    " do not pick chunks from buffers with pending changes or buffers that are not files
    if a:no_mod && (getbufvar(bufnr('%'), '&modified') || !buflisted(bufnr('%')) || !filereadable(expand('%')))
        return
    endif

    " if the extra context option is disabled - do nothing
    if g:llama_config.ring_n_chunks <= 0
        return
    endif

    " don't pick very small chunks
    if len(a:text) < 3
        return
    endif

    if len(a:text) + 1 < g:llama_config.ring_chunk_size
        let l:chunk = a:text
    else
        let l:l0 = s:rand(0, max([0, len(a:text) - g:llama_config.ring_chunk_size/2]))
        let l:l1 = min([l:l0 + g:llama_config.ring_chunk_size/2, len(a:text)])

        let l:chunk = a:text[l:l0:l:l1]
    endif

    let l:chunk_str = join(l:chunk, "\n") . "\n"

    " check if this chunk is already added
    let l:exist = v:false

    for i in range(len(s:ring_chunks))
        if s:ring_chunks[i].data == l:chunk
            let l:exist = v:true
            break
        endif
    endfor

    for i in range(len(s:ring_queued))
        if s:ring_queued[i].data == l:chunk
            let l:exist = v:true
            break
        endif
    endfor

    if l:exist
        return
    endif

    " evict queued chunks that are very similar to the new one
    for i in range(len(s:ring_queued) - 1, 0, -1)
        if s:chunk_sim(s:ring_queued[i].data, l:chunk) > 0.9
            if a:do_evict
                call remove(s:ring_queued, i)
                let s:ring_n_evict += 1
            else
                return
            endif
        endif
    endfor

    " also from s:ring_chunks
    for i in range(len(s:ring_chunks) - 1, 0, -1)
        if s:chunk_sim(s:ring_chunks[i].data, l:chunk) > 0.9
            if a:do_evict
                call remove(s:ring_chunks, i)
                let s:ring_n_evict += 1
            else
                return
            endif
        endif
    endfor

    " TODO: become parameter ?
    if len(s:ring_queued) == 16
        call remove(s:ring_queued, 0)
    endif

    call add(s:ring_queued, {'data': l:chunk, 'str': l:chunk_str, 'time': reltime(), 'filename': expand('%')})

    "let &statusline = 'extra context: ' . len(s:ring_chunks) . ' / ' . len(s:ring_queued)
endfunction

" picks a queued chunk, sends it for processing and adds it to s:ring_chunks
" called every g:llama_config.ring_update_ms
function! s:ring_update()
    call timer_start(g:llama_config.ring_update_ms, {-> s:ring_update()})

    " update only if in normal mode or if the cursor hasn't moved for a while
    if mode() !=# 'n' && reltimefloat(reltime(s:t_last_move)) < 3.0
        return
    endif

    if len(s:ring_queued) == 0
        return
    endif

    " move the first queued chunk to the ring buffer
    if len(s:ring_chunks) == g:llama_config.ring_n_chunks
        call remove(s:ring_chunks, 0)
    endif

    call add(s:ring_chunks, remove(s:ring_queued, 0))

    "let &statusline = 'updated context: ' . len(s:ring_chunks) . ' / ' . len(s:ring_queued)

    " send asynchronous job with the new extra context so that it is ready for the next FIM
    let l:extra_context = []
    for l:chunk in s:ring_chunks
        call add(l:extra_context, {
            \ 'text':     l:chunk.str,
            \ 'time':     l:chunk.time,
            \ 'filename': l:chunk.filename
            \ })
    endfor

    " no samplers needed here
    let l:request = json_encode({
        \ 'input_prefix':     "",
        \ 'input_suffix':     "",
        \ 'input_extra':      l:extra_context,
        \ 'prompt':           "",
        \ 'n_predict':        0,
        \ 'temperature':      0.0,
        \ 'stream':           v:false,
        \ 'samplers':         [],
        \ 'cache_prompt':     v:true,
        \ 't_max_prompt_ms':  1,
        \ 't_max_predict_ms': 1,
        \ 'response_fields':  [""]
        \ })

    let l:curl_command = [
        \ "curl",
        \ "--silent",
        \ "--no-buffer",
        \ "--request", "POST",
        \ "--url", g:llama_config.endpoint,
        \ "--header", "Content-Type: application/json",
        \ "--data", "@-",
        \ ]

    if exists ("g:llama_config.api_key") && len("g:llama_config.api_key") > 0
        call extend(l:curl_command, ['--header', 'Authorization: Bearer ' .. g:llama_config.api_key])
    endif

    " no callbacks because we don't need to process the response
    if s:ghost_text_nvim
        let jobid = jobstart(l:curl_command, {})
        call chansend(jobid, l:request)
        call chanclose(jobid, 'stdin')
    elseif s:ghost_text_vim
        let jobid = job_start(l:curl_command, {})
        let channel = job_getchannel(jobid)
        call ch_sendraw(channel, l:request)
        call ch_close_in(channel)
    endif
endfunction

" get the local context at a specified position
" a:prev can optionally contain a previous completion for this position
"   in such cases, create the local context as if the completion was already inserted
function! s:fim_ctx_local(pos_x, pos_y, prev)
    let l:max_y = line('$')

    if empty(a:prev)
        let l:line_cur = getline(a:pos_y)

        let l:line_cur_prefix = strpart(l:line_cur, 0, a:pos_x)
        let l:line_cur_suffix = strpart(l:line_cur, a:pos_x)

        let l:lines_prefix = getline(max([1, a:pos_y - g:llama_config.n_prefix]), a:pos_y - 1)
        let l:lines_suffix = getline(a:pos_y + 1, min([l:max_y, a:pos_y + g:llama_config.n_suffix]))

        " special handling of lines full of whitespaces - start from the beginning of the line
        if match(l:line_cur, '^\s*$') >= 0
            let l:indent = 0

            let l:line_cur_prefix = ""
            let l:line_cur_suffix = ""
        else
            " the indentation of the current line
            let l:indent = strlen(matchstr(l:line_cur, '^\s*'))
        endif
    else
        if len(a:prev) == 1
            let l:line_cur = getline(a:pos_y) . a:prev[0]
        else
            let l:line_cur = a:prev[-1]
        endif

        let l:line_cur_prefix = l:line_cur
        let l:line_cur_suffix = ""

        let l:lines_prefix = getline(max([1, a:pos_y - g:llama_config.n_prefix + len(a:prev) - 1]), a:pos_y - 1)
        if len(a:prev) > 1
            call add(l:lines_prefix, getline(a:pos_y) . a:prev[0])

            for l:line in a:prev[1:-2]
                call add(l:lines_prefix, l:line)
            endfor
        endif

        let l:lines_suffix = getline(a:pos_y + 1, min([l:max_y, a:pos_y + g:llama_config.n_suffix]))

        let l:indent = s:indent_last
    endif

    let l:prefix = ""
        \ . join(l:lines_prefix, "\n")
        \ . "\n"

    let l:middle = ""
        \ . l:line_cur_prefix

    let l:suffix = ""
        \ . l:line_cur_suffix
        \ . "\n"
        \ . join(l:lines_suffix, "\n")
        \ . "\n"

    let l:res = {}

    let l:res['prefix'] = l:prefix
    let l:res['middle'] = l:middle
    let l:res['suffix'] = l:suffix
    let l:res['indent'] = l:indent

    let l:res['line_cur'] = l:line_cur

    let l:res['line_cur_prefix'] = l:line_cur_prefix
    let l:res['line_cur_suffix'] = l:line_cur_suffix

    return l:res
endfunction

" necessary for 'inoremap <expr>'
function! llama#fim_inline(is_auto, use_cache) abort
    " we already have a suggestion displayed - hide it
    if s:hint_shown && !a:is_auto
        call llama#fim_hide()
        return ''
    endif

    call llama#fim(-1, -1, a:is_auto, [], a:use_cache)

    return ''
endfunction

" the main FIM call
" takes local context around the cursor and sends it together with the extra context to the server for completion
function! llama#fim(pos_x, pos_y, is_auto, prev, use_cache) abort
    let l:pos_x = a:pos_x
    let l:pos_y = a:pos_y

    if l:pos_x < 0
        let l:pos_x = col('.') - 1
    endif

    if l:pos_y < 0
        let l:pos_y = line('.')
    endif

    " avoid sending repeated requests too fast
    if s:current_job != v:null
        if s:timer_fim != -1
            call timer_stop(s:timer_fim)
            let s:timer_fim = -1
        endif

        let s:timer_fim = timer_start(100, {-> llama#fim(a:pos_x, a:pos_y, v:true, a:prev, a:use_cache)})
        return
    endif

    "if s:hint_shown && empty(a:prev)
    "    return
    "endif

    "let s:t_fim_start = reltime()

    let l:ctx_local = s:fim_ctx_local(l:pos_x, l:pos_y, a:prev)

    let l:prefix = l:ctx_local['prefix']
    let l:middle = l:ctx_local['middle']
    let l:suffix = l:ctx_local['suffix']
    let l:indent = l:ctx_local['indent']

    if a:is_auto && len(l:ctx_local['line_cur_suffix']) > g:llama_config.max_line_suffix
        return
    endif

    let l:t_max_predict_ms = g:llama_config.t_max_predict_ms
    if empty(a:prev)
        " the first request is quick - we will launch a speculative request after this one is displayed
        let l:t_max_predict_ms = 250
    endif

    " compute multiple hashes that can be used to generate a completion for which the
    "   first few lines are missing. this happens when we have scrolled down a bit from where the original
    "   generation was done
    "
    let l:hashes = []

    call add(l:hashes, sha256(l:prefix . l:middle . 'Î' . l:suffix))

    let l:prefix_trim = l:prefix
    for i in range(3)
        let l:prefix_trim = substitute(l:prefix_trim, '^[^\n]*\n', '', '')
        if empty(l:prefix_trim)
            break
        endif

        call add(l:hashes, sha256(l:prefix_trim . l:middle . 'Î' . l:suffix))
    endfor

    " if we already have a cached completion for one of the hashes, don't send a request
    if a:use_cache
        for l:hash in l:hashes
            if get(g:cache_data, l:hash, v:null) != v:null
                return
            endif
        endfor
    endif

    " TODO: this might be incorrect
    let s:indent_last = l:indent

    " TODO: refactor in a function
    let l:text = getline(max([1, line('.') - g:llama_config.ring_chunk_size/2]), min([line('.') + g:llama_config.ring_chunk_size/2, line('$')]))

    let l:l0 = s:rand(0, max([0, len(l:text) - g:llama_config.ring_chunk_size/2]))
    let l:l1 = min([l:l0 + g:llama_config.ring_chunk_size/2, len(l:text)])

    let l:chunk = l:text[l:l0:l:l1]

    " evict chunks that are very similar to the current context
    " this is needed because such chunks usually distort the completion to repeat what was already there
    for i in range(len(s:ring_chunks) - 1, 0, -1)
        if s:chunk_sim(s:ring_chunks[i].data, l:chunk) > 0.5
            call remove(s:ring_chunks, i)
            let s:ring_n_evict += 1
        endif
    endfor

    " prepare the extra context data
    let l:extra_ctx = []
    for l:chunk in s:ring_chunks
        call add(l:extra_ctx, {
            \ 'text':     l:chunk.str,
            \ 'time':     l:chunk.time,
            \ 'filename': l:chunk.filename
            \ })
    endfor

    let l:request = json_encode({
        \ 'input_prefix':     l:prefix,
        \ 'input_suffix':     l:suffix,
        \ 'input_extra':      l:extra_ctx,
        \ 'prompt':           l:middle,
        \ 'n_predict':        g:llama_config.n_predict,
        \ 'n_indent':         l:indent,
        \ 'top_k':            40,
        \ 'top_p':            0.90,
        \ 'stream':           v:false,
        \ 'samplers':         ["top_k", "top_p", "infill"],
        \ 'cache_prompt':     v:true,
        \ 't_max_prompt_ms':  g:llama_config.t_max_prompt_ms,
        \ 't_max_predict_ms': l:t_max_predict_ms,
        \ 'response_fields':  [
        \                       "content",
        \                       "timings/prompt_n",
        \                       "timings/prompt_ms",
        \                       "timings/prompt_per_token_ms",
        \                       "timings/prompt_per_second",
        \                       "timings/predicted_n",
        \                       "timings/predicted_ms",
        \                       "timings/predicted_per_token_ms",
        \                       "timings/predicted_per_second",
        \                       "truncated",
        \                       "tokens_cached",
        \                     ],
        \ })

    let l:curl_command = [
        \ "curl",
        \ "--silent",
        \ "--no-buffer",
        \ "--request", "POST",
        \ "--url", g:llama_config.endpoint,
        \ "--header", "Content-Type: application/json",
        \ "--data", "@-",
        \ ]

    if exists ("g:llama_config.api_key") && len("g:llama_config.api_key") > 0
        call extend(l:curl_command, ['--header', 'Authorization: Bearer ' .. g:llama_config.api_key])
    endif

    if s:current_job != v:null
        if s:ghost_text_nvim
            call jobstop(s:current_job)
        elseif s:ghost_text_vim
            call job_stop(s:current_job)
        endif
    endif

    " send the request asynchronously
    if s:ghost_text_nvim
        let s:current_job = jobstart(l:curl_command, {
            \ 'on_stdout': function('s:fim_on_response', [l:hashes]),
            \ 'on_exit':   function('s:fim_on_exit'),
            \ 'stdout_buffered': v:true
            \ })
        call chansend(s:current_job, l:request)
        call chanclose(s:current_job, 'stdin')
    elseif s:ghost_text_vim
        let s:current_job = job_start(l:curl_command, {
            \ 'out_cb':    function('s:fim_on_response', [l:hashes]),
            \ 'exit_cb':   function('s:fim_on_exit')
            \ })

        let channel = job_getchannel(s:current_job)
        call ch_sendraw(channel, l:request)
        call ch_close_in(channel)
    endif

    " TODO: per-file location
    let l:delta_y = abs(l:pos_y - s:pos_y_pick)

    " gather some extra context nearby and process it in the background
    " only gather chunks if the cursor has moved a lot
    " TODO: something more clever? reranking?
    if a:is_auto && l:delta_y > 32
        let l:max_y = line('$')

        " expand the prefix even further
        call s:pick_chunk(getline(max([1,       l:pos_y - g:llama_config.ring_scope]), max([1,       l:pos_y - g:llama_config.n_prefix])), v:false, v:false)

        " pick a suffix chunk
        call s:pick_chunk(getline(min([l:max_y, l:pos_y + g:llama_config.n_suffix]),   min([l:max_y, l:pos_y + g:llama_config.n_suffix + g:llama_config.ring_chunk_size])), v:false, v:false)

        let s:pos_y_pick = l:pos_y
    endif
endfunction

" if accept_type == 'full', accept entire response
" if accept_type == 'line', accept only the first line of the response
" if accept_type == 'word', accept only the first word of the response
function! llama#fim_accept(accept_type)
    let l:pos_x  = s:fim_data['pos_x']
    let l:pos_y  = s:fim_data['pos_y']

    let l:line_cur = s:fim_data['line_cur']

    let l:can_accept = s:fim_data['can_accept']
    let l:content    = s:fim_data['content']

    if l:can_accept && len(l:content) > 0
        " insert suggestion on current line
        if a:accept_type != 'word'
            " insert first line of suggestion
            call setline(l:pos_y, l:line_cur[:(l:pos_x - 1)] . l:content[0])
        else
            " insert first word of suggestion
            let l:suffix = l:line_cur[(l:pos_x):]
            let l:word = matchstr(l:content[0][:-(len(l:suffix) + 1)], '^\s*\S\+')
            call setline(l:pos_y, l:line_cur[:(l:pos_x - 1)] . l:word . l:suffix)
        endif

        " insert rest of suggestion
        if len(l:content) > 1 && a:accept_type == 'full'
            call append(l:pos_y, l:content[1:-1])
        endif

        " move cusor
        if a:accept_type == 'word'
            " move cursor to end of word
            call cursor(l:pos_y, l:pos_x + len(l:word) + 1)
        elseif a:accept_type == 'line' || len(l:content) == 1
            " move cursor for 1-line suggestion
            call cursor(l:pos_y, l:pos_x + len(l:content[0]) + 1)
            if len(l:content) > 2
                " simulate pressing Enter to move to next line
                call feedkeys("\<CR>")
            endif
        else
            " move cursor for multi-line suggestion
            call cursor(l:pos_y + len(l:content) - 1, len(l:content[-1]) + 1)
        endif
    endif

    call llama#fim_hide()
endfunction

function! llama#fim_hide()
    let s:hint_shown = v:false

    " clear the virtual text
    let l:bufnr = bufnr('%')

    if s:ghost_text_nvim
        let l:id_vt_fim = nvim_create_namespace('vt_fim')
        call nvim_buf_clear_namespace(l:bufnr, l:id_vt_fim,  0, -1)
    elseif s:ghost_text_vim
        call prop_remove({'type': s:hlgroup_hint, 'all': v:true})
        call prop_remove({'type': s:hlgroup_info, 'all': v:true})
    endif

    " remove the mappings
    exe 'silent! iunmap <buffer> ' . g:llama_config.keymap_accept_full
    exe 'silent! iunmap <buffer> ' . g:llama_config.keymap_accept_line
    exe 'silent! iunmap <buffer> ' . g:llama_config.keymap_accept_word
endfunction

function! s:on_move()
    let s:t_last_move = reltime()

    call llama#fim_hide()

    let l:pos_x = col('.') - 1
    let l:pos_y = line('.')

    call s:fim_try_hint(l:pos_x, l:pos_y)
endfunction

" callback that processes the FIM result from the server
function! s:fim_on_response(hashes, job_id, data, event = v:null)
    if s:ghost_text_nvim
        let l:raw = join(a:data, "\n")
    elseif s:ghost_text_vim
        let l:raw = a:data
    endif

    " ignore empty results
    if len(l:raw) == 0
        return
    endif

    " put the response in the cache
    for l:hash in a:hashes
        call s:cache_insert(l:hash, l:raw)
    endfor

    " if nothing is currently displayed - show the hint directly
    if !s:hint_shown || !s:fim_data['can_accept']
        let l:pos_x = col('.') - 1
        let l:pos_y = line('.')

        call s:fim_try_hint(l:pos_x, l:pos_y)
    endif
endfunction

" try to generate a suggestion using the data in the cache
function! s:fim_try_hint(pos_x, pos_y)
    " show the suggestion only in insert mode
    if mode() !~# '\v^(i|ic|ix)$'
        return
    endif

    let l:pos_x = a:pos_x
    let l:pos_y = a:pos_y

    let l:ctx_local = s:fim_ctx_local(l:pos_x, l:pos_y, [])

    let l:prefix = l:ctx_local['prefix']
    let l:middle = l:ctx_local['middle']
    let l:suffix = l:ctx_local['suffix']

    let l:hash = sha256(l:prefix . l:middle . 'Î' . l:suffix)

    " Check if the completion is cached
    let l:raw = get(g:cache_data, l:hash, v:null)

    " ... or if there is a cached completion nearby (10 characters behind)
    " Looks at the previous 10 characters to see if a completion is cached. If one is found at (x,y)
    " then it checks that the characters typed after (x,y) match up with the cached completion result.
    if l:raw == v:null
        let l:pm = l:prefix . l:middle
        let l:best = 0

        for i in range(128)
            let l:removed = l:pm[-(1 + i):]
            let l:ctx_new = l:pm[:-(2 + i)] . 'Î' . l:suffix

            let l:hash_new = sha256(l:ctx_new)
            if has_key(g:cache_data, l:hash_new)
                let l:response_cached = get(g:cache_data, l:hash_new)
                if l:response_cached == ""
                    continue
                endif

                let l:response = json_decode(l:response_cached)
                if l:response['content'][0:i] !=# l:removed
                    continue
                endif

                let l:response['content'] = l:response['content'][i + 1:]
                if len(l:response['content']) > 0
                    if l:raw == v:null
                        let l:raw = json_encode(l:response)
                    elseif len(l:response['content']) > l:best
                        let l:best = len(l:response['content'])
                        let l:raw = json_encode(l:response)
                    endif
                endif
            endif
        endfor
    endif

    if l:raw != v:null
        call s:fim_render(l:pos_x, l:pos_y, l:raw)

        " run async speculative FIM in the background for this position
        if s:hint_shown
            call llama#fim(l:pos_x, l:pos_y, v:true, s:fim_data['content'], v:true)
        endif
    endif
endfunction

" render a suggestion at the current cursor location
function! s:fim_render(pos_x, pos_y, data)
    " do not show if there is a completion in progress
    if pumvisible()
        return
    endif

    let l:raw = a:data

    let l:can_accept = v:true
    let l:has_info   = v:false

    let l:n_prompt    = 0
    let l:t_prompt_ms = 1.0
    let l:s_prompt    = 0

    let l:n_predict    = 0
    let l:t_predict_ms = 1.0
    let l:s_predict    = 0

    let l:content = []

    " get the generated suggestion
    if l:can_accept
        let l:response = json_decode(l:raw)

        for l:part in split(get(l:response, 'content', ''), "\n", 1)
            call add(l:content, l:part)
        endfor

        " remove trailing new lines
        while len(l:content) > 0 && l:content[-1] == ""
            call remove(l:content, -1)
        endwhile

        let l:n_cached  = get(l:response, 'tokens_cached', 0)
        let l:truncated = get(l:response, 'timings/truncated', v:false)

        " if response.timings is available
        if has_key(l:response, 'timings/prompt_n') && has_key(l:response, 'timings/prompt_ms') && has_key(l:response, 'timings/prompt_per_second')
            \ && has_key(l:response, 'timings/predicted_n') && has_key(l:response, 'timings/predicted_ms') && has_key(l:response, 'timings/predicted_per_second')
            let l:n_prompt    = get(l:response, 'timings/prompt_n', 0)
            let l:t_prompt_ms = get(l:response, 'timings/prompt_ms', 1)
            let l:s_prompt    = get(l:response, 'timings/prompt_per_second', 0)

            let l:n_predict    = get(l:response, 'timings/predicted_n', 0)
            let l:t_predict_ms = get(l:response, 'timings/predicted_ms', 1)
            let l:s_predict    = get(l:response, 'timings/predicted_per_second', 0)
        endif

        let l:has_info = v:true
    endif

    if len(l:content) == 0
        call add(l:content, "")
        let l:can_accept = v:false
    endif

    let l:pos_x = a:pos_x
    let l:pos_y = a:pos_y

    let l:line_cur = getline(l:pos_y)

    " if the current line is full of whitespaces, trim as much whitespaces from the suggestion
    if match(l:line_cur, '^\s*$') >= 0
        let l:lead = min([strlen(matchstr(l:content[0], '^\s*')), strlen(l:line_cur)])

        let l:line_cur   = strpart(l:content[0], 0, l:lead)
        let l:content[0] = strpart(l:content[0],    l:lead)
    endif

    let l:line_cur_prefix = strpart(l:line_cur, 0, l:pos_x)
    let l:line_cur_suffix = strpart(l:line_cur, l:pos_x)

    " NOTE: the following is logic for discarding predictions that repeat existing text
    "       the code is quite ugly and there is very likely a simpler and more canonical way to implement this
    "
    "       still, I wonder if there is some better way that avoids having to do these special hacks?
    "       on one hand, the LLM 'sees' the contents of the file before we start editing, so it is normal that it would
    "       start generating whatever we have given it via the extra context. but on the other hand, it's not very
    "       helpful to re-generate the same code that is already there

    " truncate the suggestion if the first line is empty
    if len(l:content) == 1 && l:content[0] == ""
        let l:content = [""]
    endif

    " ... and the next lines are repeated
    if len(l:content) > 1 && l:content[0] == "" && l:content[1:] == getline(l:pos_y + 1, l:pos_y + len(l:content) - 1)
        let l:content = [""]
    endif

    " truncate the suggestion if it repeats the suffix
    if len(l:content) == 1 && l:content[0] == l:line_cur_suffix
        let l:content = [""]
    endif

    " find the first non-empty line (strip whitespace)
    let l:cmp_y = l:pos_y + 1
    while l:cmp_y < line('$') && getline(l:cmp_y) =~? '^\s*$'
        let l:cmp_y += 1
    endwhile

    if (l:line_cur_prefix . l:content[0]) == getline(l:cmp_y)
        " truncate the suggestion if it repeats the next line
        if len(l:content) == 1
            let l:content = [""]
        endif

        " ... or if the second line of the suggestion is the prefix of line l:cmp_y + 1
        if len(l:content) == 2 && l:content[-1] == getline(l:cmp_y + 1)[:len(l:content[-1]) - 1]
            let l:content = [""]
        endif

        " ... or if the middle chunk of lines of the suggestion is the same as [l:cmp_y + 1, l:cmp_y + len(l:content) - 1)
        if len(l:content) > 2 && join(l:content[1:-1], "\n") == join(getline(l:cmp_y + 1, l:cmp_y + len(l:content) - 1), "\n")
            let l:content = [""]
        endif
    endif

    " keep only lines that have the same or larger whitespace prefix as l:line_cur_prefix
    "let l:indent = strlen(matchstr(l:line_cur_prefix, '^\s*'))
    "for i in range(1, len(l:content) - 1)
    "    if strlen(matchstr(l:content[i], '^\s*')) < l:indent
    "        let l:content = l:content[:i - 1]
    "        break
    "    endif
    "endfor

    let l:content[-1] .= l:line_cur_suffix

    " if only whitespaces - do not accept
    if join(l:content, "\n") =~? '^\s*$'
        let l:can_accept = v:false
    endif

    " display virtual text with the suggestion
    let l:bufnr = bufnr('%')

    if s:ghost_text_nvim
        let l:id_vt_fim = nvim_create_namespace('vt_fim')
    endif

    let l:info = ''

    " construct the info message
    if g:llama_config.show_info > 0 && l:has_info
        let l:prefix = '   '

        if l:truncated
            let l:info = printf("%s | WARNING: the context is full: %d, increase the server context size or reduce g:llama_config.ring_n_chunks",
                \ g:llama_config.show_info == 2 ? l:prefix : 'llama.vim',
                \ l:n_cached
                \ )
        else
            let l:info = printf("%s | c: %d, r: %d/%d, e: %d, q: %d/16, C: %d/%d | p: %d (%.2f ms, %.2f t/s) | g: %d (%.2f ms, %.2f t/s)",
                \ g:llama_config.show_info == 2 ? l:prefix : 'llama.vim',
                \ l:n_cached,  len(s:ring_chunks), g:llama_config.ring_n_chunks, s:ring_n_evict, len(s:ring_queued),
                \ len(keys(g:cache_data)), g:llama_config.max_cache_keys,
                \ l:n_prompt,  l:t_prompt_ms,  l:s_prompt,
                \ l:n_predict, l:t_predict_ms, l:s_predict
                \ )
        endif

        if g:llama_config.show_info == 1
            " display the info in the statusline
            let &statusline = l:info
            let l:info = ''
        endif
    endif

    " display the suggestion and append the info to the end of the first line
    if s:ghost_text_nvim
        call nvim_buf_set_extmark(l:bufnr, l:id_vt_fim, l:pos_y - 1, l:pos_x - 1, {
            \ 'virt_text': [[l:content[0], 'llama_hl_hint'], [l:info, 'llama_hl_info']],
            \ 'virt_text_win_col': l:pos_x
            \ })

        call nvim_buf_set_extmark(l:bufnr, l:id_vt_fim, l:pos_y - 1, 0, {
            \ 'virt_lines': map(l:content[1:], {idx, val -> [[val, 'llama_hl_hint']]}),
            \ 'virt_text_win_col': l:pos_x + 1
            \ })
    elseif s:ghost_text_vim
        let l:full_suffix = l:content[0]
        if !empty(l:full_suffix)
            let l:new_suffix = l:full_suffix[0:-len(l:line_cur[l:pos_x:])-1]
            call prop_add(l:pos_y, l:pos_x + 1, {
                \ 'type': s:hlgroup_hint,
                \ 'text': l:new_suffix
                \ })
        endif
        for line in l:content[1:]
            call prop_add(l:pos_y, 0, {
                \ 'type': s:hlgroup_hint,
                \ 'text': line,
                \ 'text_padding_left': s:get_indent(line),
                \ 'text_align': 'below'
                \ })
        endfor
        if !empty(l:info)
            call prop_add(l:pos_y, 0, {
                \ 'type': s:hlgroup_info,
                \ 'text': l:info,
                \ 'text_wrap': 'truncate'
                \ })
        endif
    endif

    " setup accept shortcuts
    exe 'inoremap <buffer> ' . g:llama_config.keymap_accept_full . ' <C-O>:call llama#fim_accept(''full'')<CR>'
    exe 'inoremap <buffer> ' . g:llama_config.keymap_accept_line . ' <C-O>:call llama#fim_accept(''line'')<CR>'
    exe 'inoremap <buffer> ' . g:llama_config.keymap_accept_word . ' <C-O>:call llama#fim_accept(''word'')<CR>'

    let s:hint_shown = v:true

    let s:fim_data['pos_x']  = l:pos_x
    let s:fim_data['pos_y']  = l:pos_y

    let s:fim_data['line_cur'] = l:line_cur

    let s:fim_data['can_accept'] = l:can_accept
    let s:fim_data['content']    = l:content
endfunction

function! s:fim_on_exit(job_id, exit_code, event = v:null)
    if a:exit_code != 0
        echom "Job failed with exit code: " . a:exit_code
    endif

    let s:current_job = v:null
endfunction
