--todo: select placeholder
--todo: property timing to terminate the expansion

local M = {}

local buflines = require("infra.buflines")
local bufopen = require("infra.bufopen")
local fs = require("infra.fs")
local itertools = require("infra.itertools")
local jelly = require("infra.jellyfish")("parrot", "info")
local jumplist = require("infra.jumplist")
local prefer = require("infra.prefer")
local repeats = require("infra.repeats")
local wincursor = require("infra.wincursor")

local chirps = require("parrot.chirps")
local compiler = require("parrot.compiler")
local facts = require("parrot.facts")

local api = vim.api

local anchors = {}
do
  local create_opts = { virt_text = { { "" } }, virt_text_pos = "inline", invalidate = true, undo_restore = true, right_gravity = false }

  ---presets:
  ---* it's an empty extmark, so called anchor
  ---* it'll be invalid automatically
  ---
  ---@param bufnr integer
  ---@param lnum integer @0-based
  ---@param col integer @0-based
  function anchors.add(bufnr, lnum, col)
    jelly.debug("creating xmark, lnum=%d, col=%d", lnum, col)
    local xmid = api.nvim_buf_set_extmark(bufnr, facts.anchor_ns, lnum, col, create_opts)
    return xmid
  end

  ---@param xmid integer
  ---@return nil|{lnum: integer, col: integer} anchor
  function anchors.get(bufnr, xmid)
    local xm = api.nvim_buf_get_extmark_by_id(bufnr, facts.anchor_ns, xmid, { details = true })
    jelly.debug("getting xmid=%s", xmid)

    if #xm == 0 then return end
    if xm[3].invalid == true then return end

    return { lnum = xm[1], col = xm[2] }
  end

  ---@param bufnr integer
  ---@param xmid integer
  function anchors.del(bufnr, xmid)
    --no matter what it returns, it might be false due to .invalidate=true option
    api.nvim_buf_del_extmark(bufnr, facts.anchor_ns, xmid)
    jelly.debug("deleted xmid=%s", xmid)
  end
end

local BufState
do
  ---@class parrot.BufState
  ---@field bufnr integer
  ---@field active boolean
  ---@field xmids integer[]
  ---@field jump_idx integer @-1=no xmark
  local Impl = {}
  Impl.__index = Impl

  ---@param xmids integer[]
  ---@param jump_idx integer @-1=no chirp.pitches
  function Impl:switched(xmids, jump_idx)
    assert(not self.active)

    self.active = true
    self.xmids = xmids
    self.jump_idx = jump_idx
  end

  function Impl:deactived()
    assert(self.active)
    self.active = false
    self.xmids = {}
    self.jump_idx = -1
  end

  ---@param bufnr integer
  ---@return parrot.BufState
  function BufState(bufnr) return setmetatable({ bufnr = bufnr, active = false, xmids = {}, jump_idx = -1 }, Impl) end
end

---registry of BufState
---@type {[integer]: parrot.BufState}
local registry = {}

---@param chirp parrot.compiler.Compiled
---@param winid integer
---@param region {lnum: integer, col: integer, col_end: integer} @col_end exclusive
---@return true?
local function expand(chirp, winid, region)
  local bufnr = api.nvim_win_get_buf(winid)
  local cursor = wincursor.position(winid)

  local indent, inserts
  do
    inserts = {}
    local curline = assert(buflines.line(bufnr, cursor.lnum))
    indent = string.match(curline, "^%s+") or ""
    local chirp_iter = itertools.iter(chirp.lines)
    table.insert(inserts, chirp_iter())
    for line in chirp_iter do
      table.insert(inserts, indent .. line)
    end
  end

  --replace the key with expanded snippet
  api.nvim_buf_set_text(bufnr, region.lnum, region.col, region.lnum, region.col_end, inserts)

  local state = registry[bufnr]
  if state == nil then
    state = BufState(bufnr)
    registry[bufnr] = state
  end

  do -- clear&setup xmids
    for _, xmid in ipairs(state.xmids) do
      anchors.del(state.bufnr, xmid)
    end

    local xmids = {}
    do --anchor each pitch
      local iter = itertools.iter(chirp.pitches)
      do --the first one
        local coloff = region.col
        local lnumoff = cursor.lnum
        local pitch = iter()

        local lnum = pitch.lnum + lnumoff
        local col = pitch.col + coloff - 1
        local xmid = anchors.add(bufnr, lnum, col)
        table.insert(xmids, xmid)
      end

      do
        local coloff = #indent
        local lnumoff = cursor.lnum

        for pitch in iter do
          local lnum = pitch.lnum + lnumoff
          local col = pitch.col + coloff - 1
          local xmid = anchors.add(bufnr, lnum, col)
          table.insert(xmids, xmid)
        end
      end
    end

    assert(#xmids == #chirp.pitches)
    state.xmids = xmids
  end

  do
    local jump_idx
    if #chirp.pitches > 0 then --goto min(nth)
      local jump_nth
      for idx, pitch in ipairs(chirp.pitches) do
        if jump_idx == nil or pitch.nth < jump_nth then
          jump_idx, jump_nth = idx, pitch.nth
        end
      end
      local anchor = anchors.get(bufnr, state.xmids[jump_idx])
      assert(anchor)
      wincursor.go(winid, anchor.lnum, anchor.col)
    else --goto the end of expansion
      jump_idx = -1
      local lnum, col
      if #inserts == 1 then
        lnum = cursor.lnum
        col = cursor.col + #inserts[1] --insert_col + #firstline
      else
        lnum = cursor.lnum + #inserts - 1
        col = #indent + #inserts[#inserts] --indents + #lastline
      end
      wincursor.go(winid, lnum, col)
    end

    state.jump_idx = jump_idx
  end

  state.active = true

  return true
end

---@return true? @true when made an expansion
function M.expand()
  local winid = api.nvim_get_current_win()
  local bufnr = api.nvim_win_get_buf(winid)

  local cursor = wincursor.position(winid)
  local curline = assert(buflines.line(bufnr, cursor.lnum))

  local key
  do
    local leading = string.sub(curline, 1, cursor.col)
    key = string.match(leading, "[%w_]+$")
    if key == nil then return jelly.debug("no key found") end
  end

  ---@type parrot.compiler.Compiled?
  local chirp = chirps.get(prefer.bo(bufnr, "filetype"), key)
  if chirp == nil then return jelly.debug("no available snippet for %s", key) end

  return expand(chirp, winid, { lnum = cursor.lnum, col = cursor.col - #key, col_end = cursor.col })
end

---@param raw_chirp string[]
---@param winid integer
---@param region {lnum: integer, col: integer, col_end: integer} @col_end: exclusive?
function M.expand_external_chirp(raw_chirp, winid, region)
  jelly.info("expanding: %s", raw_chirp)
  return expand(compiler(raw_chirp), winid, region)
end

---@param step -1|1 @not support v.count right now
---@return true? @true if next hole exists
function M.jump(step)
  local winid = api.nvim_get_current_win()
  local bufnr = api.nvim_win_get_buf(winid)

  local state = registry[bufnr]
  if state == nil then return jelly.debug("no active chirp") end

  if not state.active then return jelly.debug("no active chirp") end
  if #state.xmids == 0 then return jelly.debug("no anchors") end

  repeats.remember_paren(function() M.jump(1) end, function() M.jump(-1) end)

  local jump_idx, anchor
  do
    local n = #state.xmids
    jump_idx = state.jump_idx
    for _ = 1, #state.xmids do
      jump_idx = (jump_idx + step) % n
      if jump_idx == 0 then jump_idx = n end
      anchor = anchors.get(bufnr, state.xmids[jump_idx])
      if anchor ~= nil then break end
    end
    if anchor == nil then return jelly.info("no valid anchor found") end
  end

  jumplist.push_here()

  wincursor.go(winid, anchor.lnum, anchor.col)
  state.jump_idx = jump_idx

  return true
end

---@param bufnr? integer
---@return boolean
function M.running(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()

  local state = registry[bufnr]
  if state == nil then return false end

  return state.active
end

---@param bufnr? integer
function M.cancel(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()

  local state = registry[bufnr]
  if state == nil then return end

  if not state.active then return end

  local xmids = state.xmids
  state.xmids = {}
  state.active = false

  for _, xmid in ipairs(xmids) do
    anchors.del(state.bufnr, xmid)
  end
end

do --auxiliary apis
  ---@param ft? string
  ---@param open_mode? infra.bufopen.Mode
  function M.edit_chirp(ft, open_mode)
    if ft == nil then ft = prefer.bo(api.nvim_get_current_buf(), "filetype") end
    if ft == "" then return jelly.warn("no available filetype") end
    open_mode = open_mode or "right"

    bufopen(open_mode, fs.joinpath(facts.user_root, string.format("%s.snippets", ft)))

    local chirp_bufnr = api.nvim_get_current_buf()
    prefer.bo(chirp_bufnr, "bufhidden", "wipe")
    api.nvim_create_autocmd("bufwipeout", { buffer = chirp_bufnr, once = true, callback = function() chirps.reset_ft_chirps(ft) end })
  end

  M.comp = {}
  ---@return string[]
  function M.comp.editable_chirp_fts()
    local fts = {}
    for fpath in fs.iterfiles(facts.user_root) do
      table.insert(fts, fs.stem(fpath))
    end
    return fts
  end
end

return M
