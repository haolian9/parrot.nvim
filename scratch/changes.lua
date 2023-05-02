local api = vim.api
local tail = require("infra.tail")
local fn = require("infra.fn")

---@class BufLineEventMaster
---@field private orig_start number
---@field private orig_last number
---@field private now_last number
---@field op string
---@field affected_lines number
local BufLineEventInterpreter = {}
do
  -- lines are 0-based
  -- left inclusive, right exclusive
  function BufLineEventInterpreter:orig_range() return self.orig_start, self.orig_last end
  -- lines are 0-based
  -- left inclusive, right exclusive
  function BufLineEventInterpreter:now_range() return self.orig_start, self.now_last end

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
    local _, _, _, orig_start, orig_last, now_last = ...

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
      orig_start = orig_start,
      orig_last = orig_last,
      now_last = now_last,
      op = op,
      affected_lines = affected_lines,
    }, { __index = BufLineEventInterpreter })
  end
end

local bufnr = api.nvim_get_current_buf()

vim.wo.list = true
vim.wo.listchars = "tab:> ,trail:-,nbsp:+,eol:j"

assert(api.nvim_buf_line_count(bufnr) >= 10, "need a larger buffer")

local fpath = "/tmp/nvim-line-changes.log"
tail.split_below(fpath)

local file = assert(io.open(fpath, "w"))
api.nvim_buf_attach(bufnr, false, {
  on_lines = function(...)
    local interpret = BufLineEventInterpreter.new(...)
    local _, _, tick, orig_start, orig_last, now_last = ...

    local lines = {}
    local line_range = {}
    if interpret.op == "add" then
      line_range = { interpret:added_range() }
      lines = fn.concrete(interpret:added_lines())
    elseif interpret.op == "del" then
      line_range = { interpret:deleted_range() }
      lines = fn.concrete(interpret:deleted_lines())
    else
      line_range = { "n/a" }
      lines = { "n/a" }
    end

    file:write(string.format("tick=%d origin=[%d, %d) now=[%d, %d) op=%s n=%d range=%s lines=%s\n", tick, orig_start, orig_last, orig_start, now_last, interpret.op, interpret.affected_lines, table.concat(line_range, "~"), table.concat(lines, ",")))
    file:flush()
  end,
})
