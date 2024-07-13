local augroups = require("infra.augroups")
local feedkeys = require("infra.feedkeys")
local itertools = require("infra.itertools")
local jelly = require("infra.jellyfish")("denghua.change", "debug")
local m = require("infra.keymap.global")
local ni = require("infra.ni")

local ns = ni.create_namespace("denghua.change")

local host_bufnr = ni.get_current_buf()

---@type [integer,integer], integer
local dot_pos, dot_xmid = {}, nil
local older_xmid, newer_xmid

---@param bufnr integer
local function set_dot_xmark(bufnr)
  local row, col = unpack(ni.buf_get_mark(bufnr, "."))
  if row == 0 then return end

  local new_pos = { row - 1, col }
  if itertools.equals(dot_pos, new_pos) then return end

  if dot_xmid ~= nil then ni.buf_del_extmark(bufnr, ns, dot_xmid) end
  dot_xmid = ni.buf_set_extmark(bufnr, ns, new_pos[1], new_pos[2], {
    virt_text = { { "🔴" } },
    virt_text_pos = "inline",
  })
  dot_pos = new_pos
end

---@param bufnr integer
local function set_older_xmark(bufnr)
  ---@diagnostic disable-next-line: redundant-parameter
  local changes = vim.fn.getchangelist(bufnr, -1)[1]
  if #changes == 0 then return jelly.debug("no more older changes") end
  assert(#changes == 1)
  local lnum, col = changes[1].lnum, changes[1].col
  lnum = lnum - 1
  if older_xmid ~= nil then ni.buf_del_extmark(bufnr, ns, older_xmid) end
  older_xmid = ni.buf_set_extmark(bufnr, ns, lnum, col, {
    virt_text = { { "🅰️" } },
    virt_text_pos = "inline",
  })
end
---@param bufnr integer
local function set_newer_xmark(bufnr)
  ---@diagnostic disable-next-line: redundant-parameter
  local changes = vim.fn.getchangelist(bufnr, 1)[1]
  if #changes == 0 then return jelly.debug("no more newer changes") end
  assert(#changes == 1)
  local lnum, col = changes[1].lnum, changes[1].col
  lnum = lnum - 1
  if newer_xmid ~= nil then ni.buf_del_extmark(bufnr, ns, newer_xmid) end
  newer_xmid = ni.buf_set_extmark(bufnr, ns, lnum, col, {
    virt_text = { { "🅱️" } },
    virt_text_pos = "inline",
  })
end

local aug = augroups.BufAugroup(host_bufnr, "denghua.change", true)
aug:repeats("TextChanged", {
  callback = function()
    set_dot_xmark(host_bufnr)
    set_older_xmark(host_bufnr)
    set_newer_xmark(host_bufnr)
  end,
})

do
  m.n("g;", function()
    feedkeys("g;", "n")
    vim.schedule(function()
      set_older_xmark(host_bufnr)
      set_newer_xmark(host_bufnr)
    end)
  end)
  m.n("g,", function()
    feedkeys("g,", "n")
    vim.schedule(function()
      set_newer_xmark(host_bufnr)
      set_older_xmark(host_bufnr)
    end)
  end)
end

