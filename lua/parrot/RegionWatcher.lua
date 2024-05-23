local buflines = require("infra.buflines")
local itertools = require("infra.itertools")
local jelly = require("infra.jellyfish")("parrot.regionwatcher")

local api = vim.api

local BufLineEventInterpreter
do
  ---@class BufLineEventMaster
  ---@field private orig_first number
  ---@field private orig_last number
  ---@field private now_last number
  ---@field op string
  ---@field affected_lines number
  local Impl = {}

  Impl.__index = Impl

  -- lines are 0-based
  -- left inclusive, right exclusive
  function Impl:orig_range() return self.orig_first, self.orig_last end
  -- lines are 0-based
  -- left inclusive, right exclusive
  function Impl:now_range() return self.orig_first, self.now_last end

  -- lines are 0-based
  -- left inclusive, right exclusive
  function Impl:added_range()
    assert(self.op == "add", "unreachable")
    return self.orig_last, self.now_last
  end
  -- lines are 0-based and in asc order
  function Impl:added_lines()
    assert(self.op == "add", "unreachable")
    return itertools.range(self.orig_last, self.now_last)
  end
  -- lines are 0-based
  -- left inclusive, right exclusive
  function Impl:deleted_range()
    assert(self.op == "del", "unreachable")
    return self.now_last, self.orig_last
  end
  -- lines are 0-based and in asc order
  function Impl:deleted_lines()
    assert(self.op == "del", "unreachable")
    return itertools.range(self.now_last, self.orig_last)
  end

  ---@param ... any @same to the signature of nvim_buf_attach.on_lines()
  ---@return BufLineEventMaster
  function BufLineEventInterpreter(...)
    local _, _, _, orig_first, orig_last, now_last = ...

    local n = now_last - orig_last

    local op
    if n == 0 then
      op = "nochange"
    elseif n > 0 then
      op = "add"
    else
      op = "del"
    end

    local affected_lines = math.abs(n)

    return setmetatable({
      orig_first = orig_first,
      orig_last = orig_last,
      now_last = now_last,
      op = op,
      affected_lines = affected_lines,
    }, Impl)
  end
end

---@class parrot.RegionWatcher.State
---@field bufnr number
---@field cancelled boolean @true when canceled by user
---@field watching boolean @watcher is working or not
--
--watching range will be changed dynamically
--inclusive start_line, exclusive stop_line
---@field range? {start_line: number?, stop_line: number?}

---@class parrot.RegionWatcher
---@field private state parrot.RegionWatcher.State
local RegionWatcher = {}
do
  RegionWatcher.__index = RegionWatcher

  --used by on_lines() only
  ---@private
  ---@return true
  function RegionWatcher:stop_watching()
    jelly.debug("watcher detaching")
    self.state.watching = false
    self.state.range = nil
    return true
  end

  ---@private
  ---@param ... any @arguments of nvim_buf_attach.on_lines()
  ---@return true?
  function RegionWatcher:on_lines(...)
    local state = self.state

    assert(state.watching)
    if state.cancelled then return self:stop_watching() end

    local interpret = BufLineEventInterpreter(...)
    local _, _, _, orig_first, orig_last, now_last = ...
    assert(state.range ~= nil)

    if interpret.op == "add" then
      -- 已知条件：
      -- * orig与now区间的start不变
      -- * 只需考虑orig_first与watching.range的关系

      if orig_first >= state.range.stop_line then
      -- below, no overlap
      -- no-op
      elseif orig_first < state.range.start_line then
        -- above watch, no overlap
        state.range.start_line = state.range.start_line + interpret.affected_lines
        state.range.stop_line = state.range.stop_line + interpret.affected_lines
      else
        -- within watch
        -- watch.start needs no change
        state.range.stop_line = state.range.stop_line + interpret.affected_lines
      end
    elseif interpret.op == "del" then
      -- 已知条件：
      -- * orig与now区间的start不变
      -- * 如果有orig与watch交集，则watch必shrink

      if orig_first >= state.range.stop_line then
      -- below watch, no overlap
      elseif orig_last < state.range.start_line then
        -- above watch, no overlap
        state.range.start_line = state.range.start_line - interpret.affected_lines
        state.range.stop_line = state.range.stop_line - interpret.affected_lines
      elseif orig_first == state.range.start_line and orig_last == state.range.stop_line then
        -- equal watch
        if orig_first <= now_last then
          -- all line are deleted, stop watching
          return self:stop_watching()
        else
          state.range.start_line = state.range.start_line - interpret.affected_lines
        end
      elseif orig_first <= state.range.start_line then
        -- within watch
        -- -- all lines in range are deleted
        if now_last <= state.range.start_line then return self:stop_watching() end
        if orig_last > state.range.stop_line then
          state.range.stop_line = now_last
        else
          state.range.stop_line = state.range.stop_line - interpret.affected_lines
        end
      else
        -- above-half watch, overlap
        if orig_last > state.range.stop_line then
          state.range.stop_line = now_last
        else
          state.range.stop_line = state.range.stop_line - interpret.affected_lines
        end
      end
    else
      -- no-op
      assert(interpret.op == "nochange")
    end

    if not (state.range.start_line >= 0 and state.range.stop_line >= 0) then
      jelly.err("state.range=%s, op=%s, origin.first=%d,last=%d, now.last=%d", state.range, interpret.op, orig_first, orig_last, now_last)
      error("unreachable")
    end
  end

  function RegionWatcher:bufnr() return self.state.bufnr end

  function RegionWatcher:cancel()
    assert(not self.state.cancelled, "re-cancelling")
    if not self.state.watching then return end
    self.state.cancelled = true
  end

  ---@return number?,number?
  function RegionWatcher:range()
    local range = self.state.range
    if range then return range.start_line, range.stop_line end
  end
end

---@param bufnr number
---@param start_line number 0-based, inclusive
---@param stop_line number 0-based, exclusive
---@return parrot.RegionWatcher
return function(bufnr, start_line, stop_line)
  do
    assert(type(bufnr) == "number" and type(start_line) == "number" and type(stop_line) == "number")
    assert(start_line >= 0 and stop_line <= buflines.count(bufnr))
  end

  jelly.debug("start watching buf=%d [%d, %d)", bufnr, start_line, stop_line)

  local watcher = setmetatable({
    state = { bufnr = bufnr, cancelled = false, watching = true, range = { start_line = start_line, stop_line = stop_line } },
  }, RegionWatcher)

  ---@diagnostic disable-next-line: invisible
  api.nvim_buf_attach(bufnr, false, { on_lines = function(...) return watcher:on_lines(...) end })

  return watcher
end
