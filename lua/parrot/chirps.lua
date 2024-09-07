local M = {}

local dictlib = require("infra.dictlib")
local fs = require("infra.fs")
local its = require("infra.its")
local strlib = require("infra.strlib")

local compiler = require("parrot.compiler")
local facts = require("parrot.facts")
local parser = require("parrot.parser")

---@class parrot.FiletypeChirps
---@field normal {[string]: parrot.compiler.Compiled} @{key: Compiled}
---@field visual {[string]: string[]} @{key: Parsed}; the '{visual}' will be striped from the key

---@type {[string]: parrot.FiletypeChirps}
local chirps = {}

---@param ft string
---@return fun(): string? @absolute paths
local function iter_chirp_files(ft)
  local matches = strlib.Glob(ft .. ".snippets", ft .. "-*.snippets")

  return its(fs.iterfiles(facts.user_root)) --
    :filter(function(fname) return matches(fname) end)
    :map(function(fname) return fs.joinpath(facts.user_root, fname) end)
    :unwrap()
end

---@param ft string
---@return parrot.FiletypeChirps
local function get_ft_chirps(ft)
  local held = chirps[ft]
  if held ~= nil then return held end

  local normal, visual = {}, {}
  local parsed = parser(iter_chirp_files(ft))
  for key, lines in pairs(parsed) do
    if strlib.startswith(key, "{visual}") then
      visual[string.sub(key, #"{visual}" + 1)] = lines
    else
      normal[key] = compiler(lines)
    end
  end
  chirps[ft] = { normal = normal, visual = visual }

  return chirps[ft]
end

---CAUTION: as the result is shared, caller should not mutate it
---@param ft string @the &filetype
---@param key string
---@return parrot.compiler.Compiled?
function M.get_normal(ft, key) --
  return get_ft_chirps(ft).normal[key] or get_ft_chirps("all").normal[key]
end

---CAUTION: as the result is shared, caller should not mutate it
---@param ft string @the &filetype
---@param key string
---@return string[]?
function M.get_visual(ft, key) --
  return get_ft_chirps(ft).visual[key] or get_ft_chirps("all").visual[key]
end

---including ft='all'
---@param ft string
---@return string[]
function M.get_visual_keys(ft)
  local for_all = dictlib.keys(get_ft_chirps("all").visual)
  if ft == "all" then return for_all end
  return dictlib.merged(dictlib.keys(get_ft_chirps(ft).visual), for_all)
end

---@param ft string
function M.reset_ft_chirps(ft) chirps[ft] = nil end

return M
