local M = {}

local jelly = require("infra.jellyfish")("parrot", vim.log.levels.DEBUG)

local parser = require("parrot.parser")
local fn = require("infra.fn")
local ex = require("infra.ex")
local nvimkeys = require("infra.nvimkeys")

local api = vim.api

local state = { ran = false, chirps = {} }

---@param filetype string
---@return {[string]: string[]}
local function load_chirps(filetype)
  -- todo: reload
  if state.chirps[filetype] == nil then
    local fpaths = fn.iter_chained(fn.map(function(fmt) return api.nvim_get_runtime_file(string.format(fmt, filetype), true) end, {
      "chirps/%s.snippets",
      "chirps/%s_*.snippets",
      "chirps/%s-*.snippets",
    }))
    state.chirps[filetype] = parser(fpaths)
  end
  return state.chirps[filetype]
end

function M.setup()
  if state.ran then return end
  state.ran = true

  vim.keymap.set("i", "<c-space>", function()
    local win_id, bufnr, row, col
    do
      win_id = api.nvim_get_current_win()
      bufnr = api.nvim_get_current_buf()
      row, col = unpack(api.nvim_win_get_cursor(win_id))
    end

    local chirps = load_chirps(vim.bo[bufnr].filetype)

    local line = assert(api.nvim_buf_get_lines(bufnr, row - 1, row, true)[1])
    if col < #line then return jelly.info("cursor not placed at line end") end

    local key = string.match(line, "[%w_]+$")
    if key == nil then return jelly.debug("no available key at cursor") end

    local inserts
    do
      local indent = string.match(line, "^%s+") or ""
      if chirps[key] == nil then return jelly.debug("no available snippet for %s", key) end
      inserts = fn.concrete(fn.map(function(el) return indent .. el end, chirps[key]))
      inserts[1] = string.sub(inserts[1], #indent + 1)
    end

    api.nvim_buf_set_text(bufnr, row - 1, col - #key, row - 1, col, inserts)

    -- select expanded region and search the placeholders
    do
      local after_cursor = api.nvim_win_get_cursor(win_id)
      after_cursor[2] = after_cursor[2] + 1
      vim.cmd.stopinsert()
      api.nvim_win_set_cursor(win_id, { row, col - #key })
      ex("normal! v")
      api.nvim_win_set_cursor(win_id, after_cursor)
      vim.fn.setreg("/", [[/\%V\v(\$\d+)|(\$\{\d+(:[^}]+)?\})]])
      api.nvim_feedkeys(nvimkeys("<esc>/<cr>"), "n", false)
    end

    -- todo: imap tab -> next match & select-mode
  end)
end

return M
