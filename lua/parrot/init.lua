local M = {}

local jelly = require("infra.jellyfish")("parrot", vim.log.levels.DEBUG)

local fn = require("infra.fn")
local nvimkeys = require("infra.nvimkeys")

local parser = require("parrot.parser")
local Watcher = require("parrot.RegionWatcher")
local sockets = require("parrot.sockets")

local api = vim.api

local state = {
  chirps = {},
  watcher = nil,
}

---@param filetype string
---@return {[string]: string[]}
local function load_chirps(filetype)
  -- todo: reload
  -- todo: snippets for all filetypes
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

--assume nvim is in insert mode
--only one watcher exists at the same time
local function expand_snippet()
  if state.watcher then
    jelly.debug("cancelling a watcher, for new watcher")
    state.watcher.cancel()
    state.watcher = nil
  end

  local bufnr, cursor
  do
    local win_id = api.nvim_get_current_win()
    bufnr = api.nvim_win_get_buf(win_id)
    local tuple = api.nvim_win_get_cursor(win_id)
    cursor = { row = tuple[1], col = tuple[2] }
  end

  local curline = assert(api.nvim_buf_get_lines(bufnr, cursor.row - 1, cursor.row, true)[1])
  if cursor.col ~= #curline then return jelly.debug("only trigger at EOL") end

  local key = string.match(curline, "[%w_]+$")
  if key == nil then return jelly.debug("no key found") end

  -- expand snippet
  do
    local chirps
    do
      local chirps_map = load_chirps(vim.bo[bufnr].filetype)
      chirps = chirps_map[key]
      if chirps == nil then return jelly.debug("no available snippet for %s", key) end
    end

    local inserts = {}
    do
      local indent = string.match(curline, "^%s+") or ""
      for idx, line in pairs(chirps) do
        if idx == 1 then
          table.insert(inserts, string.sub(curline, 1, -#key - 1) .. chirps[1])
        else
          table.insert(inserts, indent .. line)
        end
      end
    end

    api.nvim_buf_set_lines(bufnr, cursor.row - 1, cursor.row, true, inserts)
    state.watcher = Watcher(bufnr, cursor.row - 1, cursor.row - 1 + #inserts)
    vim.cmd.stopinsert()
  end
end

--assume nvim is in {n,v,x} mode
local function goto_next_socket()
  if state.watcher == nil then return jelly.debug("no active watcher") end

  local watch_start_line, watch_stop_line = state.watcher.range()
  if watch_start_line == nil then
    state.watcher = nil
    return jelly.debug("the watcher stopped itself")
  end

  local win_id = api.nvim_get_current_win()
  if api.nvim_win_get_buf(win_id) ~= state.watcher.bufnr then return jelly.debug("not the same buffer") end

  do
    jelly.debug("finding next socket in [%d, %d)", watch_start_line, watch_stop_line)
    local next_line, next_col_start, next_col_stop = sockets.next(win_id, watch_start_line, watch_stop_line)
    if next_line == nil then
      jelly.debug("cancelling a watcher, due to no more matches")
      state.watcher.cancel()
      state.watcher = nil
      return
    end
    api.nvim_feedkeys(nvimkeys("<esc>"), "nx", false)
    api.nvim_win_set_cursor(win_id, { next_line + 1, next_col_start })
    api.nvim_feedkeys("v", "nx", false)
    api.nvim_win_set_cursor(win_id, { next_line + 1, next_col_stop - 1 })
    api.nvim_feedkeys(nvimkeys("<c-g>"), "nx", false)
  end
end

function M.setup()
  vim.keymap.set("i", "<c-.>", expand_snippet)
  vim.keymap.set({ "n", "v", "x" }, "<tab>", goto_next_socket)
end

return M
