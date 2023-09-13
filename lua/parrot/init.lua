local M = {}

local ex = require("infra.ex")
local fn = require("infra.fn")
local fs = require("infra.fs")
local jelly = require("infra.jellyfish")("parrot", "info")
local jumplist = require("infra.jumplist")
local nvimkeys = require("infra.nvimkeys")
local prefer = require("infra.prefer")
local strlib = require("infra.strlib")
local vsel = require("infra.vsel")

local parser = require("parrot.parser")
local RegionWatcher = require("parrot.RegionWatcher")
local sockets = require("parrot.sockets")

local api = vim.api

---cache of chirps: {filetype: {prefix: [chirp]}}
---@type {[string]: {[string]: string[]}}
local cache = {}

---registry of watchers
local registry = {}
do
  ---@private
  ---@type {[integer]: parrot.RegionWatcher}
  registry.kv = {}
  ---@param bufnr integer
  ---@return parrot.RegionWatcher?
  function registry:get(bufnr) return self.kv[bufnr] end
  ---@param bufnr integer
  ---@param watcher parrot.RegionWatcher
  function registry:remember(bufnr, watcher) self.kv[bufnr] = watcher end
  ---@param bufnr integer
  function registry:forget(bufnr) self.kv[bufnr] = nil end
end

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
    if cache[filetype] == nil then cache[filetype] = parser(resolve_fpaths(filetype)) end
    return cache[filetype]
  end

  ---@param filetype string
  ---@return string[]
  function get_chirps(filetype, key) return filetype_chirps(filetype)[key] or filetype_chirps("all")[key] end
end

--starts with insert-mode, stops with normal-mode
--returns true when it has made an expand
---@return true?
function M.expand()
  assert(strlib.startswith(api.nvim_get_mode().mode, "i"))

  local winid = api.nvim_get_current_win()
  local bufnr = api.nvim_win_get_buf(winid)

  local watcher = registry:get(bufnr)

  if watcher ~= nil then --only one watcher exists at the same time for each buffer
    jelly.debug("cancelling a watcher, for new watcher")
    watcher:cancel()
    registry:forget(bufnr)
  end

  local cursor
  do
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
    registry:remember(bufnr, RegionWatcher(bufnr, cursor.row - 1, cursor.row - 1 + #inserts))
    return true
  end
end

---@param winid integer
---@param chirps string[]
---@param insert_lnum integer @0-based
---@param insert_col integer @0-based
---@param cursor_at_end boolean @nil=false
function M.expand_external_chirps(chirps, winid, insert_lnum, insert_col, cursor_at_end)
  if cursor_at_end == nil then cursor_at_end = false end

  local bufnr = api.nvim_win_get_buf(winid)

  local watcher = registry:get(bufnr)

  if watcher ~= nil then --only one watcher exists at the same time for each buffer
    jelly.debug("cancelling a watcher, for new watcher")
    watcher:cancel()
    registry:forget(bufnr)
  end

  local inserts = {}
  do
    local curline = api.nvim_get_current_line()
    local indent = string.match(curline, "^%s+") or ""
    local chirp_iter = fn.iter(chirps)
    table.insert(inserts, chirp_iter())
    for line in chirp_iter do
      table.insert(inserts, indent .. line)
    end
  end

  jumplist.push_here()

  api.nvim_buf_set_text(bufnr, insert_lnum, insert_col, insert_lnum, insert_col, inserts)
  registry:remember(bufnr, RegionWatcher(bufnr, insert_lnum, insert_lnum + #inserts))

  if cursor_at_end then api.nvim_win_set_cursor(winid, { insert_lnum + 1 + #inserts - 1, #inserts[#inserts] - 1 + 1 }) end
end

function M.goto_next()
  local bufnr = api.nvim_get_current_buf()
  local watcher = registry:get(bufnr)
  if watcher == nil then return jelly.debug("no active watcher") end

  local watch_start_line, watch_stop_line = watcher:range()
  if not (watch_start_line and watch_stop_line) then
    registry:forget(bufnr)
    return jelly.debug("the watcher stopped itself")
  end

  local winid = api.nvim_get_current_win()
  if api.nvim_win_get_buf(winid) ~= watcher:bufnr() then return jelly.debug("not the same buffer") end

  do
    jelly.debug("finding next socket in [%d, %d)", watch_start_line, watch_stop_line)
    local next_line, next_col_start, next_col_stop = sockets.next(winid, watch_start_line, watch_stop_line)
    if not (next_line and next_col_start and next_col_stop) then
      jelly.debug("cancelling a watcher, due to no more matches")
      watcher:cancel()
      registry:forget(bufnr)
      return
    end

    api.nvim_feedkeys(nvimkeys("<esc>"), "nx", false)
    assert(api.nvim_get_mode().mode == "n")

    jumplist.push_here()
    vsel.select_region(winid, next_line, next_col_start, next_line + 1, next_col_stop)
    -- i just found select mode is not that convenient
    -- api.nvim_feedkeys(nvimkeys("<c-g>"), "nx", false)
    return true
  end
end

function M.running() return registry:get(api.nvim_get_current_buf()) ~= nil end

--for debugging ATM
function M.cancel()
  local bufnr = api.nvim_get_current_buf()
  local watcher = registry:get(bufnr)
  if watcher == nil then return end
  watcher:cancel()
  registry:forget(bufnr)
end

do
  function M.reset_chirps(filetype) cache[filetype] = nil end

  local user_root = fs.joinpath(vim.fn.stdpath("config"), "chirps")

  ---@param filetype? string
  function M.edit_chirps(filetype)
    assert(filetype ~= "")
    if filetype == nil then
      local bufnr = api.nvim_get_current_buf()
      filetype = prefer.bo(bufnr, "filetype")
      if filetype == "" then return jelly.warn("no available filetype") end
      jelly.debug("filetype1: %s", filetype)
    end

    local fpath = fs.joinpath(user_root, string.format("%s.snippets", filetype))
    ex("tabedit", fpath)
    local bufnr = api.nvim_get_current_buf()
    prefer.bo(bufnr, "bufhidden", "wipe")
    api.nvim_create_autocmd("bufwipeout", { buffer = bufnr, once = true, callback = function() M.reset_chirps(filetype) end })
  end

  ---made for usercmd completion
  ---@return string[]
  function M.editable_chirps()
    local filetypes = {}
    for fpath, ftype in fs.iterdir(user_root) do
      if ftype == "file" then table.insert(filetypes, fs.stem(fpath)) end
    end
    return filetypes
  end
end

return M
