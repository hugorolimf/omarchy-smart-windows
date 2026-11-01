-- Minimize and bring back, the dock's calls (raise, present, refit) and the
-- close / minimize keys. A window comes back exactly as it left, in the same
-- place and size and on top of the others; nothing else moves, ever.

local W = require("windowing.core")
local GAP = W.GAP
local frame, place, sel, work_area, monitor_size = W.frame, W.place, W.sel, W.work_area, W.monitor_size
local find_window = W.find_window
local maxed, minimized = W.maxed, W.minimized

-- Title bar buttons (titlebars.lua) call these via hyprctl eval.
function windowing_close()
  hl.dispatch(hl.dsp.window.close())
end

-- Minimize (like Windows/macOS): the window goes to a hidden workspace and
-- comes back from its icon in the dock. The minimize key (settings.lua) does it for the active one.
-- It slides down into the dock before it hides, and slides back up to the
-- very same spot when it comes back (see window.move_to_workspace below).
-- The other windows are left alone: no hole is filled, no layout redone.
local MINIMIZE_MS = W.settings.MINIMIZE_MS

-- Kept on disk too: a config reload wipes this file's state, and a window
-- minimized before it would otherwise come back at its shrunken size. One
-- line per window: address x y w h 0 workspace (x, y from the work area's
-- corner; the 0 is a column older versions used, kept for the dock and the
-- session saver that read this file).
local MINIMIZED_FILE = W.STATE .. "/windowing-minimized"
function W.save_minimized()
  local f = io.open(MINIMIZED_FILE, "w")
  if not f then return end
  for a, r in pairs(minimized) do
    f:write(string.format("%s %d %d %d %d 0 %d\n", a, math.floor(r.x), math.floor(r.y), math.floor(r.w), math.floor(r.h), r.ws or 0))
  end
  f:close()
end
do
  local f = io.open(MINIMIZED_FILE, "r")
  if f then
    for line in f:lines() do
      local a, x, y, w, h, _, ws = line:match("^(%S+) (%-?%d+) (%-?%d+) (%d+) (%d+) (%d) ?(%-?%d*)$")
      if a then minimized[a] = { x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h), ws = tonumber(ws) } end
    end
    f:close()
  end
end

-- Like Windows when the window in use goes away: the one used before it on
-- that workspace takes the focus and the front. Without this nothing has
-- focus, and typing goes nowhere until the next click.
local function hand_focus_over(address, wsid)
  local best, best_h = nil, math.huge
  local all = hl.get_windows() or {}
  for i = 1, #all do
    local o = all[i]
    if o.address ~= address and o.mapped and not o.hidden and o.workspace and o.workspace.id == wsid then
      local h = o.focus_history_id
      if h and h >= 0 and h < best_h then best, best_h = o, h end
    end
  end
  if best then windowing_raise(best.address) end
end

function windowing_minimize(address)
  local w = find_window(address)
  if not w or not w.workspace or w.workspace.id < 0 or (minimized[address] and minimized[address].pending) then return end
  local was_active = (hl.get_active_window() or {}).address == address
  local wsid = w.workspace.id
  local f, m = frame(w), w.monitor
  local ax, ay = work_area(m)
  local _, mh = monitor_size(m)
  minimized[address] = { x = f.x - ax, y = f.y - ay, w = f.w, h = f.h, pending = true, ws = w.workspace.id }
  -- Straight down into the dock: same column, same size (apps with a
  -- minimum size can't shrink, and pulling them sideways looked broken).
  if w.fullscreen == 0 and w.floating then
    hl.dispatch(hl.dsp.window.move({ x = math.floor(w.at.x), y = math.floor(m.y + mh), window = sel(w) }))
  end
  W.save_minimized()
  hl.timer(function()
    if minimized[address] then minimized[address].pending = nil end
    -- Hyprland pulls a window back on screen when it changes workspace; with
    -- animations on, that showed as a jump up just before it vanished.
    hl.dispatch(hl.dsp.window.set_prop({ prop = "no_anim", value = "1", window = "address:" .. address }))
    hl.dispatch(hl.dsp.window.move({ workspace = "special:minimized", window = "address:" .. address, follow = false }))
    -- once it is gone, not while it still slides down over the others
    if was_active then hand_focus_over(address, wsid) end
  end, { timeout = MINIMIZE_MS, type = "oneshot" })
end

-- A minimized window still belongs to the workspace it left (the dock shows
-- it in that workspace's tile, Alt+Tab says which): bringing it back puts it
-- there, and the screen goes to it. Without a record (minimized before this
-- was kept), it comes to the workspace on screen.
function windowing_minimized_ws(address)
  local r = minimized[address]
  return r and r.ws or nil
end

function windowing_restore(address)
  local w = find_window(address)
  if not w then return end
  local ws = windowing_minimized_ws(address)
  if not ws then
    local m = hl.get_monitor_at_cursor() or w.monitor
    ws = m and m.active_workspace and m.active_workspace.id or 1
  end
  hl.dispatch(hl.dsp.window.move({ workspace = tostring(ws), window = sel(w), follow = false }))
  hl.timer(function() windowing_raise(address) end, { timeout = 60, type = "oneshot" })
end

function windowing_minimize_active()
  local w = hl.get_active_window()
  if w then windowing_minimize(w.address) end
end

-- The keys in settings.lua. Quit closes the window, and the app too when that
-- was its last window (windowing_close_app below).
local KEYS = W.settings.KEYS
if KEYS.minimize then
  hl.unbind(KEYS.minimize)
  hl.bind(KEYS.minimize, windowing_minimize_active, { description = "Minimize window (restore from the dock)" })
end
if KEYS.quit then
  hl.unbind(KEYS.quit)
  hl.bind(KEYS.quit, function() windowing_close_app() end, { description = "Close window (and the app, if it was its last)" })
end
if KEYS.maximize then
  hl.unbind(KEYS.maximize)
  hl.bind(KEYS.maximize, function() windowing_maximize() end, { description = "Maximize or restore the window" })
end

-- Coming back from special:minimized (the dock, Alt + Tab): it goes back to
-- the frame it left, on whichever screen it returns to, and nothing else
-- changes. A window sent to another workspace keeps its place and size; only
-- one that ends up out of its screen's free area is brought inside.
hl.on("window.move_to_workspace", function(w, ws)
  if not w or not ws or tostring(ws.name):find("^special") then return end
  local r = minimized[w.address]
  if r and r.pending then return end
  local mon = ws.monitor or w.monitor
  if not mon then return end
  local ax, ay, aw, ah = work_area(mon)
  local address = w.address
  if r then
    minimized[address] = nil
    W.save_minimized()
    -- After Hyprland has placed it on the new workspace: put it below the
    -- screen at once (animations still off from minimizing), then let it
    -- slide up out of the dock to where it was.
    local mw, mh = monitor_size(mon)
    local x, y, width, height = ax + r.x, ay + r.y, r.w, r.h
    -- A record that points off the screen it returns to (the window sat across the border, or on the
    -- other screen's side) would bring it back out of sight: then it comes back inside that screen.
    local cx, cy = x + width / 2, y + height / 2
    if cx < mon.x or cx >= mon.x + mw or cy < mon.y or cy >= mon.y + mh then
      width, height = math.min(width, aw - GAP * 2), math.min(height, ah - GAP * 2)
      x = math.min(math.max(x, ax + GAP), ax + aw - GAP - width)
      y = math.min(math.max(y, ay + GAP), ay + ah - GAP - height)
    end
    hl.timer(function()
      hl.dispatch(hl.dsp.window.move({ x = math.floor(x), y = math.floor(mon.y + mh), window = sel(w) }))
      hl.dispatch(hl.dsp.window.set_prop({ prop = "no_anim", value = "0", window = sel(w) }))
      hl.timer(function() place(w, x, y, width, height, "unminimize") end, { timeout = 20, type = "oneshot" })
      hl.timer(function() pcall(W.keep_inside, address) end, { timeout = 400, type = "oneshot" })
    end, { timeout = 30, type = "oneshot" })
  elseif w.floating and w.fullscreen == 0 and (w.size.x < 200 or w.size.y < 140) then
    -- shrunk by a minimize whose record was lost: a sensible size, centred
    hl.dispatch(hl.dsp.window.set_prop({ prop = "no_anim", value = "0", window = sel(w) }))
    place(w, ax + aw * 0.2, ay + ah * 0.15, aw * 0.6, ah * 0.7, "unminimize")
  else
    hl.timer(function() pcall(W.keep_inside, address) end, { timeout = 80, type = "oneshot" })
  end
end)

-- A maximized window minimized, restored or sent to another workspace: the
-- dock of the screen it left (or reached) must know.
hl.on("window.move_to_workspace", function(w)
  if w and maxed[w.address] then
    hl.timer(function() W.publish_maxed() end, { timeout = 50, type = "oneshot" })
  end
end)

-- The dock of a monitor started or stopped hiding, or its line moved:
-- maximized windows there take the new free area (full height, or stopping
-- above the dock again), the others stay above the line.
function windowing_refit(monitor)
  for a in pairs(maxed) do
    local w = find_window(a)
    if w and w.monitor and w.monitor.name == monitor and w.fullscreen == 0 and w.workspace and w.workspace.id > 0 then
      local ax, ay, aw, ah = work_area(w.monitor, true)
      place(w, ax + GAP, ay + GAP, aw - GAP * 2, ah - GAP * 2, "refit")
    end
  end
  local all = hl.get_windows() or {}
  for i = 1, #all do
    local w = all[i]
    if not maxed[w.address] and w.monitor and w.monitor.name == monitor and w.workspace
      and w.monitor.active_workspace and w.workspace.id == w.monitor.active_workspace.id then
      W.keep_inside(w.address)
    end
  end
end

-- Focus a window and put it above all the others (every window floats, so
-- focus alone can leave it behind). The dock calls this when it opens,
-- switches to or restores an app.
function windowing_raise(address)
  local target = "address:" .. address
  hl.dispatch(hl.dsp.focus({ window = target }))
  hl.dispatch(hl.dsp.window.alter_zorder({ mode = "top", window = target }))
end

local PRESENT_RISE, PRESENT_STEPS, PRESENT_TICK = 30, 7, 18

-- Bring a window forward so you see it arrive (a notification's ABRIR, the
-- bell's history): on another workspace Hyprland slides there first; then the
-- window is put a little lower without animation and glides up into place.
-- Minimized ones come back through the usual restore (out of the dock).
function windowing_present(address)
  local w = find_window(address)
  if not w then return end
  if w.workspace and tostring(w.workspace.name):find("^special:minimized") then
    windowing_restore(address)
    return
  end
  windowing_raise(address)
  if not w.floating or w.fullscreen ~= 0 then return end
  -- our own glide (Hyprland's move animation is too quick to notice):
  -- PRESENT_STEPS moves without animation, easing out (cubic)
  local x, y = math.floor(w.at.x), math.floor(w.at.y)
  local step = 0
  hl.dispatch(hl.dsp.window.set_prop({ prop = "no_anim", value = "1", window = sel(w) }))
  hl.dispatch(hl.dsp.window.move({ x = x, y = y + PRESENT_RISE, window = sel(w) }))
  local function tick()
    step = step + 1
    local t = step / PRESENT_STEPS
    local e = 1 - (1 - t) ^ 3
    hl.dispatch(hl.dsp.window.move({ x = x, y = math.floor(y + PRESENT_RISE * (1 - e) + 0.5), window = sel(w) }))
    if step < PRESENT_STEPS then
      hl.timer(tick, { timeout = PRESENT_TICK, type = "oneshot" })
    else
      hl.dispatch(hl.dsp.window.set_prop({ prop = "no_anim", value = "0", window = sel(w) }))
    end
  end
  hl.timer(tick, { timeout = 16, type = "oneshot" })
end

-- Quits an app (the dock's Quit): every window of the class, by killing
-- its processes. Web apps (chrome-*) share one Chromium process with every
-- other web app, so for them only that app's windows close. Without a
-- class: the active window's app, a terminal only closing that window.
local TERMINALS = { foot = true, Alacritty = true, kitty = true, ["com.mitchellh.ghostty"] = true }
function windowing_quit(class)
  if not class then
    local w = hl.get_active_window()
    if w and TERMINALS[w.class] then
      hl.dispatch(hl.dsp.window.close({ window = "address:" .. w.address }))
      return
    end
    class = w and w.class
  end
  if not class or class == "" then return end
  local all, pids = hl.get_windows() or {}, {}
  for i = 1, #all do
    local w = all[i]
    if w.class == class then
      if class:find("^chrome%-") then
        hl.dispatch(hl.dsp.window.close({ window = "address:" .. w.address }))
      elseif w.pid and w.pid > 0 then
        pids[w.pid] = true
      end
    end
  end
  for pid in pairs(pids) do hl.exec_cmd("kill -TERM " .. pid) end
end

-- Closes the active window; when it was its app's last one and the app is
-- still running a moment later (Spotify, Discord and the like hide in the
-- background instead of quitting), the app ends too. Other windows of the
-- app stay open. Web apps share the browser's process: only the window.
function windowing_close_app()
  local w = hl.get_active_window()
  if not w then return end
  local class, pid = w.class, w.pid
  hl.dispatch(hl.dsp.window.close({ window = "address:" .. w.address }))
  if TERMINALS[class] or not pid or pid <= 0 or tostring(class):find("^chrome%-") then return end
  hl.timer(function()
    local all = hl.get_windows() or {}
    for i = 1, #all do
      if all[i].class == class or all[i].pid == pid then return end
    end
    hl.exec_cmd("kill -TERM " .. pid)
  end, { timeout = 1500, type = "oneshot" })
end
