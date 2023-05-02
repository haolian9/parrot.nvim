local api = vim.api
local fn = require("infra.fn")
local logging = require("infra.logging")

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

local log = logging.newlogger("watchchanges", vim.log.levels.DEBUG)

local bufnr = api.nvim_get_current_buf()

vim.wo.list = true
vim.wo.listchars = "tab:> ,trail:-,nbsp:+,eol:j"
vim.go.shortmess = ""

assert(api.nvim_buf_line_count(bufnr) >= 10, "need a larger buffer")

-- [first, last)
local watching_range = { 0, 10 }

local function fmt_range(...)
  local nargs = select("#", ...)
  if nargs == 0 then
    return "n/a"
  elseif nargs == 1 then
    return string.format("%d~%d", unpack(select(1, ...)))
  elseif nargs == 2 then
    return string.format("%d~%d", ...)
  else
    error("unreachable")
  end
end

api.nvim_buf_attach(bufnr, false, {
  on_lines = function(...)
    local interpret = BufLineEventInterpreter.new(...)
    local _, _, tick, orig_first, orig_last, now_last = ...

    assert(watching_range ~= nil)

    if interpret.op == "add" then
      -- 已知条件：
      -- * orig与now区间的start不变
      -- * 只需考虑orig_first与watching_range的关系

      if orig_first >= watching_range[2] then
        -- below, no overlap
        log.debug("add#a")
        -- no-op
      elseif orig_first < watching_range[1] then
        -- above watch, no overlap
        log.debug("add#b")
        watching_range[1] = watching_range[1] + interpret.affected_lines
        watching_range[2] = watching_range[2] + interpret.affected_lines
      else
        -- within watch
        -- watch.start needs no change
        log.debug("add#c")
        watching_range[2] = watching_range[2] + interpret.affected_lines
      end

      log.debug("orig=%s, now=%s, watch=%s", fmt_range(interpret:orig_range()), fmt_range(interpret:now_range()), fmt_range(watching_range))
    elseif interpret.op == "del" then
      -- 已知条件：
      -- * orig与now区间的start不变
      -- * 如果有orig与watch交集，则watch必shrink

      if orig_first >= watching_range[2] then
        -- below watch, no overlap
        log.debug("del#a")
      elseif orig_last < watching_range[1] then
        -- above watch, no overlap
        log.debug("del#b")
        watching_range[1] = watching_range[1] - interpret.affected_lines
        watching_range[2] = watching_range[2] - interpret.affected_lines
      elseif orig_first == watching_range[1] and orig_last == watching_range[2] then
        -- equal watch
        if orig_first == now_last then
          -- all line are deleted, stop watching
          log.debug("del#c")
          return true
        else
          log.debug("del#d")
          watching_range[1] = watching_range[1] - interpret.affected_lines
        end
      elseif orig_first <= watching_range[1] then
        -- within watch
        log.debug("del#e")
        watching_range[2] = watching_range[2] - interpret.affected_lines
      else
        -- above-half watch, overlap
        log.debug("del#f")
        if orig_last > watching_range[2] then
          watching_range[2] = now_last
        else
          watching_range[2] = watching_range[2] - interpret.affected_lines
        end
      end

      log.debug("orig=%s, now=%s, watch=%s", fmt_range(interpret:orig_range()), fmt_range(interpret:now_range()), fmt_range(watching_range))
    else
      -- no-op
      assert(interpret.op == "nochange")
    end
    assert(watching_range[1] >= 0 and watching_range[2] >= 0)
  end,
})
