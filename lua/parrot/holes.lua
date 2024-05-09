local M = {}

local wincursor = require("infra.wincursor")

local api = vim.api
local jelly = require("infra.jellyfish")("parrot.holes")

-- for: `$0`, `${0}`, `${0:zero}`, `${0:}`
local matcher = vim.regex([[\v\$\d+|\$\{\d+(:[^}]*)?\}]])

---@param bufnr number
---@param start_line number inclusive
---@param stop_line number exclusive
---@return number?,number?,number?
local function first_match_in_lines(bufnr, start_line, stop_line)
  for lnum = start_line, stop_line - 1 do
    local col_start, col_stop = matcher:match_line(bufnr, lnum)
    -- no matches in this line
    if col_start ~= nil then return lnum, col_start, col_stop end
  end
end

---@param winid number
---@param start_line number inclusive
---@param stop_line number exclusive
---@return number?,number?,number? @0-indexed lnum, col_start, col_stop
function M.next(winid, start_line, stop_line)
  local bufnr = api.nvim_win_get_buf(winid)

  local cursor = wincursor.position(winid)

  -- cursor is above the range
  if cursor.lnum < start_line then return first_match_in_lines(bufnr, start_line, stop_line) end
  -- cursor is below the range
  if cursor.lnum > stop_line then return first_match_in_lines(bufnr, start_line, stop_line) end

  do -- cursor line - after cursor
    local rel_start, rel_stop = matcher:match_line(bufnr, cursor.lnum, cursor.col)
    if rel_start ~= nil then
      local col_start = rel_start + cursor.col
      local col_stop = rel_stop + cursor.col
      jelly.debug("next socket - cursor line - after cursor")
      return cursor.lnum, col_start, col_stop
    end
  end

  do -- below lines
    local lnum, col_start, col_stop = first_match_in_lines(bufnr, cursor.lnum + 1, stop_line)
    if lnum ~= nil then
      jelly.debug("next socket - below lines")
      return lnum, col_start, col_stop
    end
  end

  do -- above lines
    local lnum, col_start, col_stop = first_match_in_lines(bufnr, start_line, cursor.lnum)
    if lnum ~= nil then
      jelly.debug("next socket - above lines")
      return lnum, col_start, col_stop
    end
  end

  do -- cursor line - before cursor
    local col_start, col_stop = matcher:match_line(bufnr, cursor.lnum)
    if col_start ~= nil and col_start < cursor.col then
      jelly.debug("next socket - cursor line - before cursor")
      return cursor.lnum, col_start, col_stop
    end
  end

  -- no next
end

return M
