local M = {}

local augroups = require("infra.augroups")
local buflines = require("infra.buflines")
local ctx = require("infra.ctx")
local dictlib = require("infra.dictlib")
local highlighter = require("infra.highlighter")
local jelly = require("infra.jellyfish")("denghua", "debug")
local logging = require("infra.logging")
local mi = require("infra.mi")
local ni = require("infra.ni")
local prefer = require("infra.prefer")
local strlib = require("infra.strlib")
local unsafe = require("infra.unsafe")
local wincursor = require("infra.wincursor")

local log = logging.newlogger("denghua", "info")

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

  do
    ---@class denghua.Caps
    ---@field jump boolean
    ---@field insert boolean
    ---@field change boolean

    local function no_caps(reason)
      jelly.debug("no caps due to: %s", reason)
      return { jump = false, insert = false, change = false }
    end

    ---@param winid integer
    ---@return denghua.Caps
    function facts.Caps(winid) --
      local bufnr = ni.win_get_buf(winid)

      if mi.win_is_float(winid) then return no_caps("floatwin") end

      local bo = prefer.buf(bufnr)
      if bo.buftype == "terminal" then return no_caps("terminal buf") end
      if bo.buftype == "quickfix" then return no_caps("quickfix buf") end
      if bo.buftype == "prompt" then return no_caps("prompt buf") end

      local bufname = ni.buf_get_name(bufnr)
      if strlib.contains(bufname, "://") then return no_caps("protocol bufname") end

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
end

local localmarks = {}
do
  ---@param bufnr integer
  ---@param mark "^"|"."|string
  ---@return integer? lnum @0-based
  ---@return integer? col @0-based
  local function get_buf_mark(bufnr, mark)
    local row, col = unpack(ni.buf_get_mark(bufnr, mark))
    if row == 0 then return end
    return row - 1, col
  end

  ---@return integer? lnum @0-based
  ---@return integer? col @0-based
  function localmarks.insert(bufnr) return get_buf_mark(bufnr, "^") end

  ---@return integer? lnum @0-based
  ---@return integer? col @0-based
  function localmarks.change(bufnr) return get_buf_mark(bufnr, ".") end

  ---@return integer? lnum @0-based
  ---@return integer? col @0-based
  function localmarks.jump(winid, bufnr)
    --todo: can be removed, per jump_of_curwin_curbuf
    --according to the impl, nvim_buf_get_mark always get this mark based on curwin, curbuf
    return ctx.win(winid, function()
      return ctx.buf(bufnr, function() return get_buf_mark(bufnr, "'") end)
    end)
  end

  ---@return integer? lnum @0-based
  ---@return integer? col @0-based
  function localmarks.jump_of_curwin_curbuf(winid, bufnr)
    do
      local curwin = ni.get_current_win()
      local curbuf = ni.get_current_buf()
      if not (curwin == winid and curbuf == bufnr) then --
        return jelly.fatal("unreachable", "curwin=%s,win=%s; curbuf=%s,buf=%s", curwin, winid, curbuf, bufnr)
      end
    end
    return get_buf_mark(bufnr, "'")
  end
end

local xmarks = {}
do
  ---@param bufnr integer
  ---@param xmid integer
  ---@return {lnum:integer,col:integer}?
  function xmarks.get(bufnr, xmid)
    local xm = ni.buf_get_extmark_by_id(bufnr, facts.xmark_ns, xmid, { details = false })
    if #xm == 0 then return end
    return { lnum = xm[1], col = xm[2] }
  end

  ---@param bufnr integer
  ---@param xmid? integer
  function xmarks.del(bufnr, xmid)
    if xmid == nil then return end
    ni.buf_del_extmark(bufnr, facts.xmark_ns, xmid)
  end

  ---@param bufnr integer
  ---@param xmid integer
  ---@param lnum integer
  ---@param col integer
  ---@param icon string
  ---@return integer? xmid
  ---@return integer? lnum
  ---@return integer? col
  function xmarks.upsert(bufnr, xmid, lnum, col, icon)
    local opts = { id = xmid, virt_text = { { icon, facts.higroup } }, virt_text_pos = "inline" }

    ---notes:
    ---* 'mark is window-local, not buffer-local
    ---* ^mark and .mark are buffer-local
    ---* marks can be invalid
    ---* if the position of a mark is invalid: if lnum exists, try EOL; if not, do nothing

    do --check
      if lnum > buflines.high(bufnr) then return jelly.debug("lnum out of range") end

      local llen = assert(unsafe.linelen(bufnr, lnum))
      local high = llen - 1
      if col > high then col = high end
    end

    local new_xmid = ni.buf_set_extmark(bufnr, facts.xmark_ns, lnum, col, opts)

    return new_xmid, lnum, col
  end
end

local arbiter ---@type infra.Augroup?
local stop_arbiter ---@type fun()|nil
local executor ---@type infra.BufAugroup?
local stop_executor ---@type fun()|nil

---@param winid integer
---@param bufnr integer
local function main(winid, bufnr)
  --todo: only set xmarks in the FOV
  --todo: maybe nvim_set_decoration_provider

  if executor then
    if executor.winid == winid and executor.bufnr == bufnr then return end
    assert(stop_executor)()
  end

  local caps = facts.Caps(winid)
  if not (caps.jump or caps.insert or caps.change) then return end

  executor = augroups.BufAugroup(bufnr, "denghua", false)
  ---@diagnostic disable-next-line: inject-field
  executor.winid = winid
  ---@type {[string]: nil|integer}
  local xmids = { jump = nil, insert = nil, change = nil }

  stop_executor = function()
    local exec = executor
    executor, stop_executor = nil, nil
    exec:unlink()
    if ni.buf_is_valid(bufnr) then
      for _, xmid in pairs(xmids) do
        xmarks.del(bufnr, xmid)
      end
    end
  end

  do --the update mechanism
    local function del_from_xmids(key)
      xmarks.del(bufnr, xmids[key])
      xmids[key] = nil
    end

    ---@param key 'jump'|'insert'|'change'
    ---@param mark_pos fun():(lnum:integer?,col:integer?)
    local function markUpdator(key, mark_pos)
      local icon = assert(facts.icons[key])
      local last_lnum, last_col
      return function()
        local lnum, col = mark_pos()
        log.debug("buf#%s key=%s (%s, %s)", bufnr, key, lnum, col)
        if not (lnum and col) then return del_from_xmids(key) end
        --has been set and still exists
        if (lnum == last_lnum and col == last_col) and xmids[key] ~= nil then return end

        local xmid, added_lnum, added_col = xmarks.upsert(bufnr, xmids[key], lnum, col, icon)
        if not (xmid and added_lnum and added_col) then return del_from_xmids(key) end

        xmids[key], last_lnum, last_col = xmid, added_lnum, added_col
      end
    end

    local mark_jump = markUpdator("jump", function() return localmarks.jump_of_curwin_curbuf(winid, bufnr) end)
    local mark_insert = markUpdator("insert", function() return localmarks.insert(bufnr) end)
    local mark_change = markUpdator("change", function() return localmarks.change(bufnr) end)

    --not having xmarks on cursorline
    executor:repeats("InsertEnter", {
      callback = function()
        local cursorline = wincursor.lnum()
        local keys = dictlib.keys(xmids)
        for _, key in ipairs(keys) do
          local pos = xmarks.get(bufnr, xmids[key])
          if pos and pos.lnum == cursorline then del_from_xmids(key) end
        end
      end,
    })

    if caps.jump then executor:repeats("CursorMoved", { callback = mark_jump }) end

    --due to insertEnter, need to restore xmarks
    executor:repeats("InsertLeave", {
      callback = function()
        local mode = ni.get_mode().mode
        if mode ~= "n" then return jelly.debug("not in normal mode: %s", mode) end
        if caps.jump then mark_jump() end
        if caps.insert then mark_insert() end
        if caps.change then mark_change() end
      end,
    })

    executor:repeats("TextChanged", {
      callback = function()
        if caps.change then mark_change() end
        if caps.jump then mark_jump() end
        if caps.insert then mark_insert() end
      end,
    })
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

  do
    --facts:
    --* winenter is always triggered before bufwinenter
    --* unless open_win(enter=false)
    local last_winenter
    arbiter:repeats("WinEnter", {
      callback = function()
        local winid = ni.get_current_win()
        local bufnr = ni.get_current_buf()
        last_winenter = winid
        main(winid, bufnr)
      end,
    })
    arbiter:repeats("BufWinEnter", {
      callback = function()
        local winid = ni.get_current_win()
        --open_win(enter=false) triggers no winenter, but this only
        if winid == last_winenter then return end
        local bufnr = ni.get_current_buf()
        main(winid, bufnr)
      end,
    })
  end

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
