poor mans's snippet expanding tool

## features/limits
* it's very opinionated, personalized, not for the public
* the syntax of `.snippets` is a **subset** of UltiSnips's
* no sh, python interpolation
* keymaps are not changeable
* polluting on the register `/`

## prerequisites
* nvim 0.9.*
* haolian9/infra.nvim

## status
* just works

## usage
* `require'parrot'.setup()`
* `i <c-space>`: expanding
* `i,n,x,v <tab>`: goto next placeholder
