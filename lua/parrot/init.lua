local M = {}

local ex = require("infra.ex")
local feedkeys = require("infra.feedkeys")
local fn = require("infra.fn")
local fs = require("infra.fs")
local jelly = require("infra.jellyfish")("parrot", "info")
local jumplist = require("infra.jumplist")
local prefer = require("infra.prefer")
local vsel = require("infra.vsel")
local wincursor = require("infra.wincursor")

local holes = require("parrot.holes")
local parser = require("parrot.parser")
local RegionWatcher = require("parrot.RegionWatcher")

local api = vim.api

local facts = {}
do
  facts.user_root = fs.joinpath(vim.fn.stdpath("config"), "chirps")
end

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
    local held = cache[filetype]
    if held ~= nil then return held end

    local fresh = parser(resolve_fpaths(filetype))
    cache[filetype] = fresh
    return fresh
  end

  ---@param filetype string
  ---@return string[]
  function get_chirps(filetype, key) return filetype_chirps(filetype)[key] or filetype_chirps("all")[key] end
end

do --state transitions
  ---@param winid integer
  ---@param chirps string[]
  ---@param insert_lnum integer @0-based
  ---@param insert_col integer @0-based
  ---@param cursor_at_end boolean @nil=false
  function M._expand(chirps, winid, insert_lnum, insert_col, cursor_at_end)
    local bufnr = api.nvim_win_get_buf(winid)

    local watcher = registry:get(bufnr)

    if watcher ~= nil then --only one watcher exists at the same time for each buffer
      jelly.debug("cancelling a watcher, for new watcher")
      watcher:cancel()
      registry:forget(bufnr)
    end

    local indent, inserts
    do
      inserts = {}
      local curline = api.nvim_get_current_line()
      indent = string.match(curline, "^%s+") or ""
      local chirp_iter = fn.iter(chirps)
      table.insert(inserts, chirp_iter())
      for line in chirp_iter do
        table.insert(inserts, indent .. line)
      end
    end

    jumplist.push_here()

    api.nvim_buf_set_text(bufnr, insert_lnum, insert_col, insert_lnum, insert_col, inserts)
    registry:remember(bufnr, RegionWatcher(bufnr, insert_lnum, insert_lnum + #inserts))

    if cursor_at_end then
      local lnum, col
      if #inserts == 1 then
        lnum = insert_lnum
        col = insert_col + #inserts[1] --insert_col + #firstline
      else
        lnum = insert_lnum + #inserts - 1
        col = #indent + #inserts[#inserts] --indents + #lastline
      end
      wincursor.go(winid, lnum, col)
    end
  end

  ---@param cursor_at_end boolean
  ---@return true? @true when made an expansion
  function M.expand(cursor_at_end)
    local winid = api.nvim_get_current_win()
    local bufnr = api.nvim_win_get_buf(winid)

    local cursor = wincursor.position(winid)

    local key
    do
      local curline = api.nvim_get_current_line()
      local leading = string.sub(curline, 1, cursor.col)
      key = string.match(leading, "[%w_]+$")
      if key == nil then return jelly.info("no key found") end
    end

    local chirps = get_chirps(prefer.bo(bufnr, "filetype"), key)
    if chirps == nil then return jelly.info("no available snippet for %s", key) end

    local insert_col = cursor.col - #key
    api.nvim_buf_set_text(bufnr, cursor.lnum, insert_col, cursor.lnum, cursor.col, {})
    M._expand(chirps, winid, cursor.lnum, insert_col, cursor_at_end)

    return true
  end

  M.expand_external_chirps = M._expand

  ---@return true? @true if next hole exists
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
    if api.nvim_win_get_buf(winid) ~= watcher:bufnr() then return jelly.warn("not the same buffer") end

    jelly.debug("finding next socket in [%d, %d)", watch_start_line, watch_stop_line)
    local next_line, next_col_start, next_col_stop = holes.next(winid, watch_start_line, watch_stop_line)
    if not (next_line and next_col_start and next_col_stop) then
      jelly.debug("cancelling a watcher, due to no more matches")
      watcher:cancel()
      registry:forget(bufnr)
      return
    end

    feedkeys("<esc>", "nx")
    assert(api.nvim_get_mode().mode == "n")

    jumplist.push_here()

    vsel.select_region(winid, next_line, next_col_start, next_line + 1, next_col_stop)

    --i just found select mode is not that convenient
    -- feedkeys("<c-g>", "nx")
    return true
  end

  function M.purify_placeholder()
    local bufnr = api.nvim_get_current_buf()
    local range = vsel.range(bufnr)
    assert(range)
    assert(range.stop_line - range.start_line == 1)

    local purified
    do
      local lines = api.nvim_buf_get_text(bufnr, range.start_line, range.start_col, range.start_line, range.stop_col, {})
      assert(#lines == 1, #lines)
      local raw = lines[1]
      if #raw < 4 then return jelly.warn("not a long-enough placeholder") end

      local count
      --this pattern should respect parrot.holes.matcher
      purified, count = string.gsub(raw, "%${%d+:?([^}]*)}", "%1")
      if count ~= 1 then return jelly.warn("not a pattern-matched placeholder") end

      assert(purified ~= raw)
    end

    api.nvim_buf_set_text(bufnr, range.start_line, range.start_col, range.start_line, range.stop_col, { purified })
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
end

do --auxiliary apis
  function M.reset_chirps(filetype) cache[filetype] = nil end

  ---@param filetype? string
  function M.edit_chirps(filetype)
    assert(filetype ~= "")
    if filetype == nil then
      local bufnr = api.nvim_get_current_buf()
      filetype = prefer.bo(bufnr, "filetype")
      if filetype == "" then return jelly.warn("no available filetype") end
    end

    local fpath = fs.joinpath(facts.user_root, string.format("%s.snippets", filetype))
    ex("tabedit", fpath)
    local bufnr = api.nvim_get_current_buf()
    prefer.bo(bufnr, "bufhidden", "wipe")
    api.nvim_create_autocmd("bufwipeout", { buffer = bufnr, once = true, callback = function() M.reset_chirps(filetype) end })
  end
end

M.comp = {}
do
  ---@return string[]
  function M.comp.editable_chirps()
    local filetypes = {}
    for fpath in fs.iterfiles(facts.user_root) do
      table.insert(filetypes, fs.stem(fpath))
    end
    return filetypes
  end
end

return M
