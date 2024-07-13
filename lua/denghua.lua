local M = {}

local augroups = require("infra.augroups")
local highlighter = require("infra.highlighter")
local ni = require("infra.ni")

---@param bufnr integer
---@param mark "^"|"."|string
---@return integer? lnum @0-based
---@return integer? col @0-based
local function get_bufmark(bufnr, mark)
  local row, col = unpack(ni.buf_get_mark(bufnr, mark))
  if row == 0 then return end
  return row - 1, col
end

local Xmarks
do
  local ns = ni.create_namespace("denghua.xmarks")

  do
    local hi = highlighter(0)
    if vim.go.background == "light" then
      hi("Denghua", { fg = 1 })
    else
      hi("Denghua", { fg = 9 })
    end
  end

  ---@class denghua.Xmarks
  ---@field bufnr integer
  local Impl = {}
  Impl.__index = Impl

  ---@param xmid? integer
  function Impl:del(xmid)
    if xmid == nil then return end
    ni.buf_del_extmark(self.bufnr, ns, xmid)
  end

  function Impl:upsert(xmid, lnum, col, emoji)
    return ni.buf_set_extmark(self.bufnr, ns, lnum, col, {
      id = xmid,
      virt_text = { { emoji, "Denghua" } },
      virt_text_pos = "inline",
    })
  end

  ---@param bufnr integer
  ---@return denghua.Xmarks
  function Xmarks(bufnr) return setmetatable({ bufnr = bufnr }, Impl) end
end

---{bufnr: detach}
---@type {[integer]: fun()}
local state = {}

---@param bufnr? integer
function M.attach(bufnr)
  bufnr = bufnr or ni.get_current_buf()

  local aug = augroups.BufAugroup(bufnr, "denghua", true)
  local xmarks = Xmarks(bufnr)

  ---@type {[string]: nil|integer}
  local xmids = { jump = nil, insert = nil, change = nil }

  do --jump, ''
    local pos = {} ---@type [integer,integer]
    aug:repeats("CursorMoved", {
      callback = function()
        local lnum, col = get_bufmark(bufnr, "'")
        if not (lnum and col) then return xmarks:del(xmids.jump) end
        if pos[1] == lnum and pos[2] == col then return end
        xmids.jump = xmarks:upsert(xmids.jump, lnum, col, "🐰")
      end,
    })
  end

  do --insert, '^
    local pos = {} ---@type [integer,integer]
    aug:repeats("InsertLeave", {
      callback = function()
        local lnum, col = get_bufmark(bufnr, "^")
        if not (lnum and col) then return xmarks:del(xmids.insert) end
        if pos[1] == lnum and pos[2] == col then return end
        xmids.insert = xmarks:upsert(xmids.insert, lnum, col, "🐭")
      end,
    })
  end

  do --change, '.
    local pos = {} ---@type [integer,integer]
    aug:repeats("TextChanged", {
      callback = function()
        local lnum, col = get_bufmark(bufnr, ".")
        if not (lnum and col) then return xmarks:del(xmids.change) end
        if pos[1] == lnum and pos[2] == col then return end
        xmids.change = xmarks:upsert(xmids.change, lnum, col, "🐱")
      end,
    })
  end

  state[bufnr] = function()
    if not ni.buf_is_valid(bufnr) then return end
    aug:unlink()
    for _, xmid in pairs(xmids) do
      xmarks:del(xmid)
    end
  end
end

function M.detach(bufnr)
  bufnr = bufnr or ni.get_current_buf()

  local detach = state[bufnr]
  if detach == nil then return end
  detach()
end

return M
