" autoload/debug.vim - Debug pane implementation for llama.vim

" script‑local state
let s:debug_log   = []   " List of raw log lines (including fold markers)
let s:debug_bufnr = -1   " Buffer number of the debug pane (-1 means none yet)

function! debug#log(msg, ...) abort
    let l:timestamp = strftime('%H:%M:%S')
    let l:header    = l:timestamp . ' | ' . a:msg

    let l:block = []
    if a:0 >= 1
        let l:details = type(a:1) == type([]) ? a:1 : split(a:1, "\n")

        let l:header = l:header . ' | ' . get(l:details, 0, '')

        call add(l:block, l:header . ' {{{')
        for l:line in l:details
            call add(l:block, l:line)
        endfor
        call add(l:block, '}}}')
    else
        call add(l:block, l:header)
    endif

    let s:debug_log = l:block + s:debug_log

    let l:max_logs = 1024
    if len(s:debug_log) > l:max_logs
        let s:debug_log = s:debug_log[:l:max_logs - 1]
    endif

    if s:debug_bufnr > 0 && bufexists(s:debug_bufnr)
        call setbufvar    (s:debug_bufnr, '&modifiable', 1)
        call deletebufline(s:debug_bufnr, 1, '$')
        call setbufline   (s:debug_bufnr, 1, s:debug_log)
        call setbufvar    (s:debug_bufnr, '&modifiable', 0)

        let l:winid = bufwinid(s:debug_bufnr)
        if l:winid > 0
            call win_execute(l:winid, 'normal! gg')
            call win_execute(l:winid, 'normal! zx')
        endif
    endif
endfunction

function! debug#toggle() abort
    " If the pane is visible, close it
    if s:debug_bufnr > 0 && bufexists(s:debug_bufnr) && bufwinnr(s:debug_bufnr) != -1
        execute bufwinnr(s:debug_bufnr) . 'close'
        return
    endif

    " Otherwise open (or re‑open) the debug pane in a bottom split
    if s:debug_bufnr > 0 && bufexists(s:debug_bufnr)
        " The buffer already exists – open it in a split without creating a new one
        execute 'botright sbuffer ' . s:debug_bufnr
    else
        " Create a fresh scratch buffer for the debug pane
        botright new
        setlocal buftype=nofile bufhidden=hide noswapfile
        setlocal nomodifiable
        setlocal nospell nowrap nonumber norelativenumber signcolumn=no
        file [llama.vim-debug]

        " Enable marker folding
        setlocal foldmethod=marker
        setlocal foldmarker={{{,}}}
        setlocal foldlevel=0 " start with all folds closed
        setlocal foldenable
        setlocal foldcolumn=2

        let s:debug_bufnr = bufnr('%')
    endif

    " Populate with existing logs (or refresh if already present)
    if !empty(s:debug_log)
        call setbufvar    (s:debug_bufnr, '&modifiable', 1)
        call deletebufline(s:debug_bufnr, 1, '$')
        call setbufline   (s:debug_bufnr, 1, s:debug_log)
        call setbufvar    (s:debug_bufnr, '&modifiable', 0)
    endif
endfunction

function! debug#clear() abort
    let s:debug_log = []
    if s:debug_bufnr > 0 && bufexists(s:debug_bufnr)
        call setbufvar    (s:debug_bufnr, '&modifiable', 1)
        call deletebufline(s:debug_bufnr, 1, '$')
        call setbufvar    (s:debug_bufnr, '&modifiable', 0)
    endif
endfunction

function! debug#setup() abort
    command! LlamaDebugClear call debug#clear()
endfunction
