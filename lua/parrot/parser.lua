-- definitions in .snippets (partially compatible with UltiSnips)
-- * `^snippet name$` block start
-- * `^endsnippet`    block end
-- * `^#`             comment
-- * `^\s*$`          blank line

local its = require("infra.its")
local jelly = require("infra.jellyfish")("parrot.parser", "info")

local function startswith(str, mark) return string.sub(str, 1, #mark) == mark end

local process_outside_defn, process_inside_defn

---@class parrot.ParsingState
---@field next fun(self: parrot.ParsingState, line: string)
---@field current_block string[]?
---@field blocks {["string"]: string[]}

---@return parrot.ParsingState
local function ParsingState() return { next = process_outside_defn, blocks = {}, current_block = nil } end

---@param state parrot.ParsingState
---@param line string
function process_outside_defn(state, line)
  assert(state.current_block == nil)
  state.next = nil
  jelly.debug("outside next: nil; line: '%s'", line)

  -- comment
  if startswith(line, "#") then
    state.next = process_outside_defn
    jelly.debug("outside next: comment")
    return
  end

  -- blank line
  if string.find(line, "^%s*$") then
    state.next = process_outside_defn
    jelly.debug("outside next: blank")
    return
  end

  if startswith(line, "snippet ") then
    do
      local name = string.sub(line, 8 + 1) -- #'snippet ' == 8
      if state.blocks[name] ~= nil then error(string.format("duplicate blocks for %s", name)) end
      local block = {}
      state.blocks[name] = block
      state.current_block = block
    end
    state.next = process_inside_defn
    jelly.debug("outside next: inside - block begin")
    return
  end

  error(string.format("unreachable; line: %s", vim.inspect(line)))
end

---@param state parrot.ParsingState
---@param line string
function process_inside_defn(state, line)
  assert(state.current_block ~= nil)
  state.next = nil
  jelly.debug("inside next: nil; line: '%s'", line)

  if startswith(line, "endsnippet") then
    state.next = process_outside_defn
    state.current_block = nil
    jelly.debug("inside next: outside - block end")
    return
  end

  state.next = process_inside_defn
  jelly.debug("inside next: append")
  table.insert(state.current_block, line)
end

---@param fpaths (fun(): string?)|string[]
---@return {[string]: string[]}
return function(fpaths)
  local state = ParsingState()

  local iter = its(fpaths):map(io.lines):flat()

  for line in iter do
    assert(state.next)
    state.next(state, line)
  end

  return state.blocks
end
