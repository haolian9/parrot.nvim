---design choices
---* no visual selecting placeholder
---  * https://github.com/neovim/neovim/issues/23549
---  * beware of empty placeholder
---* no auto-terminating
---  * i can not find a reliable way to do it, leave it to the user
---  * and in my uses, i dont even bother that

local M = {}

local buflines = require("infra.buflines")
local bufopen = require("infra.bufopen")
local ex = require("infra.ex")
local feedkeys = require("infra.feedkeys")
local fs = require("infra.fs")
local itertools = require("infra.itertools")
local its = require("infra.its")
local jelly = require("infra.jellyfish")("parrot", "info")
local jumplist = require("infra.jumplist")
local mi = require("infra.mi")
local ni = require("infra.ni")
local prefer = require("infra.prefer")
local repeats = require("infra.repeats")
local strlib = require("infra.strlib")
local vsel = require("infra.vsel")
local wincursor = require("infra.wincursor")

local beckon_select = require("beckon.select")
local chirps = require("parrot.chirps")
local compiler = require("parrot.compiler")
local facts = require("parrot.facts")

local anchors = {}
do
  ---place an 0-range, auto-deleted extmark
  ---@param bufnr integer
  ---@param lnum integer @0-based
  ---@param col integer @0-based
  ---@param len integer @>=0
  function anchors.add(bufnr, lnum, col, len)
    jelly.debug("creating xmark, lnum=%d, col=%d, len=%s", lnum, col, len)
    --stylua: ignore
    local xmid = ni.buf_set_extmark(bufnr, facts.anchor_ns, lnum, col, {
      end_row = lnum, end_col = col + len,
      right_gravity = false, end_right_gravity = true,
    })
    return xmid
  end

  ---@class parrot.Anchor
  ---@field start_lnum integer @0-based, inclusive
  ---@field start_col  integer @0-based, inclusive
  ---@field stop_lnum  integer @0-based, exclusive
  ---@field stop_col   integer @0-based, exclusive

  ---@param xmid integer
  ---@return parrot.Anchor?
  function anchors.get(bufnr, xmid)
    local xm = ni.buf_get_extmark_by_id(bufnr, facts.anchor_ns, xmid, { details = true })
    jelly.debug("getting xmid=%s", xmid)

    if #xm == 0 then return end
    if xm[3].invalid then return end

    return { start_lnum = xm[1], start_col = xm[2], stop_lnum = xm[3].end_row + 1, stop_col = xm[3].end_col }
  end

  ---@param bufnr integer
  ---@param xmid integer
  function anchors.del(bufnr, xmid)
    --no matter what it returns, it might be false due to .invalidate=true option
    ni.buf_del_extmark(bufnr, facts.anchor_ns, xmid)
    jelly.debug("deleted xmid=%s", xmid)
  end

  ---@param winid integer
  ---@param anchor parrot.Anchor
  function anchors.vsel_or_goto(winid, anchor)
    if anchor.stop_lnum - anchor.start_lnum <= 1 and anchor.stop_col - anchor.start_col <= 1 then
      if strlib.startswith(ni.get_mode().mode, "v") then feedkeys.keys("<esc>", "n") end
      wincursor.go(winid, anchor.start_lnum, anchor.start_col)
    else
      vsel.select_region(winid, anchor.start_lnum, anchor.start_col, anchor.stop_lnum, anchor.stop_col)
    end
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

  function Impl:deactivated()
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

local expand
do
  ---@class parrot.ExpandRegion
  ---@field lnum integer
  ---@field col integer @0-based
  ---@field col_end integer @0-based, exclusive

  ---@class parrot.ExpandContex
  ---@field winid integer
  ---@field bufnr integer
  ---@field cursor {lnum: integer, col: integer}
  ---@field chirp parrot.compiler.Compiled
  ---@field region parrot.ExpandRegion
  ---@field indent string
  ---@field inserts string[]
  ---@field state parrot.BufState

  ---@param ctx parrot.ExpandContex
  local function handle_chirp_without_pitch(ctx)
    local state = ctx.state

    do --goto the end of expansion
      local lnum, col
      local cursor, inserts = ctx.cursor, ctx.inserts
      if #ctx.inserts == 1 then
        lnum = cursor.lnum
        col = cursor.col + #inserts[1] --insert_col + #firstline
      else
        lnum = cursor.lnum + #inserts - 1
        col = #ctx.indent + #inserts[#inserts] --indent + #lastline
      end
      wincursor.go(ctx.winid, lnum, col)
    end

    state:deactivated()
  end

  ---@param ctx parrot.ExpandContex
  local function handle_chirp_with_pitches(ctx)
    local state = ctx.state

    do ---anchor xmarks
      local xmids = {}

      local iter = itertools.iter(ctx.chirp.pitches)
      local lnumoff = ctx.cursor.lnum
      for pitch in iter do
        local coloff
        if pitch.lnum == 0 then
          --pitches at the first line
          coloff = ctx.region.col - 1
        else
          coloff = #ctx.indent - 1
        end
        local lnum = pitch.lnum + lnumoff
        local col = pitch.col + coloff
        local xmid = anchors.add(ctx.bufnr, lnum, col, #pitch.text)
        table.insert(xmids, xmid)
      end

      assert(#xmids == #ctx.chirp.pitches)
      state.xmids = xmids
    end

    do --goto min(nth) anchor
      local jump_idx
      do --try nth=1, or fallback to nth=0
        local nth1, nth0_idx
        for idx, pitch in ipairs(ctx.chirp.pitches) do
          if pitch.nth > 0 then
            if jump_idx == nil or pitch.nth < nth1 then
              jump_idx, nth1 = idx, pitch.nth
            end
          else
            nth0_idx = idx
          end
        end
        if jump_idx == nil then jump_idx = assert(nth0_idx) end
      end

      local anchor = assert(anchors.get(ctx.bufnr, state.xmids[jump_idx]))
      anchors.vsel_or_goto(0, anchor)

      state.jump_idx = jump_idx
    end

    state.active = true
  end

  ---@param chirp parrot.compiler.Compiled
  ---@param winid integer
  ---@param region parrot.ExpandRegion
  ---@return true?
  function expand(chirp, winid, region)
    local bufnr = ni.win_get_buf(winid)
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
    ni.buf_set_text(bufnr, region.lnum, region.col, region.lnum, region.col_end, inserts)

    local state = registry[bufnr]
    if state == nil then
      state = BufState(bufnr)
      registry[bufnr] = state
    end

    ---clean xmarks
    for _, xmid in ipairs(state.xmids) do
      anchors.del(state.bufnr, xmid)
    end

    local ctx = { winid = winid, bufnr = bufnr, cursor = cursor, chirp = chirp, region = region, indent = indent, inserts = inserts, state = state }

    if #chirp.pitches == 0 then
      handle_chirp_without_pitch(ctx)
    else
      handle_chirp_with_pitches(ctx)
    end

    return true
  end
end

function M.visual_expand()
  local winid = ni.get_current_win()
  local bufnr = ni.win_get_buf(winid)

  local xrange
  if ni.get_mode().mode == "i" then
    local cursor = wincursor.position(winid)
    local regex = vim.regex([[\v[^ ]+$]]) --unicode chars
    local mat_start, mat_stop = regex:match_line(bufnr, cursor.lnum, 0, cursor.col)
    if not (mat_start and mat_stop) then return jelly.warn("no leading text found") end
    xrange = { start_col = mat_start, start_line = cursor.lnum, stop_col = mat_stop, stop_line = cursor.lnum }
    --enter normal mode, necessary for beckon
    --and for unknown reason, mi.stopinsert() does not works well here
    ex("stopinsert")
  else
    xrange = vsel.range(bufnr, true)
    if xrange == nil then return jelly.warn("no visual selected text") end
    if xrange.stop_line - xrange.start_line > 1 then return jelly.warn("not support multi-line visual") end
  end

  local ft = prefer.bo(bufnr, "filetype")

  local keys ---@type string[]
  do
    if ft == nil or ft == "" then ft = "all" end
    keys = chirps.get_visual_keys(ft)
    if #keys == 0 then return jelly.warn("no available visual snippets") end
  end

  beckon_select(keys, { prompt = "🦜" }, function(key)
    if key == nil or key == "" then return end
    assert(ni.get_current_win() == winid)

    local xhirp = chirps.get_visual(ft, key)
    if xhirp == nil then return end

    local chirp
    do
      local xtext = assert(buflines.partial_line(bufnr, xrange.start_line, xrange.start_col, xrange.stop_col))
      local lines = its(xhirp) --
        :map(function(line) return string.gsub(line, "{visual}", xtext) end)
        :tolist()
      chirp = compiler(lines)
    end

    return expand(chirp, winid, { lnum = xrange.start_line, col = xrange.start_col, col_end = xrange.stop_col })
  end)
end

---@return true? @true when made an expansion
function M.expand()
  local winid = ni.get_current_win()
  local bufnr = ni.win_get_buf(winid)
  local cursor = wincursor.position(winid)
  local curline = assert(buflines.line(bufnr, cursor.lnum))

  local leading = string.sub(curline, 1, cursor.col)
  local key = string.match(leading, "[^ ]+$")
  if key == nil then return jelly.debug("no key found") end

  ---@type parrot.compiler.Compiled?
  local chirp = chirps.get_normal(prefer.bo(bufnr, "filetype"), key)
  if chirp == nil then return jelly.debug("no available snippet for %s", key) end

  return expand(chirp, winid, { lnum = cursor.lnum, col = cursor.col - #key, col_end = cursor.col })
end

---@param raw_chirp string[]
---@param winid integer
---@param region {lnum: integer, col: integer, col_end: integer} @col_end: exclusive?
function M.external_expand(raw_chirp, winid, region)
  jelly.info("expanding: %s", raw_chirp)
  return expand(compiler(raw_chirp), winid, region)
end

---@param step -1|1 @not support v.count right now
---@return true? @true if next hole exists
function M.jump(step)
  do --necessary for awkard mode changing
    local mode = ni.get_mode()
    assert(mode.blocking == false)
    assert(mode.mode == "n")
  end

  local winid = ni.get_current_win()
  local bufnr = ni.win_get_buf(winid)

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

  anchors.vsel_or_goto(winid, anchor)
  state.jump_idx = jump_idx

  return true
end

---always do expand not jump
function M.itab()
  if vim.fn.pumvisible() == 1 then return feedkeys("<c-y>", "n") end
  if M.expand() then
    --that's a dirty hack
    --to prevent vim entering a weird visual mode
    --which only occurs in imap
    return feedkeys("<esc>l", "n")
  end
  assert(strlib.startswith(ni.get_mode().mode, "i"))
  feedkeys("<tab>", "n")
end

---@param bufnr? integer
function M.cancel(bufnr)
  bufnr = mi.resolve_bufnr_param(bufnr)

  local state = registry[bufnr]
  if state == nil then return end
  if not state.active then return end

  local xmids = state.xmids

  state:deactivated()

  for _, xmid in ipairs(xmids) do
    anchors.del(state.bufnr, xmid)
  end
end

do --auxiliary apis
  ---@param ft? string
  ---@param open_mode? infra.bufopen.Mode
  function M.edit_chirp(ft, open_mode)
    if ft == nil then ft = prefer.bo(ni.get_current_buf(), "filetype") end
    if ft == "" then return jelly.warn("no available filetype") end
    open_mode = open_mode or "right"

    bufopen(open_mode, fs.joinpath(facts.user_root, string.format("%s.snippets", ft)))

    local chirp_bufnr = ni.get_current_buf()
    prefer.bo(chirp_bufnr, "bufhidden", "wipe")
    ni.create_autocmd("bufwipeout", { buffer = chirp_bufnr, once = true, callback = function() chirps.reset_ft_chirps(ft) end })
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
