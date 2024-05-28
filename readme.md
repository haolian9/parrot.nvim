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
* merely a toy, not supposed to be used publicly

## todo
* select placeholder
* property timing to terminate the expansion

## usage

here's my personal config
```
do --parrot
  m.i("<tab>", function() ---always do expand, not jump
    local parrot = require("parrot")

    if vim.fn.pumvisible() == 1 then return feedkeys("<c-y>", "n") end
    if parrot.expand() then return feedkeys("<esc>", "n") end
    assert(strlib.startswith(api.nvim_get_mode().mode, "i"))
    feedkeys("<tab>", "n")
  end)
  m.n("<tab>", function() require("parrot").jump(1) end)
  m.n("<s-tab>", function() require("parrot").jump(-1) end)

  usercmd("ParrotCancel", function() require("parrot").cancel() end)

  do --:ParrotEdit
    local comp = cmds.ArgComp.constant(function() return require("parrot").comp.editable_chirp_fts() end)
    local function default() return prefer.bo(api.nvim_get_current_buf(), "filetype") end

    local spell = cmds.Spell("ParrotEdit", function(args) require("parrot").edit_chirp(args.filetype) end)
    spell:add_flag("open", "string", false, "right", cmds.FlagComp.constant("open", { "left", "right", "above", "below", "inplace", "tab" }))
    spell:add_arg("filetype", "string", false, default, comp)
    cmds.cast(spell)
  end
end
```
