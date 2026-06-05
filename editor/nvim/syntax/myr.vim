if exists("b:current_syntax")
  finish
endif

" keywords
syntax keyword myrKeyword function let return if else for break continue
syntax keyword myrKeyword struct enum import with context soa aos match
syntax keyword myrBoolean true false
syntax keyword myrNil    nil

" types
syntax keyword myrType int float bool str

" literals
syntax match   myrNumber  '\<[0-9]\+\(\.[0-9]\+\)\?\>'
syntax region  myrString  start='"' end='"' skip='\\"'
syntax match   myrComment '//.*$'

" decorators
syntax match   myrDecorator '@\w\+'

" operators
syntax match   myrOperator '[-+*/%=<>!&|^~]'
syntax match   myrOperator '\.\.\.'
syntax match   myrOperator '->'
syntax match   myrOperator '::'

" function names (word followed by open paren)
syntax match   myrFunction '\<\w\+\ze\s*('

" type annotations (word after colon)
syntax match   myrTypeAnnotation ':\s*\zs\w\+'

" highlight links
highlight link myrKeyword      Keyword
highlight link myrBoolean      Boolean
highlight link myrNil          Constant
highlight link myrType         Type
highlight link myrNumber       Number
highlight link myrString       String
highlight link myrComment      Comment
highlight link myrDecorator    PreProc
highlight link myrOperator     Operator
highlight link myrFunction     Function
highlight link myrTypeAnnotation Type

let b:current_syntax = "myr"
