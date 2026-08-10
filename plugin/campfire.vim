" campfire.vim - Clojure nREPL support for Neovim

if exists('g:loaded_campfire')
  finish
endif
let g:loaded_campfire = 1

if !has('nvim')
  echohl WarningMsg
  echomsg 'campfire.nvim requires Neovim'
  echohl None
  finish
endif

augroup campfire
  autocmd!
  autocmd FileType clojure call campfire#activate()
  autocmd BufReadCmd campfire://doc/* call luaeval("require('campfire.ui').bufread_doc()")
  if exists('##SessionWritePre')
    autocmd SessionWritePre * call luaeval("require('campfire.ui').session_write()")
  endif
augroup END

command! -bar -bang -nargs=* -complete=customlist,campfire#connect_complete Connect
      \ exe campfire#connect_command(<line1>, <count>, +'<range>', <bang>0, <q-mods>, <q-args>, [<f-args>])
command! -bar Connections exe campfire#connections_command()
command! -bar -nargs=? -complete=customlist,campfire#disconnect_complete Disconnect
      \ exe campfire#disconnect_command(<q-args>)
command! -bar -nargs=? -complete=customlist,campfire#disconnect_complete Reconnect
      \ exe campfire#reconnect_command(<q-args>)
command! -bang -bar -nargs=? -complete=customlist,campfire#scope_complete Scope
      \ exe campfire#scope_command(<bang>0, <q-args>)
command! -bang -range -nargs=* -complete=customlist,campfire#eval_complete Eval
      \ exe campfire#eval_command('auto', <line1>, <count>, +'<range>', <bang>0, <q-mods>, <q-args>)
