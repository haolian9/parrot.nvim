local M = {}

local ex = require("infra.ex")
local fn = require("infra.fn")
local jelly = require("infra.jellyfish")("parrot", "debug")
local jumplist = require("infra.jumplist")
local nvimkeys = require("infra.nvimkeys")
local prefer = require("infra.prefer")
local vsel = require("infra.vsel")

local parser = require("parrot.parser")
local RegionWatcher = require("parrot.RegionWatcher")
local sockets = require("parrot.sockets")

local api = vim.api

local state = {
  ---@type {[string]: {[string]: string[]}} @{filetype: {prefix: [chirp]}}
  cache = {},
  ---@type parrot.RegionWatcher?
  watcher = nil,
}

local get_chirps
do
  ---@param filetype string
  local function resolve_fpaths(filetype)
    return fn.iter_chained(fn.map(function(fmt) return api.nvim_get_runtime_file(string.format(fmt, filetype), true) end, {
      "chirps/%s.snippets",
      "chirps/%s-*.snippets",
    }))
  end

  ---@param filetype string
  local function filetype_chirps(filetype)
    if state.cache[filetype] == nil then state.cache[filetype] = parser(resolve_fpaths(filetype)) end
    return state.cache[filetype]
  end

  ---@param filetype string
  ---@return string[]
  function get_chirps(filetype, key) return filetype_chirps(filetype)[key] or filetype_chirps("all")[key] end
end

local function ensure_modes(...)
  local held = api.nvim_get_mode().mode
  for i = 1, select("#", ...) do
    if held == select(i, ...) then return end
  end
  error("unreachable: unexpected mode")
end

--starts with insert-mode, stops with normal-mode
--returns true when it has made an expand
---@return true?
function M.expand()
  ensure_modes("i")

  --only one watcher exists at the same time
  if state.watcher then
    jelly.debug("cancelling a watcher, for new watcher")
    state.watcher:cancel()
    state.watcher = nil
  end

  local bufnr, cursor
  do
    local winid = api.nvim_get_current_win()
    bufnr = api.nvim_win_get_buf(winid)
    local tuple = api.nvim_win_get_cursor(winid)
    cursor = { row = tuple[1], col = tuple[2] }
  end

  local curline = assert(api.nvim_buf_get_lines(bufnr, cursor.row - 1, cursor.row, true)[1])
  if cursor.col ~= #curline then return jelly.debug("only trigger at EOL") end

  local key = string.match(curline, "[%w_]+$")
  if key == nil then return jelly.debug("no key found") end

  -- expand snippet
  do
    local chirps = get_chirps(prefer.bo(bufnr, "filetype"), key)
    if chirps == nil then return jelly.debug("no available snippet for %s", key) end

    local inserts = {}
    do
      local indent = string.match(curline, "^%s+") or ""
      for idx, line in ipairs(chirps) do
        if idx == 1 then
          table.insert(inserts, string.sub(curline, 1, -#key - 1) .. chirps[1])
        else
          table.insert(inserts, indent .. line)
        end
      end
    end

    jumplist.push_here()

    api.nvim_buf_set_lines(bufnr, cursor.row - 1, cursor.row, true, inserts)
    state.watcher = RegionWatcher(bufnr, cursor.row - 1, cursor.row - 1 + #inserts)
    ex("stopinsert")
    return true
  end
end

function M.goto_next()
  if state.watcher == nil then return jelly.debug("no active watcher") end

  local watch_start_line, watch_stop_line = state.watcher:range()
  if not (watch_start_line and watch_stop_line) then
    state.watcher = nil
    return jelly.debug("the watcher stopped itself")
  end

  local winid = api.nvim_get_current_win()
  if api.nvim_win_get_buf(winid) ~= state.watcher:bufnr() then return jelly.debug("not the same buffer") end

  do
    jelly.debug("finding next socket in [%d, %d)", watch_start_line, watch_stop_line)
    local next_line, next_col_start, next_col_stop = sockets.next(winid, watch_start_line, watch_stop_line)
    if not (next_line and next_col_start and next_col_stop) then
      jelly.debug("cancelling a watcher, due to no more matches")
      state.watcher:cancel()
      state.watcher = nil
      return
    end

    api.nvim_feedkeys(nvimkeys("<esc>"), "nx", false)
    assert(api.nvim_get_mode().mode == "n")

    jumplist.push_here()
    vsel.select_region(next_line, next_col_start, next_line + 1, next_col_stop)
    -- i just found select mode is not that convenient
    -- api.nvim_feedkeys(nvimkeys("<c-g>"), "nx", false)
    return true
  end
end

function M.running() return state.watcher ~= nil end

--for debugging ATM
function M.cancel()
  if state.watcher == nil then return end
  state.watcher:cancel()
  state.watcher = nil
end

function M.reset_chirps(filetype)
  if state.cache[filetype] == nil then return end
  state.cache[filetype] = nil
end

return M
