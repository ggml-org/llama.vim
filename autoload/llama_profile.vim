" autoload/llama_profile.vim - Profiles for llama.vim

" Keep the configured values separate from a profile restored from the previous
" session.  :LlamaProfileReset uses these values to return to the .vimrc setup.
let s:default_profile = g:llama_config.profile
let s:default_endpoint_fim   = g:llama_config.endpoint_fim
let s:default_endpoint_inst  = g:llama_config.endpoint_inst

function! llama_profile#names() abort
    if type(g:llama_config.profiles) != v:t_dict
        return []
    endif

    return sort(keys(g:llama_config.profiles))
endfunction

function! llama_profile#complete(arglead, cmdline, cursorpos) abort
    return filter(llama_profile#names(), 'stridx(v:val, a:arglead) == 0')
endfunction

function! s:profile_state_file()
    " Allow configuration (.vimrc) of where the state file is stored.
    let l:file = get(g:, 'llama_profile_state_file', '')
    if type(l:file) == v:t_string && !empty(l:file)
        return expand(l:file)
    endif

    " If Vim/Neovim provides stdpath(), use its state filesystem
    " location.
    if exists('*stdpath')
        try
            return stdpath('state') . '/llama/profile'
        catch
        endtry
    endif

    " Fallback to the user's home .vim directory.
    return expand('~/.vim/llama-profile')
endfunction


function! s:save_profile(profile)
    let l:file = s:profile_state_file()
    try
        call mkdir(fnamemodify(l:file, ':h'), 'p', 0700)
        call writefile([a:profile], l:file)
    catch
        echohl WarningMsg
        echomsg 'llama.vim: could not save profile state'
        echohl None
    endtry
endfunction

function! llama_profile#restore() abort
    let l:file = s:profile_state_file()
    if !filereadable(l:file)
        return
    endif

    try
        let l:profile = get(readfile(l:file), 0, '')
    catch
        return
    endtry

    if type(g:llama_config.profiles) == v:t_dict && has_key(g:llama_config.profiles, l:profile)
        let g:llama_config.profile = l:profile
    endif
endfunction

function! llama_profile#reset() abort
    let g:llama_config.endpoint_fim   = s:default_endpoint_fim
    let g:llama_config.endpoint_inst  = s:default_endpoint_inst
    let g:llama_config.profile = s:default_profile

    if !empty(s:default_profile)
        call llama_profile#select(s:default_profile, v:true, v:false)
    else
        call llama#profile_changed()
    endif

    let l:file = s:profile_state_file()
    if filereadable(l:file)
        try
            call delete(l:file)
        catch
            echohl WarningMsg
            echomsg 'llama.vim: could not clear profile state'
            echohl None
            return
        endtry
    endif

    echo 'Restored default llama profile: ' . (empty(s:default_profile)
        \ ? '(custom endpoints)'
        \ : s:default_profile)
endfunction

function! llama_profile#select(name, ...) abort
    if empty(a:name)
        let l:names = llama_profile#names()
        let l:active = empty(g:llama_config.profile)
            \ ? '(custom endpoints)'
            \ : g:llama_config.profile

        let l:profile_values = []
        for l:name in l:names
            let l:base = get(g:llama_config.profiles, l:name, '')
            if type(l:base) == v:t_string && !empty(l:base)
                call add(l:profile_values, l:name . ' (' . l:base . ')')
            else
                call add(l:profile_values, l:name . ' (invalid base URL)')
            endif
        endfor
        let l:active_base = get(g:llama_config.profiles, g:llama_config.profile, '')
        if type(l:active_base) == v:t_string && !empty(l:active_base)
            let l:active .= ' (' . l:active_base . ')'
        endif

        echo 'Active llama profile: ' . l:active
        echo 'Available llama profiles: ' . (empty(l:profile_values)
            \ ? '(none)'
            \ : join(l:profile_values, ', '))
        return
    endif

    if type(g:llama_config.profiles) != v:t_dict
        echohl ErrorMsg
        echo 'llama.vim: profiles must be a dictionary'
        echohl None
        return
    endif

    if !has_key(g:llama_config.profiles, a:name)
        echohl ErrorMsg
        echo 'llama.vim: unknown profile: ' . a:name
        echohl None
        return
    endif

    let l:base = g:llama_config.profiles[a:name]
    if type(l:base) != v:t_string || empty(l:base)
        echohl ErrorMsg
        echo 'llama.vim: profile must contain a non-empty base URL: ' . a:name
        echohl None
        return
    endif

    let l:base = substitute(l:base, '/\+$', '', '')
    let g:llama_config.endpoint_fim = l:base . '/infill'
    let g:llama_config.endpoint_inst = l:base . '/v1/chat/completions'
    let g:llama_config.profile = a:name

        call llama#profile_changed()

    if !get(a:, 1, v:false)
        echo 'Using llama profile: ' . a:name . ' (' . l:base . ')'
    endif

    if get(a:, 2, !get(a:, 1, v:false))
        call s:save_profile(a:name)
    endif
endfunction
