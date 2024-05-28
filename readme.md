a poor man's snippet expanding tool

## impl/features/limits
* use extmark to anchor the placeholder for later jumping
* uses a subset syntax of ultisnips's: `$0`, `${0}`, `${0:zero}`
* no placeholder evaluation
    * no sh, python interpolation
* limited support expanding external snippets, eg: lsp snippet completion, docgen


## prerequisites
* nvim 0.10.*
* haolian9/infra.nvim

## status
* just works


## usage
TBD


## todo
* select placeholder
* property timing to terminate the expansion


## notes
i had always been using ultisnips, while when i started to adopt lua in my nvim rice, i wanted to replace it to get rid of the
depency of python, even python is my favorite language all the time. but i could not found one meets my need, also i want to see
how hard is it to implement an usable one for myself (and now i knew that's not easy as there are too many states need to
maintain). so i rolled my own one in the way i knew, it lacks many features, and isnt comparable to ultisnips nor others in the
nvim realm, yet i still enjoy using and polishing it.
