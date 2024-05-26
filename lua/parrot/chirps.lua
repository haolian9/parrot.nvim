local M = {}

local itertools = require("infra.itertools")

local compiler = require("parrot.compiler")
local parser = require("parrot.parser")

local api = vim.api

---cache of chirps: {filetype: {key: Compiled}}
---@type {[string]: {[string]: parrot.compiler.Compiled}}
local chirps = {}

---@param ft string
local function collect_chirp_files(ft)
  local iter
  iter = itertools.iter({ "chirps/%s.snippets", "chirps/%s-*.snippets" })
  iter = itertools.map(function(fmt) return api.nvim_get_runtime_file(string.format(fmt, ft), true) end, iter)
  iter = itertools.flatten(iter)

  return iter
end

---@param ft string
local function get_ft_chirps(ft)
  local held = chirps[ft]
  if held ~= nil then return held end

  local compiled = {}
  do
    local parsed = parser(collect_chirp_files(ft))
    for key, lines in pairs(parsed) do
      compiled[key] = compiler(lines)
    end
  end

  chirps[ft] = compiled

  return compiled
end

---CAUTION: as the result is shared, caller should not mutate it
---@param ft string @the &filetype
---@param key string
---@return parrot.compiler.Compiled?
function M.get(ft, key) return get_ft_chirps(ft)[key] or get_ft_chirps("all")[key] end

---@param ft string
function M.reset_ft_chirps(ft) chirps[ft] = nil end

return M
