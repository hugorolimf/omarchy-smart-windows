-- Maximize, and dragging: let go near a screen edge to snap (Aero Snap).
-- Moving or resizing a window never moves the others: dropped on top of
-- another window, it stays on top, where it was let go.

local W = require("windowing.core")
local KEYS = W.settings.KEYS
local GAP, TOUCH, ZONE, SHARED, CORNER = W.GAP, W.TOUCH, W.ZONE, W.SHARED, W.CORNER
local frame, place, place_raw, bar, work_area, monitor_size = W.frame, W.place, W.place_raw, W.bar, W.work_area, W.monitor_size
local find_window, windows_on, overlap, same_frame = W.find_window, W.windows_on, W.overlap, W.same_frame
local remember, forget, set_maxed, sel = W.remember, W.forget, W.set_maxed, W.sel
local restore, saved, maxed = W.restore, W.saved, W.maxed

-- Maximize fills the free part of the monitor (bar and dock stay visible);
-- doing it again puts the window back where it was. Without an address it
-- acts on the active window (our buttons); apps' own maximize buttons pass
-- theirs (hyprbars plugin).
function windowing_maximize(address)
  local w = address and find_window(address) or hl.get_active_window()
  if not w or not w.floating or w.fullscreen ~= 0 then return end
  local ax, ay, aw, ah = work_area(w.monitor, true)
  local f, s = frame(w), saved[w.address]
  if same_frame(f, { x = ax + GAP, y = ay + GAP, w = aw - GAP * 2, h = ah - GAP * 2 }) then
    -- the size it had before; without a record, 70% of the screen in the middle
    s = s or { x = ax + aw * 0.15, y = ay + ah * 0.15, w = aw * 0.7, h = ah * 0.7 }
    forget(w.address)
    place(w, s.x, s.y, s.w, s.h, "unmaximize")
  else
    saved[w.address] = f
    remember(w, f)
    set_maxed(w)
    place(w, ax + GAP, ay + GAP, aw - GAP * 2, ah - GAP * 2, "maximize")
  end
end

-- Horizontal span for a window snapped to one side between rows y..y+h:
-- half the screen, or whatever the windows already snapped on the other
-- side leave free (so a 60% window gets a 40% neighbour, not an overlap).
local function side_span(m, w, left, y, h)
  local ax, _, aw = work_area(m)
  local half = (aw - GAP * 3) / 2
  local x0, x1 = ax + GAP, ax + aw - GAP
  local edge = nil
  local list = windows_on(m.active_workspace and m.active_workspace.id or -1, w.address, m.name)
  for i = 1, #list do
    local q = frame(list[i])
    if overlap(q.y, q.y + q.h, y, y + h) > h * 0.5 then
      if left and math.abs(q.x + q.w - x1) <= TOUCH then
        edge = math.min(edge or q.x, q.x)
      elseif not left and math.abs(q.x - x0) <= TOUCH then
        edge = math.max(edge or (q.x + q.w), q.x + q.w)
      end
    end
  end
  local width = edge and (left and edge - GAP - x0 or x1 - edge - GAP) or half
  if width < aw * 0.2 or width > aw * 0.8 then width = half end
  return left and x0 or x1 - width, width
end

-- Snap zone width on each border of m: wide on a real screen edge, thin
-- where another monitor continues, so dragging a window across to the other
-- screen doesn't snap it the moment it crosses.
local function zones(m)
  local mw, mh = monitor_size(m)
  local z = { left = ZONE, right = ZONE, top = ZONE, bottom = ZONE }
  local ms = hl.get_monitors() or {}
  for i = 1, #ms do
    local o = ms[i]
    if o.name ~= m.name then
      local ow, oh = monitor_size(o)
      local vert = overlap(o.y, o.y + oh, m.y, m.y + mh) > 0
      local horz = overlap(o.x, o.x + ow, m.x, m.x + mw) > 0
      if vert and math.abs(o.x + ow - m.x) <= 2 then z.left = SHARED end
      if vert and math.abs(m.x + mw - o.x) <= 2 then z.right = SHARED end
      if horz and math.abs(o.y + oh - m.y) <= 2 then z.top = SHARED end
      if horz and math.abs(m.y + mh - o.y) <= 2 then z.bottom = SHARED end
    end
  end
  return z
end

-- Only the dragged window snaps; the others stay where they are.
local function snap(w, p)
  local c = hl.get_cursor_pos()
  local m = hl.get_monitor_at_cursor()
  if not c or not m then return end
  local mw, mh = monitor_size(m)
  local ax, ay, _, ah = work_area(m)
  local z = zones(m)
  local left, right = c.x <= m.x + z.left, c.x >= m.x + mw - z.right
  local top, bottom = c.y <= m.y + z.top, c.y >= m.y + mh - z.bottom
  local near_top, near_bottom = c.y <= m.y + mh * CORNER, c.y >= m.y + mh * (1 - CORNER)
  local near_left, near_right = c.x <= m.x + mw * CORNER * 0.6, c.x >= m.x + mw * (1 - CORNER * 0.6)
  local qh = (ah - GAP * 3) / 2

  local side, row = nil, nil   -- which side, and full / top / bottom row
  if (left or right) then side = left and "left" or "right" end
  if (top or bottom) and (near_left or near_right) then side = near_left and "left" or "right" end
  if side then
    if (top or ((left or right) and near_top)) then row = "top"
    elseif (bottom or ((left or right) and near_bottom)) then row = "bottom"
    elseif left or right then row = "full" end
  end

  if side and row then
    remember(w, p.frame)
    local y = row == "bottom" and ay + GAP * 2 + qh or ay + GAP
    local h = row == "full" and ah - GAP * 2 or qh
    local x, width = side_span(m, w, side == "left", y, h)
    place(w, x, y, width, h, "snap-" .. side .. "-" .. row)
  elseif top and not bottom then
    remember(w, p.frame)
    set_maxed(w)
    local mx, my, mw2, mh2 = work_area(m, true)
    place(w, mx + GAP, my + GAP, mw2 - GAP * 2, mh2 - GAP * 2, "snap-top")
  elseif restore[w.address] then
    -- Back to its old size, keeping the spot it was grabbed by under the
    -- pointer (Super + drag grabs anywhere, not just a title bar).
    local r = restore[w.address]
    local fx = math.min(math.max((c.x - w.at.x) / math.max(w.size.x, 1), 0), 1)
    local fy = math.min(math.max((c.y - w.at.y) / math.max(w.size.y, 1), 0), 1)
    forget(w.address)
    W.log("unsnap", w, c.x - fx * r.w, c.y - fy * r.h, r.w, r.h)
    place_raw(w, c.x - fx * r.w, c.y - fy * r.h, r.w, r.h)
  end
end

-- The window under the pointer. Focus only follows clicks (input.lua), so
-- the active window isn't necessarily the one being dragged: take the active
-- one if the pointer is on it, else the most recently used one under it.
local function window_at_cursor()
  local c, m = hl.get_cursor_pos(), hl.get_monitor_at_cursor()
  if not c or not m then return nil end
  local function under(w)
    return w and c.x >= w.at.x and c.x < w.at.x + w.size.x and c.y >= w.at.y - bar() and c.y < w.at.y + w.size.y
  end
  local active = hl.get_active_window()
  if under(active) then return active end
  if not m.active_workspace then return nil end
  local best = nil
  local list = windows_on(m.active_workspace.id, nil, m.name)
  for i = 1, #list do
    local o = list[i]
    if under(o) and (not best or (o.focus_history_id or 99) < (best.focus_history_id or 99)) then best = o end
  end
  return best
end

-- A window that opens over a fullscreen one stays above it (Hyprland marks it
-- allowed_over_fullscreen) and clicking the fullscreen window doesn't take it
-- down. A click on the fullscreen window (not on one above it) sends every
-- other window of the workspace behind it, top first so they keep their order;
-- going to the bottom clears the mark. The dock or Alt + Tab bring them back.
-- Tests: hyprctl eval 'windowing_bury_test(8)' buries over workspace 8's
-- fullscreen window without looking at the cursor.
local function bury_over_fullscreen(wsid, c)
  local all, full, others, over = hl.get_windows() or {}, nil, {}, false
  for i = 1, #all do
    local o = all[i]
    if o.mapped and not o.hidden and o.workspace and o.workspace.id == wsid then
      if o.fullscreen ~= 0 then
        full = o
      elseif o.allowed_over_fullscreen and c and c.x >= o.at.x and c.x < o.at.x + o.size.x
        and c.y >= o.at.y - bar() and c.y < o.at.y + o.size.y then
        return  -- the click is on a window above the fullscreen one
      elseif not o.pinned then
        others[#others + 1] = o
        over = over or o.allowed_over_fullscreen
      end
    end
  end
  if not full or not over then return end
  for i = #others, 1, -1 do
    hl.dispatch(hl.dsp.window.alter_zorder({ mode = "bottom", window = sel(others[i]) }))
  end
end
windowing_bury_test = function(wsid) bury_over_fullscreen(wsid, nil) end

-- Button down: remember the window and where it was, to tell a drag or a
-- resize from a click.
-- Super + right click without dragging (Super + right drag still resizes)
-- arranges the screen like Super + A, on a window or on the bare desktop.
local pressed = nil   -- active floating window when a button went down
local super_right = false

local function on_press(button)
  super_right = button == "mouse:273" and (hl.is_key_down("Super_L") or hl.is_key_down("Super_R"))
  local m = hl.get_monitor_at_cursor()
  if not super_right and m and m.active_workspace then
    bury_over_fullscreen(m.active_workspace.id, hl.get_cursor_pos())
  end
  local w = window_at_cursor()
  if w and w.floating then
    pressed = { address = w.address, x = w.at.x, y = w.at.y, w = w.size.x, h = w.size.y, frame = frame(w) }
    -- dragged onto a workspace tile of the dock, it goes there (dockdrop.lua)
    if button == "mouse:272" and w.fullscreen == 0 then W.drop_press(pressed) end
  else
    pressed = nil
  end
end

-- The monitor a frame's centre is on (a window dragged across to the other
-- screen belongs to the one it mostly sits on).
local function monitor_of(f)
  local cx, cy = f.x + f.w / 2, f.y + f.h / 2
  local ms = hl.get_monitors() or {}
  for i = 1, #ms do
    local m = ms[i]
    local mw, mh = monitor_size(m)
    if cx >= m.x and cx < m.x + mw and cy >= m.y and cy < m.y + mh then return m end
  end
end

-- A window let go touching or past a screen edge comes back inside, GAP
-- from the edges like a snapped one; one bigger than the screen shrinks to
-- fit. Snapped windows are already inside, so this leaves them alone.
function W.keep_inside(address)
  local w = find_window(address)
  if not w or maxed[address] or not w.floating or w.fullscreen ~= 0 or not w.workspace or w.workspace.id < 0 then return end
  local f = frame(w)
  local m = monitor_of(f) or w.monitor
  if not m then return end
  local ax, ay, aw, ah = work_area(m)
  local width, height = math.min(f.w, aw - GAP * 2), math.min(f.h, ah - GAP * 2)
  local g = {
    x = math.min(math.max(f.x, ax + GAP), ax + aw - GAP - width),
    y = math.min(math.max(f.y, ay + GAP), ay + ah - GAP - height),
    w = width, h = height,
  }
  if not same_frame(f, g) then place(w, g.x, g.y, g.w, g.h, "fit-screen") end
end

-- Tests: hyprctl eval 'windowing_snap_test("0x...")' snaps by where the cursor is now.
windowing_snap_test = function(address) local w = find_window(address) if w then snap(w, { frame = frame(w) }) end end
windowing_fit = W.keep_inside  -- also callable: hyprctl eval 'windowing_fit("0x...")'

-- Button up: a move snaps by where the pointer is; a resize only changes
-- that window.
local function on_release()
  local p, click = pressed, super_right
  pressed, super_right = nil, false
  if W.drop_release() then return end
  if not p then
    if click and KEYS.arrange_click then windowing_arrange() end
    return
  end
  local w = find_window(p.address)
  if not w or w.address ~= p.address or not w.floating or w.fullscreen ~= 0 then return end
  local moved = w.at.x ~= p.x or w.at.y ~= p.y
  local resized = w.size.x ~= p.w or w.size.y ~= p.h
  if click and not moved and not resized then
    if KEYS.arrange_click then windowing_arrange() end
    return
  end
  if resized then
    saved[w.address] = nil
    if maxed[w.address] then maxed[w.address] = nil W.publish_maxed() end
  elseif moved then
    snap(w, p)
  end
  if moved or resized then
    -- once the moves above have landed
    hl.timer(function() W.keep_inside(p.address) end, { timeout = 40, type = "oneshot" })
  end
end

for _, button in ipairs({ "mouse:272", "mouse:273" }) do
  hl.bind(button, function() on_press(button) end, { non_consuming = true, ignore_mods = true, description = "Window snap: track drag" })
  hl.bind(button, on_release, { non_consuming = true, release = true, ignore_mods = true, description = "Window snap: snap on release" })
end
