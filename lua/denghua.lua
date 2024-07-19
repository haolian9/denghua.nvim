local M = {}

local augroups = require("infra.augroups")
local buflines = require("infra.buflines")
local highlighter = require("infra.highlighter")
local jelly = require("infra.jellyfish")("denghua", "debug")
local logging = require("infra.logging")
local ni = require("infra.ni")
local prefer = require("infra.prefer")
local unsafe = require("infra.unsafe")

local log = logging.newlogger("denghua", "debug")

local facts = {}
do
  facts.icons = { jump = "", insert = "", change = "" }
  facts.xmark_ns = ni.create_namespace("denghua.xmarks")

  do
    local group = "Denghua"
    local hi = highlighter(0)
    if vim.go.background == "light" then
      hi(group, { fg = 1 })
    else
      hi(group, { fg = 9 })
    end
    facts.higroup = group
  end
end

local contracts = {}
do
  ---@class denghua.Caps
  ---@field jump boolean
  ---@field insert boolean
  ---@field change boolean

  local function no_caps() return { jump = false, insert = false, change = false } end

  ---@param winid integer
  ---@return denghua.Caps
  function contracts.resolve_caps(winid) --
    local bufnr = ni.win_get_buf(winid)

    local bo = prefer.buf(bufnr)
    if bo.buftype == "terminal" then return no_caps() end
    if bo.buftype == "quickfix" then return no_caps() end
    if bo.buftype == "prompt" then return no_caps() end

    local caps = { jump = true, insert = true, change = true }

    if bo.readonly then
      caps.insert = false
      caps.change = false
    end

    if bo.undolevels == -1 then caps.change = false end

    --todo: more constraints

    return caps
  end
end

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
  ---@class denghua.Xmarks
  ---@field bufnr integer
  local Impl = {}
  Impl.__index = Impl

  ---@param xmid? integer
  function Impl:del(xmid)
    if xmid == nil then return end
    ni.buf_del_extmark(self.bufnr, facts.xmark_ns, xmid)
  end

  ---@param xmid integer
  ---@param lnum integer
  ---@param col integer
  ---@param icon string
  ---@return integer? xmid
  ---@return integer? lnum
  ---@return integer? col
  function Impl:upsert(xmid, lnum, col, icon)
    local opts = { id = xmid, virt_text = { { icon, facts.higroup } }, virt_text_pos = "inline" }

    ---notes:
    ---* 'mark is window-local, not buffer-local
    ---* ^mark and .mark are buffer-local
    ---* marks can be invalid
    ---* if the position of a mark is invalid: if lnum exists, try EOL; if not, do nothing

    do --check
      if lnum > buflines.high(self.bufnr) then return jelly.debug("lnum out of range") end

      local llen = assert(unsafe.linelen(self.bufnr, lnum))
      local high = llen - 1
      if col > high then col = high end
    end

    local new_xmid = ni.buf_set_extmark(self.bufnr, facts.xmark_ns, lnum, col, opts)

    return new_xmid, lnum, col
  end

  ---@param bufnr integer
  ---@return denghua.Xmarks
  function Xmarks(bufnr) return setmetatable({ bufnr = bufnr }, Impl) end
end

local arbiter ---@type infra.Augroup?
local stop_arbiter ---@type fun()|nil
local executor ---@type infra.BufAugroup?
local stop_executor ---@type fun()|nil

local function on_winenter()
  local winid = ni.get_current_win()
  local bufnr = ni.win_get_buf(winid)

  if executor then
    if executor.bufnr == bufnr then return end
    assert(stop_executor)()
  end

  local caps = contracts.resolve_caps(winid)
  if not (caps.jump or caps.insert or caps.change) then return end

  executor = augroups.BufAugroup(bufnr, "denghua", false)
  local xmarks = Xmarks(bufnr)
  ---@type {[string]: nil|integer}
  local xmids = { jump = nil, insert = nil, change = nil }

  stop_executor = function()
    local exec = executor
    executor, stop_executor = nil, nil
    exec:unlink()
    if ni.buf_is_valid(bufnr) then
      for _, xmid in pairs(xmids) do
        xmarks:del(xmid)
      end
    end
  end

  do --the update mechanism
    local function del_from_xmids(key)
      xmarks:del(xmids[key])
      xmids[key] = nil
    end

    ---@param key 'jump'|'insert'|'change'
    ---@param mark "^"|"."|string
    local function markUpdator(key, mark)
      local icon = assert(facts.icons[key])
      local last_lnum, last_col
      return function()
        local lnum, col = get_bufmark(bufnr, mark)
        log.debug("buf#%s mark=%s (%s, %s)", bufnr, mark, lnum, col)
        if not (lnum and col) then return del_from_xmids(key) end
        if lnum == last_lnum and col == last_col then return end

        local xmid, added_lnum, added_col = xmarks:upsert(xmids[key], lnum, col, icon)
        if not (xmid and added_lnum and added_col) then return del_from_xmids(key) end

        xmids[key], last_lnum, last_col = xmid, added_lnum, added_col
      end
    end

    local mark_jump = markUpdator("jump", "'")
    local mark_insert = markUpdator("insert", "^")
    local mark_change = markUpdator("change", ".")

    if caps.jump then executor:repeats("CursorMoved", { callback = mark_jump }) end
    if caps.insert then executor:repeats("InsertLeave", { callback = mark_insert }) end
    if caps.change then --
      executor:repeats("TextChanged", {
        callback = function()
          mark_change()
          if caps.jump then mark_jump() end
          if caps.insert then mark_insert() end
        end,
      })
    end
  end

  do --trigger the first update
    if caps.jump then executor:emit("CursorMoved", {}) end
    if caps.insert then executor:emit("InsertLeave", {}) end
    if caps.change then executor:emit("TextChanged", {}) end
  end
end

function M.activate()
  if arbiter ~= nil then return end
  arbiter = augroups.Augroup("denghua://")

  stop_arbiter = function()
    local arb = arbiter
    arbiter, stop_arbiter = nil, nil
    arb:unlink()
  end

  arbiter:repeats({ "WinEnter", "BufWinEnter" }, {
    ---this vim.schedule is necessary here, due to: https://github.com/neovim/neovim/issues/24843
    callback = vim.schedule_wrap(on_winenter),
  })

  --triger the first run
  arbiter:emit("WinEnter", {})
end

function M.deactivate()
  if stop_arbiter == nil then
    assert(stop_executor == nil)
    return
  end
  stop_arbiter()

  if stop_executor == nil then return end
  stop_executor()
end

return M
