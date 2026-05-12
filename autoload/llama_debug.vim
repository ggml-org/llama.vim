" autoload/llama_debug.vim - Debug pane implementation for llama.vim

let s:debug = {
    \ 'bufnr': -1,
    \ 'log': [],
    \ 'max_lines': 1024,
    \ 'flush': -1,
    \ 'dirty': 1,
    \ }

" ensure the debug buffer exists and is ready for writing
function! s:ensure_buf() abort
    if s:debug.bufnr > 0 && bufexists(s:debug.bufnr)
        return v:true
    endif

    " create a fresh scratch buffer for the debug pane
    botright new
    setlocal buftype=nofile bufhidden=hide noswapfile
    setlocal nomodifiable
    setlocal nospell nowrap nonumber norelativenumber signcolumn=no
    file [llama.vim-debug]

    " enable marker folding
    setlocal foldmethod=marker
    setlocal foldmarker={{{,}}}
    setlocal foldlevel=0 " start with all folds closed
    setlocal foldenable
    setlocal foldcolumn=2

    let s:debug.bufnr = bufnr('%')

    return v:true
endfunction

" schedule a deferred buffer flush if not already pending.
function! s:flush_sched() abort
    if s:debug.flush != -1
        return
    endif

    let s:debug.flush = timer_start(50, {-> s:flush()}, {'repeat': 0})
endfunction

" flush the in‑memory log to the debug buffer.
function! s:flush() abort
    let s:debug.flush = -1
    if !(s:debug.bufnr > 0 && bufexists(s:debug.bufnr))
        return
    endif

    if s:debug.dirty == 0
        return
    endif
    let s:debug.dirty = 0

    call setbufvar    (s:debug.bufnr, '&modifiable', 1)
    call deletebufline(s:debug.bufnr, 1, '$')

    let l:flat = []
    for l:block in s:debug.log
        call extend(l:flat, l:block)
    endfor

    if !empty(l:flat)
        call setbufline(s:debug.bufnr, 1, l:flat)
    endif

    call setbufvar    (s:debug.bufnr, '&modifiable', 0)
endfunction

" log a message (msg is a string). Optional second argument can be a list or any value that will be split into lines.
function! llama_debug#log(msg, ...) abort
    " normalise details to a list of strings
    let l:details = a:0 >= 1 ? a:1 : []
    if type(l:details) != type([])
        let l:details = split(string(l:details), "\n")
    endif

    let l:timestamp = strftime('%H:%M:%S')
    let l:header    = l:timestamp . ' | ' . a:msg

    let l:block = []
    if !empty(l:details)
        let l:header = l:header . ' | ' . get(l:details, 0, '')
        call add(l:block, l:header . ' {{{')
        for l:line in l:details
            call add(l:block, l:line)
        endfor
        call add(l:block, '}}}')
    else
        call add(l:block, l:header)
    endif

    " insert new logs at the beginning of the list (newest first)
    call insert(s:debug.log, l:block, 0)

    if len(s:debug.log) > s:debug.max_lines
        let s:debug.log = s:debug.log[:s:debug.max_lines - 1]
    endif

    let s:debug.dirty = 1
    call s:flush_sched()
endfunction

function! llama_debug#toggle() abort
    " if the pane is visible, close it
    if s:debug.bufnr > 0 && bufexists(s:debug.bufnr) && bufwinnr(s:debug.bufnr) != -1
        execute bufwinnr(s:debug.bufnr) . 'close'
        return
    endif

    " otherwise, open (or re‑open) the debug pane in a bottom split
    if s:debug.bufnr > 0 && bufexists(s:debug.bufnr)
        " the buffer already exists – open it in a split without creating a new one
        execute 'botright sbuffer ' . s:debug.bufnr
    else
        " create a fresh scratch buffer
        call s:ensure_buf()
    endif

    call s:flush_sched()
endfunction

function! llama_debug#clear() abort
    let s:debug.log = []
    if s:debug.bufnr > 0 && bufexists(s:debug.bufnr)
        call setbufvar    (s:debug.bufnr, '&modifiable', 1)
        call deletebufline(s:debug.bufnr, 1, '$')
        call setbufvar    (s:debug.bufnr, '&modifiable', 0)
    endif
endfunction

function! llama_debug#setup() abort
    call llama_debug#clear()
endfunction
