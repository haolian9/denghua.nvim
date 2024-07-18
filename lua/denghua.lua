local M = {}

local augroups = require("infra.augroups")
local highlighter = require("infra.highlighter")
local logging = require("infra.logging")
local ni = require("infra.ni")

local log = logging.newlogger("denghua", "info")

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

  ---@param xmid integer
  ---@param lnum integer
  ---@param col integer
  ---@param emoji string
  ---@return integer xmid
  function Impl:upsert(xmid, lnum, col, emoji)
    local ok1, err1 = pcall(ni.buf_set_extmark, self.bufnr, ns, lnum, col, {
      id = xmid,
      virt_text = { { emoji, "Denghua" } },
      virt_text_pos = "inline",
    })
    if ok1 then return err1 end

    --(n)vim can offer illegal mark pos during undo/redo; if shit happens, try col=-1
    local ok2, err2 = pcall(ni.buf_set_extmark, self.bufnr, ns, lnum, -1, {
      id = xmid,
      virt_text = { { emoji, "Denghua" } },
      virt_text_pos = "inline",
    })
    if ok2 then return err2 end

    log.err("setxmark xm(%s, %s) (%s, %s) err1=%s; err2=%s", xmid, emoji, lnum, col, err1, err2)
    error("unreachable")
  end

  ---@param bufnr integer
  ---@return denghua.Xmarks
  function Xmarks(bufnr) return setmetatable({ bufnr = bufnr }, Impl) end
end

local arbiter ---@type infra.Augroup?
local stop_arbiter ---@type fun()|nil
local executor ---@type infra.BufAugroup?
local stop_executor ---@type fun()|nil

function M.attach()
  if arbiter ~= nil then return end
  arbiter = augroups.Augroup("denghua://")

  stop_arbiter = function()
    local arb
    arb, arbiter, stop_arbiter = arbiter, nil, nil
    arb:unlink()
  end

  arbiter:repeats({ "WinEnter", "BufWinEnter" }, {
    callback = function()
      local winid = ni.get_current_win()
      local bufnr = ni.win_get_buf(winid)

      if executor then
        if executor.bufnr == bufnr then return end
        assert(stop_executor)()
      end

      executor = augroups.BufAugroup(bufnr, "denghua", false)
      local xmarks = Xmarks(bufnr)
      ---@type {[string]: nil|integer}
      local xmids = { jump = nil, insert = nil, change = nil }

      do
        ---@param key 'jump'|'insert'|'change'
        ---@param mark "^"|"."|string
        local function oncall(key, mark, emoji)
          return function()
            local lnum, col = get_bufmark(bufnr, mark)
            log.debug("buf#%s mark=%s (%s, %s)", bufnr, mark, lnum, col)
            if not (lnum and col) then
              xmarks:del(xmids[key])
              xmids[key] = nil
            else
              --should always update in realtime
              xmids[key] = xmarks:upsert(xmids[key], lnum, col, emoji)
            end
          end
        end
        local mark_jump = oncall("jump", "'", "")
        local mark_insert = oncall("insert", "^", "")
        local mark_change = oncall("change", ".", "")
        executor:repeats("CursorMoved", { callback = mark_jump })
        executor:repeats("InsertLeave", { callback = mark_insert })
        executor:repeats("TextChanged", {
          callback = function()
            mark_change()
            mark_jump()
            mark_insert()
          end,
        })
      end

      do
        executor:emit("CursorMoved", {})
        executor:emit("InsertLeave", {})
        executor:emit("TextChanged", {})
      end

      stop_executor = function()
        local exec
        exec, executor, stop_executor = executor, nil, nil
        exec:unlink()
        if ni.buf_is_valid(bufnr) then
          for _, xmid in pairs(xmids) do
            xmarks:del(xmid)
          end
        end
      end
    end,
  })

  arbiter:emit("WinEnter", {})

  do
    assert(executor)
    executor:emit("CursorMoved", {})
    executor:emit("InsertLeave", {})
    executor:emit("TextChanged", {})
  end
end

function M.detach()
  if stop_arbiter == nil then
    assert(stop_executor == nil)
    return
  end
  stop_arbiter()

  if stop_executor == nil then return end
  stop_executor()
end

return M
