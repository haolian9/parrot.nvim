local api = vim.api

local bufnr = api.nvim_get_current_buf()
local ns = api.nvim_create_namespace("sss")
-- for: `$0`, `${0}`, `${0:zero}`
local matcher = vim.regex([[\v(\$\d+)|(\$\{\d+(:[^}]+)?\})]])

api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

---@type {[number]: number[]}
local matches = {}
for lnum = 0, api.nvim_buf_line_count(bufnr) - 1 do
  matches[lnum] = {}
  local offset = 0
  while true do
    local col_start, col_stop
    do
      local rel_start, rel_stop = matcher:match_line(bufnr, lnum, offset)
      if rel_start == nil then break end
      col_start = rel_start + offset
      col_stop = rel_stop + offset
    end
    offset = col_stop
    api.nvim_buf_add_highlight(bufnr, ns, "Search", lnum, col_start, col_stop)
    table.insert(matches[lnum], col_start)
    table.insert(matches[lnum], col_stop)
  end
end

vim.notify(vim.inspect(matches))
