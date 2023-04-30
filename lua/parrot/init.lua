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
    local win_id, bufnr, cursor
    do
      win_id = api.nvim_get_current_win()
      bufnr = api.nvim_get_current_buf()
      local tuple = api.nvim_win_get_cursor(win_id)
      cursor = { row = tuple[1], col = tuple[2] }
    end

    local line = assert(api.nvim_buf_get_lines(bufnr, cursor.row - 1, cursor.row, true)[1])
    if cursor.col ~= #line then return jelly.info("cursor not placed at line end") end

    local key = string.match(line, "[%w_]+$")
    if key == nil then return jelly.debug("no available key at cursor") end

    local chirps
    do
      local chirps_map = load_chirps(vim.bo[bufnr].filetype)
      chirps = chirps_map[key]
      if chirps == nil then return jelly.debug("no available snippet for %s", key) end
    end

    local inserts
    do
      local indent = string.match(line, "^%s+") or ""
      inserts = fn.concrete(fn.map(function(el) return indent .. el end, fn.slice(chirps, 2, #chirps)))
      table.insert(inserts, 1, string.sub(line, 1, -#key - 1) .. chirps[1])
      assert(#inserts == #chirps)
    end

    api.nvim_buf_set_lines(bufnr, cursor.row - 1, cursor.row, true, inserts)

    -- expand & select region & search/highlight placeholders
    do
      local region_begin, region_end
      region_begin = { cursor.row, cursor.col - #key }
      region_end = { cursor.row + #inserts - 1, #inserts[#inserts] }
      vim.cmd.stopinsert()
      api.nvim_win_set_cursor(win_id, region_begin)
      ex("normal! v")
      api.nvim_win_set_cursor(win_id, region_end)
      vim.fn.setreg("/", [[/\%V\v(\$\d+)|(\$\{\d+(:[^}]+)?\})]])
      api.nvim_feedkeys(nvimkeys("<esc>/<cr>"), "n", false)
    end
  end)

  -- todo: respect the state
  vim.keymap.set({ 'n', "i", "x", "v" }, "<tab>", function() api.nvim_feedkeys(nvimkeys("<esc>ngn<c-g>"), "n", false) end)
end

return M
