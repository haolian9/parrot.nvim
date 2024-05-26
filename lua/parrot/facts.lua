local M = {}

local fs = require("infra.fs")

local api = vim.api

---@diagnostic disable-next-line: param-type-mismatch
M.user_root = fs.joinpath(vim.fn.stdpath("config"), "chirps")

M.anchor_ns = api.nvim_create_namespace("parrot:anchors")

return M
