local M = {}

local fs = require("infra.fs")
local itertools = require("infra.itertools")
local strlib = require("infra.strlib")

local compiler = require("parrot.compiler")
local facts = require("parrot.facts")
local parser = require("parrot.parser")

---cache of chirps: {filetype: {key: Compiled}}
---@type {[string]: {[string]: parrot.compiler.Compiled}}
local chirps = {}

---@param ft string
---@return fun(): string? @absolute paths
local function collect_chirp_files(ft)
  local iter

  iter = fs.iterfiles(facts.user_root)

  local exact = string.format("%s.snippets", ft)
  local prefix = string.format("%s-", ft)
  iter = itertools.filter(function(fname) return fname == exact or strlib.startswith(fname, prefix) end, iter)

  iter = itertools.map(function(fname) return fs.joinpath(facts.user_root, fname) end, iter)

  return iter
end

---@param ft string
local function get_ft_chirps(ft)
  local held = chirps[ft]
  if held ~= nil then return held end

  local compiled = {}
  local parsed = parser(collect_chirp_files(ft))
  for key, lines in pairs(parsed) do
    compiled[key] = compiler(lines)
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
