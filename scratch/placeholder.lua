-- todo: monitor reg`/` change
-- todo: aware of `\%V`
local api = vim.api

local bufnr = api.nvim_get_current_buf()
local ns = api.nvim_create_namespace("sss")
local matcher = vim.regex([[\v(\$\d+)|(\$\{\d+(:[^}]+)?\})]])

api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

for i = 0, api.nvim_buf_line_count(bufnr) - 1 do
  local col_start, col_stop = matcher:match_line(bufnr, i)
  if col_start ~= nil then api.nvim_buf_add_highlight(bufnr, ns, "Search", i, col_start, col_stop) end
end
