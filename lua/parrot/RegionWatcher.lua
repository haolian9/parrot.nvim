local api = vim.api
local fn = require("infra.fn")
local jelly = require("infra.jellyfish")("parrot.regionwatcher", vim.log.levels.DEBUG)

---@class BufLineEventMaster
---@field private orig_first number
---@field private orig_last number
---@field private now_last number
---@field op string
---@field affected_lines number
local BufLineEventInterpreter = {}
do
  -- lines are 0-based
  -- left inclusive, right exclusive
  function BufLineEventInterpreter:orig_range() return self.orig_first, self.orig_last end
  -- lines are 0-based
  -- left inclusive, right exclusive
  function BufLineEventInterpreter:now_range() return self.orig_first, self.now_last end

  -- lines are 0-based
  -- left inclusive, right exclusive
  function BufLineEventInterpreter:added_range()
    assert(self.op == "add", "unreachable")
    return self.orig_last, self.now_last
  end
  -- lines are 0-based and in asc order
  function BufLineEventInterpreter:added_lines()
    assert(self.op == "add", "unreachable")
    return fn.range(self.orig_last, self.now_last)
  end
  -- lines are 0-based
  -- left inclusive, right exclusive
  function BufLineEventInterpreter:deleted_range()
    assert(self.op == "del", "unreachable")
    return self.now_last, self.orig_last
  end
  -- lines are 0-based and in asc order
  function BufLineEventInterpreter:deleted_lines()
    assert(self.op == "del", "unreachable")
    return fn.range(self.now_last, self.orig_last)
  end

  ---@param ... any @same to the signature of nvim_buf_attach.on_lines()
  ---@return BufLineEventMaster
  function BufLineEventInterpreter.new(...)
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
    }, { __index = BufLineEventInterpreter })
  end
end

---@param bufnr number
---@param start_line number 0-based, inclusive
---@param stop_line number 0-based, exclusive
return function(bufnr, start_line, stop_line)
  do
    vim.validate({ bufnr = { bufnr, "number" }, start_line = { start_line, "number" }, stop_line = { stop_line, "number" } })
    assert(start_line >= 0 and stop_line <= api.nvim_buf_line_count(bufnr))
  end

  jelly.debug("start watching buf=%d [%d, %d)", bufnr, start_line, stop_line)

  local state = {
    --canceled by user
    cancel = false,
    --Watcher is working or not
    watching = nil,
    --watched range will be dynamically changed
    --[start, stop)
    range = { start_line, stop_line },
  }

  ---@return true
  local function stop_watching()
    jelly.debug("watcher detaching")
    state.watching = false
    state.range = nil
    return true
  end

  state.watching = true
  api.nvim_buf_attach(bufnr, false, {
    on_lines = function(...)
      assert(state.watching)
      if state.cancel then return stop_watching() end

      local interpret = BufLineEventInterpreter.new(...)
      local _, _, _, orig_first, orig_last, now_last = ...
      assert(state.range ~= nil)

      if interpret.op == "add" then
        -- 已知条件：
        -- * orig与now区间的start不变
        -- * 只需考虑orig_first与watching.range的关系

        if orig_first >= state.range[2] then
        -- below, no overlap
        -- no-op
        elseif orig_first < state.range[1] then
          -- above watch, no overlap
          state.range[1] = state.range[1] + interpret.affected_lines
          state.range[2] = state.range[2] + interpret.affected_lines
        else
          -- within watch
          -- watch.start needs no change
          state.range[2] = state.range[2] + interpret.affected_lines
        end
      elseif interpret.op == "del" then
        -- 已知条件：
        -- * orig与now区间的start不变
        -- * 如果有orig与watch交集，则watch必shrink

        if orig_first >= state.range[2] then
        -- below watch, no overlap
        elseif orig_last < state.range[1] then
          -- above watch, no overlap
          state.range[1] = state.range[1] - interpret.affected_lines
          state.range[2] = state.range[2] - interpret.affected_lines
        elseif orig_first == state.range[1] and orig_last == state.range[2] then
          -- equal watch
          if orig_first == now_last then
            -- all line are deleted, stop watching
            return stop_watching()
          else
            state.range[1] = state.range[1] - interpret.affected_lines
          end
        elseif orig_first <= state.range[1] then
          -- within watch
          -- -- all lines in range are deleted
          if now_last <= state.range[1] then return stop_watching() end
          if orig_last > state.range[2] then
            state.range[2] = now_last
          else
            state.range[2] = state.range[2] - interpret.affected_lines
          end
        else
          -- above-half watch, overlap
          if orig_last > state.range[2] then
            state.range[2] = now_last
          else
            state.range[2] = state.range[2] - interpret.affected_lines
          end
        end
      else
        -- no-op
        assert(interpret.op == "nochange")
      end
      assert(state.range[1] >= 0, state.range[1])
      assert(state.range[2] >= 0, state.range[2])
    end,
  })

  return {
    bufnr = bufnr,
    cancel = function() state.cancel = true end,
    range = function() return unpack(state.range or {}) end,
  }
end
