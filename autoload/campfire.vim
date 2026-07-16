" Vimscript command shims for campfire.nvim

if exists('g:autoloaded_campfire')
  finish
endif
let g:autoloaded_campfire = 1

function! s:lua_call(method, args) abort
  return luaeval("require('campfire').vim_call(_A.method, _A.args)", {'method': a:method, 'args': a:args})
endfunction

function! s:map(mode, lhs, rhs, ...) abort
  if get(g:, 'campfire_no_maps')
    return
  endif
  let flags = (a:0 ? a:1 : '') . (a:rhs =~# '^<Plug>' ? '' : '<script>')
  if flags =~# '<unique>' && !empty(mapcheck(a:lhs, a:mode))
    return
  endif
  execute a:mode . 'map <buffer>' flags a:lhs a:rhs
endfunction

function! campfire#connect_complete(A, L, P) abort
  return s:lua_call('connect_complete', [a:A, a:L, a:P])
endfunction

function! campfire#eval_complete(A, L, P) abort
  return s:lua_call('eval_complete', [a:A, a:L, a:P])
endfunction

function! campfire#ns_complete(A, L, P) abort
  return s:lua_call('ns_complete', [a:A, a:L, a:P])
endfunction

function! campfire#disconnect_complete(A, L, P) abort
  return s:lua_call('disconnect_complete', [a:A, a:L, a:P])
endfunction

function! campfire#connect_command(line1, line2, range, bang, mods, arg, args) abort
  return s:lua_call('connect_command', [a:line1, a:line2, a:range, a:bang, a:mods, a:arg, a:args])
endfunction

function! campfire#connections_command() abort
  return s:lua_call('connections_command', [])
endfunction

function! campfire#disconnect_command(args) abort
  return s:lua_call('disconnect_command', [a:args])
endfunction

function! campfire#reconnect_command(args) abort
  return s:lua_call('reconnect_command', [a:args])
endfunction

function! campfire#scope_command(bang, args) abort
  return s:lua_call('scope_command', [a:args, a:bang])
endfunction

function! campfire#scope_complete(A, L, P) abort
  return s:lua_call('scope_complete', [a:A, a:L, a:P])
endfunction

function! campfire#eval_command(runtime, line1, line2, range, bang, mods, args) abort
  return luaeval("require('campfire.eval').command(_A)", [a:runtime, a:line1, a:line2, a:range, a:bang, a:mods, a:args])
endfunction

function! campfire#run_tests_command(bang, line1, line2, args) abort
  return luaeval("require('campfire.tests').command(_A)", [a:bang, a:line1, a:line2, a:args])
endfunction

function! campfire#run_test_expr_command(bang, args) abort
  return luaeval("require('campfire.tests').command(_A)", [a:bang, 0, 0, a:args, 'expr'])
endfunction

function! campfire#run_lazytest_command(bang, line1, line2, args) abort
  return luaeval("require('campfire.tests').command(_A)", [a:bang, a:line1, a:line2, a:args, '', 'lazytest'])
endfunction

function! campfire#run_lazytest_expr_command(bang, args) abort
  return luaeval("require('campfire.tests').command(_A)", [a:bang, 0, 0, a:args, 'expr', 'lazytest'])
endfunction

function! campfire#doc_command(kind, args) abort
  return luaeval("require('campfire.ui').command(_A)", [a:kind, a:args])
endfunction

function! campfire#format_command(line1, line2) abort
  return luaeval("require('campfire.format').command(_A)", [a:line1, a:line2])
endfunction

function! campfire#formatexpr() abort
  return luaeval("require('campfire.format').formatexpr(_A[1], _A[2])", [v:lnum, v:count])
endfunction

function! campfire#omnifunc(findstart, base) abort
  return luaeval("require('campfire.completion').omnifunc(_A)", [a:findstart, a:base])
endfunction

function! s:print_op(type) abort
  " Defer the eval out of the opfunc/g@ callback so its result echo isn't
  " wiped by the redraw vim does when the operator finishes. Mirrors
  " vim-fireplace's s:printop -> <Plug>FireplacePrintLast.
  let s:print_type = a:type
  call feedkeys("\<Plug>CampfirePrintLast")
endfunction

function! s:print_last() abort
  call luaeval("require('campfire.operator').eval(_A)", s:print_type)
  return ''
endfunction

function! s:virt_op(type) abort
  call luaeval("require('campfire.operator').virt_eval(_A)", a:type)
endfunction

function! s:virt_clear(count) abort
  call luaeval("require('campfire.operator').clear(_A > 0)", a:count)
endfunction

function! s:virt_goto() abort
  call luaeval("require('campfire.operator').goto_virt()")
endfunction

function! s:virt_preview() abort
  call luaeval("require('campfire.operator').preview_virt()")
endfunction

let s:macroexpand_pending_count = 0

function! s:macroexpand_set_count(count) abort
  let s:macroexpand_pending_count = a:count
endfunction

function! s:macroexpand_arm(count, expander) abort
  let s:macroexpand_pending_count = a:count
  if a:expander ==# 'macroexpand-1'
    set opfunc=<SID>macroexpand1_op
  else
    set opfunc=<SID>macroexpand_op
  endif
endfunction

function! s:macroexpand_op(type) abort
  let l:count = s:macroexpand_pending_count
  let s:macroexpand_pending_count = 0
  call luaeval("require('campfire.macroexpand').op(_A[1], _A[2], _A[3])", [a:type, 'macroexpand-all', l:count])
endfunction

function! s:macroexpand1_op(type) abort
  let l:count = s:macroexpand_pending_count
  let s:macroexpand_pending_count = 0
  call luaeval("require('campfire.macroexpand').op(_A[1], _A[2], _A[3])", [a:type, 'macroexpand-1', l:count])
endfunction

function! campfire#macroexpand_command(bang, expander, args, count) abort
  return luaeval("require('campfire.macroexpand').command(_A[1], _A[2], _A[3], _A[4])", [a:bang ? v:true : v:false, a:expander, a:args, a:count])
endfunction

function! s:filter_op(type) abort
  call luaeval("require('campfire.operator').eval_replace(_A)", a:type)
endfunction

function! campfire#clear_command(bang) abort
  call luaeval("require('campfire.operator').clear(_A)", a:bang ? v:true : v:false)
  return ''
endfunction

function! s:campfire_last(count) abort
  return luaeval("require('campfire.history').command(_A)", [a:count])
endfunction

function! campfire#stacktrace_command(expr) abort
  return luaeval("require('campfire.stacktrace').command({ expr = _A })", a:expr)
endfunction

nnoremap <silent> <Plug>CampfirePrint :<C-U>set opfunc=<SID>print_op<CR>g@
xnoremap <silent> <Plug>CampfirePrint :<C-U>call <SID>print_op(visualmode())<CR>
nnoremap <silent> <Plug>CampfireCountPrint :<C-U>call <SID>print_op(v:count)<CR>
nnoremap <silent> <Plug>CampfirePrintLast :exe <SID>print_last()<CR>
nnoremap <silent> <Plug>CampfireVirtPrint :<C-U>set opfunc=<SID>virt_op<CR>g@
xnoremap <silent> <Plug>CampfireVirtPrint :<C-U>call <SID>virt_op(visualmode())<CR>
nnoremap <silent> <Plug>CampfireVirtCountPrint :<C-U>call <SID>virt_op(v:count)<CR>
nnoremap <silent> <Plug>CampfireVirtClear :<C-U>call <SID>virt_clear(v:count)<CR>
nnoremap <silent> <Plug>CampfireVirtGoto :<C-U>call <SID>virt_goto()<CR>
nnoremap <silent> <Plug>CampfireVirtPreview :<C-U>call <SID>virt_preview()<CR>
nnoremap <silent> <Plug>CampfireDocHover :DocHover <C-R>=expand('<cword>')<CR><CR>
nnoremap <silent> <Plug>CampfireSource :Source <C-R>=expand('<cword>')<CR><CR>
nnoremap <silent> <Plug>CampfireMacroExpand :<C-U>call <SID>macroexpand_arm(v:count, 'macroexpand-all')<CR>g@
xnoremap <silent> <Plug>CampfireMacroExpand :<C-U>call <SID>macroexpand_set_count(v:count)<bar>call <SID>macroexpand_op(visualmode())<CR>
nnoremap <silent> <Plug>CampfireCountMacroExpand :<C-U>call <SID>macroexpand_set_count(v:count)<bar>call <SID>macroexpand_op(v:count)<CR>
nnoremap <silent> <Plug>CampfireMacroExpand1 :<C-U>call <SID>macroexpand_arm(v:count, 'macroexpand-1')<CR>g@
xnoremap <silent> <Plug>CampfireMacroExpand1 :<C-U>call <SID>macroexpand_set_count(v:count)<bar>call <SID>macroexpand1_op(visualmode())<CR>
nnoremap <silent> <Plug>CampfireCountMacroExpand1 :<C-U>call <SID>macroexpand_set_count(v:count)<bar>call <SID>macroexpand1_op(v:count)<CR>
nnoremap <silent> <Plug>CampfireFilter :<C-U>set opfunc=<SID>filter_op<CR>g@
xnoremap <silent> <Plug>CampfireFilter :<C-U>call <SID>filter_op(visualmode())<CR>
nnoremap <silent> <Plug>CampfireCountFilter :<C-U>call <SID>filter_op(v:count)<CR>

function! campfire#activate() abort
  setlocal omnifunc=campfire#omnifunc

  command! -buffer -bang -bar -complete=customlist,campfire#connect_complete -nargs=*
        \ Connect exe campfire#connect_command(<line1>, <count>, +'<range>', <bang>0, <q-mods>, <q-args>, [<f-args>])
  command! -buffer -bar Connections exe campfire#connections_command()
  command! -buffer -bar -nargs=? -complete=customlist,campfire#disconnect_complete
        \ Disconnect exe campfire#disconnect_command(<q-args>)
  command! -buffer -bar -nargs=? -complete=customlist,campfire#disconnect_complete
        \ Reconnect exe campfire#reconnect_command(<q-args>)
  command! -buffer -bang -bar -nargs=? -complete=customlist,campfire#scope_complete
        \ Scope exe campfire#scope_command(<bang>0, <q-args>)

  command! -buffer -bang -range -nargs=* -complete=customlist,campfire#eval_complete
        \ Eval exe campfire#eval_command('auto', <line1>, <count>, +'<range>', <bang>0, <q-mods>, <q-args>)
  command! -buffer -bar -bang -range=0 -nargs=* -complete=customlist,campfire#ns_complete
        \ RunTests exe campfire#run_tests_command(<bang>0, <line1>, <line2>, <q-args>)
  command! -buffer -bang -nargs=* RunAllTests exe campfire#run_tests_command(<bang>0, 0, 0, <q-args>)
  command! -buffer -bang -nargs=* -complete=customlist,campfire#eval_complete RunTestExpr exe campfire#run_test_expr_command(<bang>0, <q-args>)
  command! -buffer -bar -bang -range=0 -nargs=* -complete=customlist,campfire#ns_complete
        \ RunLazyTest exe campfire#run_lazytest_command(<bang>0, <line1>, <line2>, <q-args>)
  command! -buffer -bang -nargs=* RunAllLazyTests exe campfire#run_lazytest_command(<bang>0, 0, 0, <q-args>)
  command! -buffer -bang -nargs=* -complete=customlist,campfire#eval_complete RunLazyTestExpr exe campfire#run_lazytest_expr_command(<bang>0, <q-args>)
  command! -buffer -bar -nargs=* -complete=customlist,campfire#eval_complete Doc exe campfire#doc_command('doc', <q-args>)
  command! -buffer -bar -nargs=* -complete=customlist,campfire#eval_complete DocHover exe campfire#doc_command('hover', <q-args>)
  command! -buffer -bar -nargs=* -complete=customlist,campfire#eval_complete Source exe campfire#doc_command('source', <q-args>)
  command! -buffer -bar -bang -count=0 -nargs=* -complete=customlist,campfire#eval_complete MacroExpand exe campfire#macroexpand_command(<bang>0, 'macroexpand-all', <q-args>, <count>)
  command! -buffer -bar -bang -count=0 -nargs=* -complete=customlist,campfire#eval_complete MacroExpand1 exe campfire#macroexpand_command(<bang>0, 'macroexpand-1', <q-args>, <count>)
  " count 0 (bare :Last) follows the newest eval; a counted :Last pins.
  command! -buffer -bar -count=0 Last exe s:campfire_last(<count>)
  " No -bar: a Clojure expr arg routinely contains `"`, which -bar would treat
  " as the start of a comment and truncate the expression.
  command! -buffer -nargs=? Stacktrace exe campfire#stacktrace_command(<q-args>)
  command! -buffer -bar -bang Clear exe campfire#clear_command(<bang>0)
  command! -buffer -bar -range=% Format exe campfire#format_command(<line1>, <line2>)
  setlocal keywordprg=:DocHover

  setlocal formatexpr=campfire#formatexpr()

  call s:map('n', 'cp', '<Plug>CampfirePrint')
  call s:map('n', 'cpp', '<Plug>CampfireCountPrint')
  call s:map('n', 'cvp', '<Plug>CampfireVirtPrint')
  call s:map('n', 'cvpp', '<Plug>CampfireVirtCountPrint')
  call s:map('n', 'cv!', '<Plug>CampfireVirtClear')
  call s:map('n', 'cvg', '<Plug>CampfireVirtGoto')
  call s:map('n', 'cvL', '<Plug>CampfireVirtPreview')
  call s:map('n', 'K', '<Plug>CampfireDocHover', '<unique>')
  call s:map('n', '[D', '<Plug>CampfireSource')
  call s:map('n', ']D', '<Plug>CampfireSource')
  call s:map('n', 'cm',  '<Plug>CampfireMacroExpand')
  call s:map('x', 'cm',  '<Plug>CampfireMacroExpand')
  call s:map('n', 'cmm', '<Plug>CampfireCountMacroExpand')
  call s:map('n', 'cm1', '<Plug>CampfireMacroExpand1')
  call s:map('x', 'cm1', '<Plug>CampfireMacroExpand1')
  call s:map('n', 'c!',  '<Plug>CampfireFilter')
  call s:map('x', 'c!',  '<Plug>CampfireFilter')
  call s:map('n', 'c!!', '<Plug>CampfireCountFilter')

  if exists('#User#CampfireActivate')
    doautocmd <nomodeline> User CampfireActivate
  endif
endfunction
