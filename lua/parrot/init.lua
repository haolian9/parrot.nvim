local jelly = require("infra.jellyfish")("parrot", vim.log.levels.DEBUG)

local parser = require("parrot.parser")
local fn = require("infra.fn")

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

return function()
  if state.ran then return end
  state.ran = true

  vim.keymap.set("i", "<c-space>", function()
    local bufnr, row, col
    do
      local win_id = api.nvim_get_current_win()
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
      inserts[1] = string.sub(inserts[1], #indent)
    end

    jelly.debug("(%d, %d), (%d, %d)", row - 1, col - #key, row - 1, col)
    api.nvim_buf_set_text(bufnr, row - 1, col - #key, row - 1, col, inserts)

    -- todo: regional search: `/\v(\$\d+)|(\$\{\d+:[^}]+\})`
  end)
end
