poor mans's snippet expanding tool

## features/limits
* it's very opinionated, not ready for public use at the moment
* uses a subset syntax of ultisnips's
* no placeholder evaluation
* no sh, python interpolation

## prerequisites
* nvim 0.9.*
* haolian9/infra.nvim

## status
* just works (tm)

## usage
* have below configs i used personally
* add snippets in `${rtp}/chirps/${ft}.snippets`

```
vim.keymap.set("i", "<tab>", function()
  local parrot = require("parrot")
  local nvimkeys = require("infra.nvimkeys")

  if parrot.running() then
    parrot.goto_next()
  else
    if parrot.expand() then return end
    assert(api.nvim_get_mode().mode == "i")
    api.nvim_feedkeys(nvimkeys("<tab>"), "n", false)
  end
end)
vim.keymap.set({ "n", "v", "x" }, "<tab>", function()
  local parrot = require("parrot")
  local nvimkeys = require("infra.nvimkeys")

  if parrot.goto_next() then return end
  -- for tmux only which can not distinguish between <c-i> and <tab>
  api.nvim_feedkeys(nvimkeys("<tab>"), "n", false)
end)
```

## todo
* possibly making use of inlay extmarks for placeholder evaluation and navigation
