-- Super + Shift + arrows: the active window trades places with its
-- neighbour that way. Only the two involved move.

local W = require("windowing.core")
local frame, place, find_window, windows_on, overlap, is_dialog = W.frame, W.place, W.find_window, W.windows_on, W.overlap, W.is_dialog

-- Two windows trade places: each takes the other's frame. If the last
-- arrangement of the workspace is still undoable, it follows the trade.
local function trade(w, fw, o, fo)
  place(w, fo.x, fo.y, fo.w, fo.h, "swap")
  place(o, fw.x, fw.y, fw.w, fw.h, "swap")
  local st = w.workspace and W.arranged[w.workspace.id]
  if st and st.placed[w.address] and st.placed[o.address] then
    st.placed[w.address], st.placed[o.address] = fo, fw
  end
end

-- The neighbour that way among the windows of the screen (Omarchy's own swap
-- only works on tiled windows). One in the same row (or column) comes first,
-- then the nearest.
local function swap_toward(dir, w)
  w = w or hl.get_active_window()
  if not w or not w.floating or w.fullscreen ~= 0 or not w.workspace or not w.monitor then return end
  local f = frame(w)
  local cx, cy = f.x + f.w / 2, f.y + f.h / 2
  local across = dir == "l" or dir == "r"
  local best, best_d = nil, math.huge
  local all = windows_on(w.workspace.id, w.address, w.monitor.name)
  for i = 1, #all do
    local o = all[i]
    if not is_dialog(o) then
      local q = frame(o)
      local dx, dy = q.x + q.w / 2 - cx, q.y + q.h / 2 - cy
      local ahead = (dir == "l" and dx < -1) or (dir == "r" and dx > 1) or (dir == "u" and dy < -1) or (dir == "d" and dy > 1)
      if ahead then
        local lined = across and overlap(q.y, q.y + q.h, f.y, f.y + f.h) > 0 or (not across and overlap(q.x, q.x + q.w, f.x, f.x + f.w) > 0)
        local d = (across and math.abs(dx) or math.abs(dy)) + 2 * (across and math.abs(dy) or math.abs(dx)) + (lined and 0 or 100000)
        if d < best_d then best, best_d = o, d end
      end
    end
  end
  if best then trade(w, f, best, frame(best)) end
end
local SWAP_KEYS = { { "l", "LEFT" }, { "r", "RIGHT" }, { "u", "UP" }, { "d", "DOWN" } }
for i = 1, W.settings.KEYS.swap and #SWAP_KEYS or 0 do
  local dir, key = SWAP_KEYS[i][1], SWAP_KEYS[i][2]
  hl.unbind("SUPER + SHIFT + " .. key)
  hl.bind("SUPER + SHIFT + " .. key, function() swap_toward(dir) end, { description = "Swap places with the window " .. ({ l = "to the left", r = "to the right", u = "above", d = "below" })[dir] })
end

-- Tests: hyprctl eval 'windowing_swap_test("0x...", "r")' swaps that window
-- like Super + Shift + Right would.
function windowing_swap_test(address, dir) swap_toward(dir, find_window(address)) end
