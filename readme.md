a poor man's snippet expanding tool

## impl/features/limits
* uses regex to match placeholder, which makes it eror-prone
    * thus it does not honor the jump order specified in the placeholder, `$1` vs `$2`
* the processing on `nvim_buf_attach(on_lines)` has not been well tested, which makes the state transition fragile
    * that's why i exposed `parrot.cancel()`
    * and every buffer can only have one running expanding operation
* uses a subset syntax of ultisnips's: `$0`, `${0}`, `${0:zero}`
* no placeholder evaluation
    * no sh, python interpolation
* limited support expanding external snippets, eg: lsp snippet completion, docgen


## prerequisites
* nvim 0.9.*
* haolian9/infra.nvim

## status
* just works (tm)
* it's far from stable


## usage
TBD


## todo
* possibly making use of inline extmarks for placeholder evaluation and navigation
* isolating every expanding


## notes
i had always been using ultisnips, while when i started to adopt lua in my nvim rice, i wanted to replace it to get rid of the
depency of python, even python is my favorite language all the time. but i could not found one meets my need, also i want to see
how hard is it to implement an usable one for myself (and now i knew that's not easy as there are too many states need to
maintain). so i rolled my own one in the way i knew, it lacks many features, and isnt comparable to ultisnips nor others from
nvim realm, yet i still enjoy using and polishing it.
