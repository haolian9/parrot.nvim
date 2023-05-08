poor mans's snippet expanding tool

## features/limits
* it's very opinionated, not ready for public use at the moment
* ultisnips-compatible snippet syntax
* no sh, python interpolation
* keymaps are not changeable

## prerequisites
* nvim 0.9.*
* haolian9/infra.nvim

## status
* just works (tm)

## usage
* `require'parrot'.setup()`
* `i <c-.>`: expand snippet
* `n,x,v <tab>`: goto next socket
* add snippets in `${rtp}/chirps/${ft}.snippets`
