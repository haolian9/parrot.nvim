local M = {}

local fs = require("infra.fs")
local ni = require("infra.ni")

---@diagnostic disable-next-line: param-type-mismatch
M.user_root = fs.joinpath(vim.fn.stdpath("config"), "chirps")

M.anchor_ns = ni.create_namespace("parrot:anchors")

return M
