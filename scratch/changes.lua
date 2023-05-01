-- 目的：监测某个区间行的动态变化
--
-- 具体实现：
-- * 首尾行内的新增、删除行 -> 记录
-- * 首尾行外的变化 -> 忽略
--
-- 其他情况
-- * 改动区间与本区间

-- delete one line: {}

local api = vim.api
local tail = require("infra.tail")
local fn = require("infra.fn")

---@class BufLineEventMaster
---@field private orig_start number
---@field private orig_last number
---@field private now_last number
local BufLineEventInterpreter = {}
do
  function BufLineEventInterpreter:op()
    local n = self.now_last - self.orig_last
    if n == 0 then
      return "noop"
    elseif n > 0 then
      return "add"
    else
      return "del"
    end
  end
  ---@return number
  function BufLineEventInterpreter:affected_lines() return math.abs(self.now_last - self.orig_last) end
  -- lines are 0-based
  -- left inclusive, right exclusive
  function BufLineEventInterpreter:added_line_range()
    assert(self:op() == "add", "unreachable")
    return self.orig_last, self.now_last
  end
  -- lines are 0-based and in asc order
  function BufLineEventInterpreter:added_lines()
    assert(self:op() == "add", "unreachable")
    return fn.range(self.orig_last, self.now_last)
  end
  -- lines are 0-based
  -- left inclusive, right exclusive
  function BufLineEventInterpreter:deleted_line_range()
    assert(self:op() == "del", "unreachable")
    return self.now_last, self.orig_last
  end
  -- lines are 0-based and in asc order
  function BufLineEventInterpreter:deleted_lines()
    assert(self:op() == "del", "unreachable")
    return fn.range(self.now_last, self.orig_last)
  end

  ---@param ... any @same to the signature of nvim_buf_attach.on_lines()
  ---@return BufLineEventMaster
  function BufLineEventInterpreter.new(...)
    local _, _, _, orig_start, orig_last, now_last = ...
    return setmetatable({ orig_start = orig_start, orig_last = orig_last, now_last = now_last }, { __index = BufLineEventInterpreter })
  end
end

local bufnr = api.nvim_get_current_buf()

vim.wo.list = true
vim.wo.listchars = "tab:> ,trail:-,nbsp:+,eol:j"

local fpath = "/tmp/nvim-line-changes.log"
tail.split_below(fpath)

local file = assert(io.open(fpath, "w"))
api.nvim_buf_attach(bufnr, false, {
  on_lines = function(...)
    local interpret = BufLineEventInterpreter.new(...)
    local _, _, tick, orig_start, orig_last, now_last = ...

    local op = interpret:op()
    local lines = {}
    local line_range = {}
    if op == "add" then
      line_range = { interpret:added_line_range() }
      lines = fn.concrete(interpret:added_lines())
    elseif op == "del" then
      line_range = { interpret:deleted_line_range() }
      lines = fn.concrete(interpret:deleted_lines())
    else
      line_range = { "n/a" }
      lines = { "n/a" }
    end

    file:write(string.format("tick=%d origin=[%d, %d) now=[%d, %d) op=%s n=%d range=%s lines=%s\n", tick, orig_start, orig_last, orig_start, now_last, op, interpret:affected_lines(), table.concat(line_range, "~"), table.concat(lines, ",")))
    file:flush()
  end,
})
