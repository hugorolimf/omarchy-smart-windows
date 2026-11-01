-- Where windows land. Each app reopens where and how big it was when it was
-- closed (scaled to the screen it opens on), and a second window of an app
-- that would sit exactly on top of the first steps down and right, the way
-- Windows cascades them. Nothing else moves: no hunt for free room, no layout
-- to join, no neighbours to push.

local W = require("windowing.core")
local GAP, MIN_W, MIN_H = W.GAP, W.MIN_W, W.MIN_H
local frame, place, work_area, windows_on, is_dialog, same_frame = W.frame, W.place, W.work_area, W.windows_on, W.is_dialog, W.same_frame
local find_window, minimized = W.find_window, W.minimized

-- Each app's window is remembered when it closes (size and place, relative
-- to the free area of its screen) and reopens the same way. On another
-- screen (laptop vs. monitor) it is scaled to that screen and kept inside
-- it. ~/.local/state/omarchy/windowing-geometry
local GEOMETRY_FILE = W.STATE .. "/windowing-geometry"
local geometry = {}  -- class -> { mon, aw, ah, x, y, w, h } (x, y from the work area's corner)
W.geometry = geometry
do
  local f = io.open(GEOMETRY_FILE, "r")
  if f then
    for line in f:lines() do
      local c, mon, aw, ah, x, y, w, h = line:match("^(.-)\t(%S+) (%d+) (%d+) (%-?%d+) (%-?%d+) (%d+) (%d+)$")
      if c then
        geometry[c] = { mon = mon, aw = tonumber(aw), ah = tonumber(ah), x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h) }
      end
    end
    f:close()
  end
end

local function save_geometry()
  local f = io.open(GEOMETRY_FILE, "w")
  if not f then return end
  for c, g in pairs(geometry) do
    f:write(string.format("%s\t%s %d %d %d %d %d %d\n", c, g.mon, g.aw, g.ah, g.x, g.y, g.w, g.h))
  end
  f:close()
end

-- Other open windows of the same app.
local function siblings(w)
  local out, all = {}, hl.get_windows() or {}
  for i = 1, #all do
    local o = all[i]
    if o.address ~= w.address and o.class == w.class and o.mapped then out[#out + 1] = o end
  end
  return out
end

local function remember_geometry(w)
  if not w.class or w.class == "" or not w.monitor or not w.floating or w.fullscreen ~= 0 or is_dialog(w) then return end
  local ax, ay, aw, ah = work_area(w.monitor)
  local f, r = nil, minimized[w.address]
  if r then
    f = { x = ax + r.x, y = ay + r.y, w = r.w, h = r.h }  -- closed while minimized: where it lived
  elseif w.workspace and w.workspace.id > 0 then
    f = frame(w)
  else
    return
  end
  if f.w < 200 or f.h < 150 then return end
  -- several windows of the app: the biggest one stands for it
  local sib = siblings(w)
  for i = 1, #sib do
    if sib[i].size.x * sib[i].size.y > f.w * f.h then return end
  end
  geometry[w.class] = { mon = w.monitor.name, aw = aw, ah = ah, x = f.x - ax, y = f.y - ay, w = f.w, h = f.h }
  save_geometry()
end

-- The frame an app's window opens in: where its last one was closed, on this
-- screen's free area (ax, ay, aw, ah). nil for an app never seen before.
local function remembered(w, ax, ay, aw, ah)
  local g = w.class and geometry[w.class]
  if not g then return nil end
  local x, y, width, height = g.x, g.y, g.w, g.h
  if g.mon ~= w.monitor.name or math.abs(g.aw - aw) > 2 or math.abs(g.ah - ah) > 2 then
    local sx, sy = aw / g.aw, ah / g.ah   -- another screen: same share of it
    x, y, width, height = x * sx, y * sy, width * sx, height * sy
  end
  width = math.max(math.min(width, aw - GAP * 2), MIN_W)
  height = math.max(math.min(height, ah - GAP * 2), MIN_H)
  x = math.min(math.max(x, GAP), aw - GAP - width)
  y = math.min(math.max(y, GAP), ah - GAP - height)
  return { x = ax + x, y = ay + y, w = width, h = height }
end

-- A window that would sit exactly on another window of its own app (same
-- corner) steps down and right until its corner is free, like Windows
-- cascading them. Different apps are left to overlap: that is the user's
-- call. A window almost as big as the free area has no room to step.
local STEP = 32
local function cascade(w, f, ax, ay, aw, ah)
  if f.w > aw - STEP * 2 and f.h > ah - STEP * 2 then return f end
  local mine = {}
  local all = windows_on(w.workspace.id, w.address, w.monitor.name)
  for i = 1, #all do
    if all[i].class == w.class then mine[#mine + 1] = all[i] end
  end
  for _ = 1, 12 do
    local covered = false
    for i = 1, #mine do
      local q = frame(mine[i])
      if math.abs(q.x - f.x) <= 6 and math.abs(q.y - f.y) <= 6 then covered = true break end
    end
    if not covered then break end
    local nx = math.min(f.x + STEP, ax + aw - GAP - f.w)
    local ny = math.min(f.y + STEP, ay + ah - GAP - f.h)
    if nx == f.x and ny == f.y then nx, ny = ax + GAP, ay + GAP end   -- ran out of room: start over
    f.x, f.y = nx, ny
  end
  return f
end

-- A moment after a window opens (Hyprland has applied its own rules by then):
-- an app seen before goes where it was, and a window that would hide its
-- twin steps aside. Dialogs Omarchy centres (tag floating-window) keep their
-- place.
local function settle(address)
  local w = find_window(address)
  if not w or not w.mapped or not w.floating or w.fullscreen ~= 0 or not w.workspace or w.workspace.id < 0
    or not w.monitor or is_dialog(w) then return end
  local ax, ay, aw, ah = work_area(w.monitor)
  local f = remembered(w, ax, ay, aw, ah)
  local reopened = f ~= nil
  f = cascade(w, f or frame(w), ax, ay, aw, ah)
  if reopened or not same_frame(f, frame(w)) then
    place(w, f.x, f.y, f.w, f.h, reopened and "reopen" or "cascade")
  end
end

hl.on("window.open", function(w)
  if not w or not w.address then return end
  local a = w.address
  hl.timer(function() pcall(settle, a) end, { timeout = 40, type = "oneshot" })
  -- whatever placed it (Hyprland centres new windows on the whole monitor),
  -- it ends up above the dock's line
  hl.timer(function() pcall(W.keep_inside, a) end, { timeout = 120, type = "oneshot" })
end)

hl.on("window.close", function(w)
  if not w or not w.address then return end
  pcall(remember_geometry, w)
  if minimized[w.address] then minimized[w.address] = nil W.save_minimized() end
  W.forget(w.address)
end)
