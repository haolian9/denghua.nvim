local augroups = require("infra.augroups")
local itertools = require("infra.itertools")
local ni = require("infra.ni")

local ns = ni.create_namespace("denghua.jump")

local bufnr = ni.get_current_buf()

---@type [integer,integer], integer
local pos, xmid = {}, nil

local aug = augroups.BufAugroup(bufnr, "denghua.jump", true)
aug:repeats("CursorMoved", {
  callback = function()
    local row, col = unpack(ni.buf_get_mark(bufnr, "'"))
    if row == 0 then return end

    local new_pos = { row - 1, col }
    if itertools.equals(pos, new_pos) then return end

    if xmid ~= nil then ni.buf_del_extmark(bufnr, ns, xmid) end
    xmid = ni.buf_set_extmark(bufnr, ns, new_pos[1], new_pos[2], {
      virt_text = { { "🐰" } },
      virt_text_pos = "inline",
    })
    pos = new_pos
  end,
})
