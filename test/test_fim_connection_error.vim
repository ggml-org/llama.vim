set runtimepath^=.

let s:unreachable_endpoint = 'http://127.0.0.1:0/infill'
let s:connection_error = 'llama.vim: cannot connect to the FIM server; check endpoint_fim and that llama-server is running'
let s:wait_attempts = 40
let s:wait_interval_ms = 50
let s:test_job_id = 0
let s:other_curl_exit = 22

let g:llama_config = {
    \ 'endpoint_fim': s:unreachable_endpoint,
    \ 'enable_at_startup': v:false,
    \ }

source autoload/llama.vim
call llama#init()

function! s:wait_for_message(pattern)
    for l:attempt in range(s:wait_attempts)
        let l:messages = execute('messages')
        if l:messages =~# a:pattern
            return l:messages
        endif
        execute 'sleep ' . s:wait_interval_ms . 'm'
    endfor

    return execute('messages')
endfunction

function! s:script_function(name)
    let l:script_path = fnamemodify('autoload/llama.vim', ':p')
    for l:script in getscriptinfo()
        if fnamemodify(l:script.name, ':p') ==# l:script_path
            return function('<SNR>' . l:script.sid . '_' . a:name)
        endif
    endfor

    throw 'llama.vim script ID not found'
endfunction

messages clear
new
call setline(1, 'connection test')
call cursor(1, 1)
call llama#fim(0, 1, v:false, [], v:false)

let s:messages = s:wait_for_message('FIM.*\(failed\|connect\)')
call assert_match(s:connection_error, s:messages,
    \ 'curl connection failures must explain how to restore the FIM server connection')
call assert_notmatch('FIM job failed with exit code: 7', s:messages,
    \ 'curl exit code 7 must not be the only user-facing diagnosis')

let s:fim_on_exit = s:script_function('fim_on_exit')
messages clear
call call(s:fim_on_exit, [s:test_job_id, s:other_curl_exit])
call assert_match('FIM job failed with exit code: ' . s:other_curl_exit,
    \ execute('messages'), 'other curl failures must retain their exit code')

if !empty(v:errors)
    for s:error in v:errors
        echom s:error
    endfor
    cquit
endif

qa!
