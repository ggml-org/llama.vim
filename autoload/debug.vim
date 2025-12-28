" autoload/debug.vim - Debug pane implementation for llama.vim

" script‑local state
let s:debug_log   = []   " List of raw log lines (including fold markers)
let s:debug_bufnr = -1   " Buffer number of the debug pane (-1 means none yet)

function! debug#log(msg, ...) abort
    " Create a timestamped header
    let l:timestamp = strftime('%H:%M:%S')
    let l:header    = l:timestamp . ' | ' . a:msg

    if a:0 >= 1
        " If extra data is supplied, wrap it in fold markers
        let l:details = type(a:1) == type([]) ? a:1 : split(a:1, "\n")
        call add(s:debug_log, l:header . ' {{{')
        for l:line in l:details
            call add(s:debug_log, l:line)
        endfor
        call add(s:debug_log, '}}}')
    else
        " Simple one‑liner – no fold
        call add(s:debug_log, l:header)
    endif

    if s:debug_bufnr > 0 && bufexists(s:debug_bufnr)
        call setbufvar(s:debug_bufnr, '&modifiable', 1)
        call setbufline(s:debug_bufnr, 1, s:debug_log)
        call setbufvar(s:debug_bufnr, '&modifiable', 0)
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
        file [Llama‑Debug]

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
        call setbufvar(s:debug_bufnr, '&modifiable', 1)
        call setbufline(s:debug_bufnr, 1, s:debug_log)
        call setbufvar(s:debug_bufnr, '&modifiable', 0)
    endif
endfunction

function! debug#clear() abort
    let s:debug_log = []
    if s:debug_bufnr > 0 && bufexists(s:debug_bufnr)
        call setbufvar(s:debug_bufnr, '&modifiable', 1)
        %delete _
        call setbufvar(s:debug_bufnr, '&modifiable', 0)
    endif
endfunction

function! debug#setup() abort
    call debug#log('Debug pane initialized')

    command! LlamaDebugClear     call debug#clear()
    command! LlamaDebugFoldOpen  execute bufwinnr(s:debug_bufnr) . 'wincmd w' | normal! zR
    command! LlamaDebugFoldClose execute bufwinnr(s:debug_bufnr) . 'wincmd w' | normal! zM
endfunction
