local itertools = require("infra.itertools")
local listlib = require("infra.listlib")
local strlib = require("infra.strlib")

local ropes = require("string.buffer")

---@class parrot.Pitch
---@field lnum integer @0-based, inclusive
---@field col integer @0-based, inclusive
---@field raw string
---@field nth integer
---@field text string
---@field xmid? integer @extmark id

local compile_line
do
  ---@alias parrot.compiler.Try fun(str: string, offset: integer): integer?,integer?,integer?,string?

  ---@type parrot.compiler.Try[] @iter(start,stop,num,text)
  local tries = {
    function(str, offset)
      local start, stop = string.find(str, "%$%d+", offset, false)
      if not (start and stop) then return end
      stop = stop + 1
      local nth = assert(tonumber(string.sub(str, start + #"$", stop - 1)))
      return start, stop, nth, ""
    end,

    function(str, offset)
      local start, stop = string.find(str, "%${%d+}", offset, false)
      if not (start and stop) then return end
      stop = stop + 1
      local nth = assert(tonumber(string.sub(str, start + #"${", stop - #"}" - 1)))
      return start, stop, nth, ""
    end,

    function(str, offset)
      local start, stop = string.find(str, "%${%d+:}", offset, false)
      if not (start and stop) then return end
      stop = stop + 1
      local nth = assert(tonumber(string.sub(str, start + #"${", stop - #":}" - 1)))
      return start, stop, nth, ""
    end,

    function(str, offset)
      local start, stop = string.find(str, "%${%d+:[^}]+}", offset, false)
      if not (start and stop) then return end
      stop = stop + 1
      local iter = strlib.iter_splits(string.sub(str, start + #"${", stop - #"}" - 1), ":", 1)
      local nth = assert(tonumber(iter()))
      local text = assert(iter())
      return start, stop, nth, text
    end,
  }

  ---@class parrot.compiler.Found
  ---@field start integer
  ---@field stop integer
  ---@field nth integer
  ---@field text string @text being purified

  ---@param str string
  ---@param try parrot.compiler.Try
  ---@return fun(): parrot.compiler.Found?
  local function try_find_all(str, try)
    local offset = 1
    return function()
      local start, stop, nth, text = try(str, offset)
      if not (start and stop and nth and text) then return end
      offset = stop
      return { start = start, stop = stop, nth = nth, text = text }
    end
  end

  ---@param lnum integer
  ---@param line string
  ---@return fun(): parrot.Pitch?
  local function collect_pitches(lnum, line)
    assert(lnum ~= nil)
    assert(line ~= nil)

    local iter
    iter = itertools.iter(tries)
    iter = itertools.map(function(try) return try_find_all(line, try) end, iter)
    iter = itertools.flatten(iter)

    ---@param found parrot.compiler.Found
    iter = itertools.map(function(found)
      if found == nil then return end
      return { lnum = lnum, col = found.start, raw = string.sub(line, found.start, found.stop - 1), nth = found.nth, text = found.text }
    end, iter)
    ---@param pitch? parrot.Pitch
    iter = itertools.filter(function(pitch) return pitch ~= nil end, iter)

    return iter
  end

  ---@param lnum integer
  ---@param line string
  ---@return string compiled_line
  ---@return parrot.Pitch[] pitches
  function compile_line(lnum, line)
    assert(lnum ~= nil)
    assert(line ~= nil)

    ---@type parrot.Pitch[]
    local pitches = itertools.tolist(collect_pitches(lnum, line))
    if #pitches == 0 then return line, {} end

    table.sort(pitches, function(a, b) return a.col < b.col end)

    local compiled_line
    do
      local rope = ropes.new()
      local offset = 1
      for _, p in ipairs(pitches) do
        if offset < p.col then
          rope:put(string.sub(line, offset, p.col - 1), p.text)
        elseif offset == p.col then
          rope:put(p.text)
        else
          error("unreachable")
        end
        offset = p.col + #p.raw
      end
      if offset <= #line then rope:put(string.sub(line, offset)) end
      compiled_line = rope:get()
    end

    return compiled_line, pitches
  end
end

---@class parrot.compiler.Compiled
---@field lines string[]
---@field pitches parrot.Pitch[]

---@param chirp string[]
---@return parrot.compiler.Compiled
return function(chirp)
  local lines, pitches = {}, {}
  do
    local iter
    iter = listlib.enumerate(chirp)
    iter = itertools.mapn(compile_line, iter)

    for line, line_pitches in iter do
      table.insert(lines, line)
      listlib.extend(pitches, line_pitches)
    end
  end

  return { lines = lines, pitches = pitches }
end
