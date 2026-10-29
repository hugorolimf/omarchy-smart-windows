-- Smart Windows: Windows-style window management for Omarchy (Hyprland Lua).
-- https://github.com/hugorolimf/omarchy-windows · MIT © Hugo Rolim Filho
--
-- Every window floats. Drag a window and let go with the pointer near a
-- screen edge to snap it, like Windows Aero Snap:
--   top edge                 -> fills the screen (maximize)
--   left/right edge          -> left/right side
--   corners (any of the two edges near it) -> quarter
-- Snapping is smart: a side fills what the windows already snapped on the
-- other side leave free, and when only one other window is around it takes
-- the other side. Dragging a snapped window away gives it back its old size.
-- Windows that sit side by side resize together: drag the shared edge of one
-- (Super + right drag) and its neighbours follow. Closing or minimizing one
-- lets its neighbours fill the hole.
-- Super + A arranges every window of the screen by how many there are (and
-- puts them back when pressed again). New windows open in the largest free
-- area instead of on top of the others. Apps reopen at the size and place
-- they had when closed, scaled to the screen they open on.
-- Windows move freely between monitors by dragging them across.
--
-- Loaded by a one-line loader in ~/.local/state/omarchy/toggles/hypr/
-- (Omarchy runs every .lua there on each Hyprland reload). Edit the
-- configuration block below, then run `hyprctl reload`.

-- ===================================================================
-- Configuration
-- ===================================================================

local ZONE = 36       -- px from a monitor border where letting go snaps
local SHARED = 4      -- the same, on a border shared with another monitor
local CORNER = 0.22   -- share of a side, next to a corner, that snaps a quarter
local GAP = 8         -- space between snapped windows and the screen border
local MIN_W, MIN_H = 160, 100  -- smallest size a neighbour is squeezed to
local MINIMIZE_MS = 230        -- length of the slide into the dock on minimize

-- Keybindings. Set one to false to leave that key alone.
-- Super + W (close the window) is Omarchy's own and stays as it is.
local KEYS = {
  quit = "SUPER + Q",      -- quit the active window's app
  minimize = "SUPER + M",  -- minimize the active window
  arrange = "SUPER + A",   -- arrange the screen's windows (again to undo)
  maximize = false,        -- maximize / restore the active window, e.g. "SUPER + CTRL + M"
}

-- Optional: pin workspaces to monitors, so switching on one screen never
-- empties the other. The first workspace of each range is that monitor's
-- default. Monitor names: `hyprctl monitors`. Rules for a monitor that isn't
-- plugged in are ignored. Empty = Omarchy's default behaviour.
--   local MONITOR_WORKSPACES = { ["DP-1"] = { 1, 5 }, ["eDP-1"] = { 6, 10 } }
local MONITOR_WORKSPACES = {}

-- State folders of a dock, under ~/.local/state/omarchy/, first match wins.
-- A visible dock publishes the height it covers there (cover-<monitor>), and
-- snapped windows stop above it; this module lists maximized windows there
-- (maximized), so the dock can hide while one fills the screen. Written
-- only into folders that already exist. The first entry is Glass Dock
-- (github.com/hugorolimf/omarchy-dock); the second, its pre-release name.
local DOCK_STATE_DIRS = { "io.github.hugorolimf.dock", "hugo.dock" }

-- Log every automatic move with its reason, to tell which rule moved a
-- window somewhere odd: ~/.local/state/omarchy/windowing.log (~400 lines).
local LOG_MOVES = false

-- ===================================================================

local STATE = (os.getenv("XDG_STATE_HOME") or os.getenv("HOME") .. "/.local/state") .. "/omarchy"
local TOUCH = GAP + 8 -- edges this close count as touching (a snap group)

hl.window_rule({ match = { class = ".*" }, float = true })

local pressed = nil   -- active floating window when a button went down
local restore = {}    -- address -> size before the window was snapped
local saved = {}      -- address -> frame before maximize, for restoring it
local tiled = {}      -- address -> true while the window is part of a layout
local arranged = {}   -- workspace id -> { frames placed, frames before } (Super + A)
local maxed = {}      -- address -> true while the window fills its screen
local publish_maxed   -- defined below, once find_window exists

local function sel(w) return "address:" .. w.address end

-- With LOG_MOVES on, every automatic move is logged with its reason:
-- ~/.local/state/omarchy/windowing.log (last ~400 lines).
local LOG = STATE .. "/windowing.log"
local log_lines = 0
local function log(reason, w, x, y, width, height)
  if not LOG_MOVES then return end
  local f = io.open(LOG, log_lines > 400 and "w" or "a")
  if not f then return end
  log_lines = log_lines > 400 and 0 or log_lines + 1
  f:write(string.format("%s %-12s %-18s %s -> %d,%d %dx%d\n", os.date("%H:%M:%S"), reason,
    tostring(w.class):sub(1, 18), tostring(w.title):sub(1, 30), math.floor(x), math.floor(y), math.floor(width), math.floor(height)))
  f:close()
end

-- Height of a title bar drawn above each window, outside it (a title bar
-- plugin can set the global TITLEBAR_HEIGHT), so frames below are the whole
-- window: bar plus contents. 0 when nothing sets it.
local function bar() return TITLEBAR_HEIGHT or 0 end

local function frame(w)
  return { x = w.at.x, y = w.at.y - bar(), w = w.size.x, h = w.size.y + bar() }
end

-- Height the dock covers at the bottom of a monitor while it stays on
-- screen, as the dock publishes it (DOCK_STATE_DIRS); 0 when it auto-hides
-- or there is no dock. Like macOS, snapped windows stop above a visible dock.
local function dock_cover(m)
  for i = 1, #DOCK_STATE_DIRS do
    local f = io.open(STATE .. "/" .. DOCK_STATE_DIRS[i] .. "/cover-" .. m.name, "r")
    if f then
      local n = tonumber(f:read("*l") or "") or 0
      f:close()
      return n
    end
  end
  return 0
end

local function monitor_size(m)
  local w, h = m.width / m.scale, m.height / m.scale
  if (m.transform or 0) % 2 == 1 then w, h = h, w end
  return w, h
end

-- Free part of a monitor (minus bar and a visible dock), in global logical px.
local function work_area(m)
  local r = m.reserved or {}
  local w, h = monitor_size(m)
  local left, top = r.left or 0, r.top or 0
  local bottom = math.max(r.bottom or 0, dock_cover(m))
  return m.x + left, m.y + top, w - left - (r.right or 0), h - top - bottom
end

local function place_raw(w, x, y, width, height)
  hl.dispatch(hl.dsp.window.resize({ x = math.floor(width), y = math.floor(height), window = sel(w) }))
  hl.dispatch(hl.dsp.window.move({ x = math.floor(x), y = math.floor(y), window = sel(w) }))
end

-- Places a whole window (title bar included) in the given frame.
local function place(w, x, y, width, height, reason)
  if reason then log(reason, w, x, y, width, height) end
  place_raw(w, x, y + bar(), width, height - bar())
end

-- Remembers how a window was before it joins a layout, for dragging it back
-- out (restore) or un-maximizing it (saved).
local function remember(w, f)
  if not saved[w.address] then saved[w.address] = f or frame(w) end
  if not restore[w.address] then restore[w.address] = { w = w.size.x, h = w.size.y } end
  tiled[w.address] = true
end

local function forget(address)
  restore[address], saved[address], tiled[address] = nil, nil, nil
  if maxed[address] then
    maxed[address] = nil
    publish_maxed()
  end
end

-- Visible floating windows on a workspace (optionally only on one monitor).
-- Counted loop, not ipairs: omarchy-menu-keybindings (and similar tools)
-- run the config against a stub where every hl.* call returns an endless
-- proxy, and ipairs over it never ends.
local function windows_on(wsid, except, monitor)
  local out, all = {}, hl.get_windows() or {}
  for i = 1, #all do
    local o = all[i]
    if o.address ~= except and o.mapped and not o.hidden and o.floating and o.fullscreen == 0
      and not o.pinned and o.workspace and o.workspace.id == wsid
      and (not monitor or (o.monitor and o.monitor.name == monitor)) then
      out[#out + 1] = o
    end
  end
  return out
end

local function overlap(a1, a2, b1, b2) return math.min(a2, b2) - math.max(a1, b1) end

local function same_frame(a, b)
  return math.abs(a.x - b.x) <= 3 and math.abs(a.y - b.y) <= 3 and math.abs(a.w - b.w) <= 3 and math.abs(a.h - b.h) <= 3
end

-- A window that leaves its spot (closed or minimized) while part of a layout:
-- the neighbours that only touched it along one side grow into the hole.
local function fill_hole(f, wsid, except)
  local fr, fb = f.x + f.w, f.y + f.h
  local list = windows_on(wsid, except)
  for i = 1, #list do
    local o = list[i]
    if tiled[o.address] then
      local q = frame(o)
      local qr, qb = q.x + q.w, q.y + q.h
      local within_v = q.y >= f.y - TOUCH and qb <= fb + TOUCH
      local within_h = q.x >= f.x - TOUCH and qr <= fr + TOUCH
      if within_v and math.abs(q.x - fr) <= TOUCH then          -- right of the hole
        place(o, f.x, q.y, qr - f.x, q.h, "fill-hole")
      elseif within_v and math.abs(f.x - qr) <= TOUCH then      -- left of it
        place(o, q.x, q.y, fr - q.x, q.h, "fill-hole")
      elseif within_h and math.abs(q.y - fb) <= TOUCH then      -- below it
        place(o, q.x, f.y, q.w, qb - f.y, "fill-hole")
      elseif within_h and math.abs(f.y - qb) <= TOUCH then      -- above it
        place(o, q.x, q.y, q.w, fb - q.y, "fill-hole")
      end
    end
  end
end

-- Title bar buttons call these via hyprctl eval (see the README).
function windowing_close()
  hl.dispatch(hl.dsp.window.close())
end

-- Minimize (like Windows/macOS): the window goes to a hidden workspace and
-- comes back from its icon in the dock. Super + M minimizes the active one.
-- It slides down into the bottom of its screen, where the dock is, before it
-- hides, and slides back up to the same spot when it comes back (see
-- window.move_to_workspace below), instead of just vanishing.
local minimized = {}  -- address -> { frame relative to the work area, tiled }

-- Kept on disk too: a config reload wipes this file's state, and a window
-- minimized before it would otherwise come back at its shrunken size.
local MINIMIZED_FILE = STATE .. "/windowing-minimized"
local function save_minimized()
  local f = io.open(MINIMIZED_FILE, "w")
  if not f then return end
  for a, r in pairs(minimized) do
    f:write(string.format("%s %d %d %d %d %d\n", a, r.x, r.y, r.w, r.h, r.tiled and 1 or 0))
  end
  f:close()
end
do
  local f = io.open(MINIMIZED_FILE, "r")
  if f then
    for line in f:lines() do
      local a, x, y, w, h, t = line:match("^(%S+) (%-?%d+) (%-?%d+) (%d+) (%d+) (%d)$")
      if a then minimized[a] = { x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h), tiled = t == "1" } end
    end
    f:close()
  end
end

local function find_window(address)
  local all = hl.get_windows() or {}
  for i = 1, #all do
    if all[i].address == address then return all[i] end
  end
end

function windowing_minimize(address)
  local w = find_window(address)
  if not w or not w.workspace or w.workspace.id < 0 or (minimized[address] and minimized[address].pending) then return end
  local f, m = frame(w), w.monitor
  local ax, ay, aw, ah = work_area(m)
  local _, mh = monitor_size(m)
  minimized[address] = { x = f.x - ax, y = f.y - ay, w = f.w, h = f.h, tiled = tiled[address], pending = true }
  if tiled[address] then
    tiled[address] = nil
    fill_hole(f, w.workspace.id, address)
  end
  -- Straight down into the dock: same column, same size (apps with a
  -- minimum size can't shrink, and pulling them sideways looked broken).
  if w.fullscreen == 0 and w.floating then
    hl.dispatch(hl.dsp.window.move({ x = math.floor(w.at.x), y = math.floor(m.y + mh), window = sel(w) }))
  end
  save_minimized()
  hl.timer(function()
    if minimized[address] then minimized[address].pending = nil end
    -- Hyprland pulls a window back on screen when it changes workspace; with
    -- animations on, that showed as a jump up just before it vanished.
    hl.dispatch(hl.dsp.window.set_prop({ prop = "no_anim", value = "1", window = "address:" .. address }))
    hl.dispatch(hl.dsp.window.move({ workspace = "special:minimized", window = "address:" .. address, follow = false }))
  end, { timeout = MINIMIZE_MS, type = "oneshot" })
end

-- Coming back from special:minimized (the dock, Alt + Tab): grow back to
-- where it was, on whichever screen it returns to.
hl.on("window.move_to_workspace", function(w, ws)
  if not w or not ws or tostring(ws.name):find("^special") then return end
  local r = minimized[w.address]
  if r and r.pending then return end
  local mon = ws.monitor or w.monitor
  if not mon then return end
  local ax, ay, aw, ah = work_area(mon)
  if r then
    minimized[w.address] = nil
    save_minimized()
    if r.tiled then tiled[w.address] = true end
    -- After Hyprland has placed it on the new workspace: put it below the
    -- screen at once (animations still off from minimizing), then let it
    -- slide up out of the dock to where it was.
    local _, mh = monitor_size(mon)
    hl.timer(function()
      hl.dispatch(hl.dsp.window.move({ x = math.floor(ax + r.x), y = math.floor(mon.y + mh), window = sel(w) }))
      hl.dispatch(hl.dsp.window.set_prop({ prop = "no_anim", value = "0", window = sel(w) }))
      hl.timer(function() place(w, ax + r.x, ay + r.y, r.w, r.h, "unminimize") end, { timeout = 20, type = "oneshot" })
    end, { timeout = 30, type = "oneshot" })
  elseif w.floating and w.fullscreen == 0 and (w.size.x < 200 or w.size.y < 140) then
    -- shrunk by a minimize whose record was lost: a sensible size, centred
    place(w, ax + aw * 0.2, ay + ah * 0.15, aw * 0.6, ah * 0.7, "unminimize")
  end
end)
-- Maximized windows, for the dock: while one fills the visible workspace of
-- a monitor, that monitor's dock hides like macOS and shows on hover at the
-- bottom edge, then calls windowing_refit so the window grows into the room
-- the dock left. One line per window: address workspace monitor. Written
-- into every DOCK_STATE_DIRS folder that exists (none: nothing is written).
publish_maxed = function()
  local lines = {}
  for a in pairs(maxed) do
    local w = find_window(a)
    if not w then
      maxed[a] = nil
    elseif w.workspace and w.workspace.id > 0 and w.monitor then
      lines[#lines + 1] = string.format("%s %d %s\n", a, w.workspace.id, w.monitor.name)
    end
  end
  local text = table.concat(lines)
  for i = 1, #DOCK_STATE_DIRS do
    local f = io.open(STATE .. "/" .. DOCK_STATE_DIRS[i] .. "/maximized", "w")
    if f then
      f:write(text)
      f:close()
    end
  end
end

local function set_maxed(w)
  maxed[w.address] = true
  publish_maxed()
end

-- A maximized window minimized, restored or sent to another workspace: the
-- dock of the screen it left (or reached) must know.
hl.on("window.move_to_workspace", function(w)
  if w and maxed[w.address] then
    hl.timer(function() publish_maxed() end, { timeout = 50, type = "oneshot" })
  end
end)

-- The dock of a monitor started or stopped hiding: maximized windows there
-- take the new free area (full height, or stopping above the dock again).
function windowing_refit(monitor)
  for a in pairs(maxed) do
    local w = find_window(a)
    if w and w.monitor and w.monitor.name == monitor and w.fullscreen == 0 and w.workspace and w.workspace.id > 0 then
      local ax, ay, aw, ah = work_area(w.monitor)
      place(w, ax + GAP, ay + GAP, aw - GAP * 2, ah - GAP * 2, "refit")
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

-- Super + Q quits the active window's app (Super + W only closes the
-- window; many apps keep running in the background, and the dock shows
-- them). Web apps (chrome-*) share one Chromium process with every other
-- web app, so for them only that app's windows close.
function windowing_quit(class)
  if not class then
    local w = hl.get_active_window()
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
if KEYS.quit then
  hl.bind(KEYS.quit, function() windowing_quit() end, { description = "Quit app (Super + W only closes the window)" })
end

function windowing_minimize_active()
  local w = hl.get_active_window()
  if w then windowing_minimize(w.address) end
end
if KEYS.minimize then
  hl.bind(KEYS.minimize, windowing_minimize_active, { description = "Minimize window (restore from the dock)" })
end

-- Maximize fills the free part of the monitor (bar and dock stay visible);
-- doing it again puts the window back where it was. Without an address it
-- acts on the active window (a title bar button); a caller that knows the
-- window (a button drawn on a particular window) can pass its address.
function windowing_maximize(address)
  local w = address and find_window(address) or hl.get_active_window()
  if not w or not w.floating or w.fullscreen ~= 0 then return end
  local ax, ay, aw, ah = work_area(w.monitor)
  local f, s = frame(w), saved[w.address]
  if same_frame(f, { x = ax + GAP, y = ay + GAP, w = aw - GAP * 2, h = ah - GAP * 2 }) and s then
    forget(w.address)
    place(w, s.x, s.y, s.w, s.h, "unmaximize")
  else
    saved[w.address] = f
    remember(w, f)
    set_maxed(w)
    place(w, ax + GAP, ay + GAP, aw - GAP * 2, ah - GAP * 2, "maximize")
  end
end
if KEYS.maximize then
  hl.bind(KEYS.maximize, function() windowing_maximize() end, { description = "Maximize window (again to restore)" })
end

-- w was resized from frame p to its current frame. The windows beside it
-- move with the edge that moved: one that touched that edge follows it (a
-- snapped group), and one the edge now runs into gives way. Either way they
-- end up GAP apart, never overlapping. A neighbour already at its minimum
-- size doesn't give way: then w stops GAP short of it instead.
local function follow_resize(w, p)
  if not w.workspace then return end
  local n = frame(w)
  local pr, pb = p.x + p.w, p.y + p.h
  local nx, ny, nr, nb = n.x, n.y, n.x + n.w, n.y + n.h
  local list = windows_on(w.workspace.id, w.address)
  for i = 1, #list do
    local o = list[i]
    local q = frame(o)
    local x, y, r, b = q.x, q.y, q.x + q.w, q.y + q.h
    local side = overlap(q.y, b, ny, nb) > 0 and overlap(q.y, b, p.y, pb) > 0     -- beside each other
    local stacked = overlap(q.x, r, nx, nr) > 0 and overlap(q.x, r, p.x, pr) > 0  -- one above the other
    -- which side of w the neighbour was on before the resize
    local was_right, was_left = q.x >= pr - TOUCH, r <= p.x + TOUCH
    local was_below, was_above = q.y >= pb - TOUCH, b <= p.y + TOUCH

    if side and was_right and nr ~= pr and (math.abs(q.x - pr) <= TOUCH or nr + GAP > q.x) then
      if r - (nr + GAP) >= MIN_W then x = nr + GAP else nr = q.x - GAP end
    elseif side and was_left and nx ~= p.x and (math.abs(p.x - r) <= TOUCH or nx - GAP < r) then
      if (nx - GAP) - x >= MIN_W then r = nx - GAP else nx = r + GAP end
    elseif stacked and was_below and nb ~= pb and (math.abs(q.y - pb) <= TOUCH or nb + GAP > q.y) then
      if b - (nb + GAP) >= MIN_H then y = nb + GAP else nb = q.y - GAP end
    elseif stacked and was_above and ny ~= p.y and (math.abs(p.y - b) <= TOUCH or ny - GAP < b) then
      if (ny - GAP) - y >= MIN_H then b = ny - GAP else ny = b + GAP end
    end
    if x ~= q.x or y ~= q.y or r ~= q.x + q.w or b ~= q.y + q.h then
      place(o, x, y, r - x, b - y, "give-way")
    end
  end
  if nx ~= n.x or ny ~= n.y or nr ~= n.x + n.w or nb ~= n.y + n.h then
    place(w, nx, ny, nr - nx, nb - ny, "stop-short")
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

local function snap(w, p)
  local c = hl.get_cursor_pos()
  local m = hl.get_monitor_at_cursor()
  if not c or not m then return end
  local mw, mh = monitor_size(m)
  local ax, ay, aw, ah = work_area(m)
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

    -- Only one other window on this screen, not part of a layout yet: it
    -- takes the other side, like Windows' snap assist without the picker.
    if row == "full" and m.active_workspace then
      local others = windows_on(m.active_workspace.id, w.address, m.name)
      if #others == 1 and not tiled[others[1].address] then
        local o = others[1]
        remember(o)
        local ox = side == "left" and x + width + GAP or ax + GAP
        place(o, ox, ay + GAP, aw - GAP * 3 - width, ah - GAP * 2, "other-side")
      end
    end
  elseif top and not bottom then
    remember(w, p.frame)
    set_maxed(w)
    place(w, ax + GAP, ay + GAP, aw - GAP * 2, ah - GAP * 2, "snap-top")
  elseif restore[w.address] then
    -- Back to its old size, keeping the spot it was grabbed by under the
    -- pointer (Super + drag grabs anywhere, not just a title bar).
    local r = restore[w.address]
    local fx = math.min(math.max((c.x - w.at.x) / math.max(w.size.x, 1), 0), 1)
    local fy = math.min(math.max((c.y - w.at.y) / math.max(w.size.y, 1), 0), 1)
    forget(w.address)
    log("unsnap", w, c.x - fx * r.w, c.y - fy * r.h, r.w, r.h)
    place_raw(w, c.x - fx * r.w, c.y - fy * r.h, r.w, r.h)
  end
end

-- The window under the pointer. When focus doesn't follow the mouse (e.g.
-- input follow_mouse = 2), the active window isn't necessarily the one being
-- dragged: take the active one if the pointer is on it, else the most
-- recently used one under it.
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

-- Button down: remember the window and where it was, to tell a drag or a
-- resize from a click.
local function on_press()
  local w = window_at_cursor()
  if w and w.floating then
    pressed = { address = w.address, x = w.at.x, y = w.at.y, w = w.size.x, h = w.size.y, frame = frame(w) }
  else
    pressed = nil
  end
end

-- Button up: a move snaps by where the pointer is; a resize drags the
-- neighbours of the group along.
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
local function keep_inside(address)
  local w = find_window(address)
  if not w or not w.floating or w.fullscreen ~= 0 or not w.workspace or w.workspace.id < 0 then return end
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

windowing_fit = keep_inside  -- also callable: hyprctl eval 'windowing_fit("0x...")'

local function on_release()
  local p = pressed
  pressed = nil
  if not p then return end
  local w = find_window(p.address)
  if not w or w.address ~= p.address or not w.floating or w.fullscreen ~= 0 then return end
  local moved = w.at.x ~= p.x or w.at.y ~= p.y
  local resized = w.size.x ~= p.w or w.size.y ~= p.h
  if resized then
    follow_resize(w, p.frame)
    saved[w.address] = nil
    if maxed[w.address] then maxed[w.address] = nil publish_maxed() end
  elseif moved then
    snap(w, p)
  end
  if moved or resized then
    -- once the moves above have landed
    hl.timer(function() keep_inside(p.address) end, { timeout = 40, type = "oneshot" })
  end
end

for _, button in ipairs({ "mouse:272", "mouse:273" }) do
  hl.bind(button, on_press, { non_consuming = true, ignore_mods = true, description = "Window snap: track drag" })
  hl.bind(button, on_release, { non_consuming = true, release = true, ignore_mods = true, description = "Window snap: snap on release" })
end

-- Frames of a layout of n windows in a work area, biggest spot first.
local function layout(n, ax, ay, aw, ah)
  local full = { x = ax + GAP, y = ay + GAP, w = aw - GAP * 2, h = ah - GAP * 2 }
  local hw, hh = (aw - GAP * 3) / 2, (ah - GAP * 3) / 2
  local lx, rx, ty, by = ax + GAP, ax + GAP * 2 + hw, ay + GAP, ay + GAP * 2 + hh
  if n == 1 then return { full } end
  if n == 2 then
    return { { x = lx, y = ty, w = hw, h = full.h }, { x = rx, y = ty, w = hw, h = full.h } }
  end
  if n == 3 then
    return { { x = lx, y = ty, w = hw, h = full.h }, { x = rx, y = ty, w = hw, h = hh }, { x = rx, y = by, w = hw, h = hh } }
  end
  local cols = math.ceil(math.sqrt(n))
  local rows = math.ceil(n / cols)
  local ch = (ah - GAP * (rows + 1)) / rows
  local out = {}
  for r = 0, rows - 1 do
    local in_row = math.min(cols, n - r * cols)  -- the last row may be short: its cells widen
    local cw = (aw - GAP * (in_row + 1)) / in_row
    for k = 0, in_row - 1 do
      out[#out + 1] = { x = ax + GAP + k * (cw + GAP), y = ay + GAP + r * (ch + GAP), w = cw, h = ch }
    end
  end
  return out
end

-- Super + A: arrange the windows of the screen under the pointer. The active
-- window gets the biggest spot, the others follow by how recently they were
-- used. Pressing it again, before anything moved, puts them back.
function windowing_arrange()
  local m = hl.get_monitor_at_cursor()
  if not m or not m.active_workspace then return end
  local wsid = m.active_workspace.id
  local list = windows_on(wsid, nil, m.name)
  if #list == 0 then return end

  local prev = arranged[wsid]
  if prev then
    local untouched = true
    for i = 1, #list do
      local want = prev.placed[list[i].address]
      if not want or not same_frame(frame(list[i]), want) then untouched = false end
    end
    arranged[wsid] = nil
    if untouched then
      for i = 1, #list do
        local f = prev.before[list[i].address]
        forget(list[i].address)
        if f then place(list[i], f.x, f.y, f.w, f.h) end
      end
      return
    end
  end

  table.sort(list, function(a, b) return (a.focus_history_id or 99) < (b.focus_history_id or 99) end)
  local ax, ay, aw, ah = work_area(m)
  local spots = layout(#list, ax, ay, aw, ah)
  local state = { placed = {}, before = {} }
  for i = 1, #list do
    local w, s = list[i], spots[i]
    state.before[w.address] = frame(w)
    state.placed[w.address] = s
    remember(w)
    if #list == 1 then set_maxed(w) end
    place(w, s.x, s.y, s.w, s.h)
  end
  arranged[wsid] = state
end
if KEYS.arrange then
  hl.bind(KEYS.arrange, windowing_arrange, { description = "Arrange windows (again to undo)" })
end

-- Largest empty rectangle of a work area, given the windows already there.
local function largest_free(ax, ay, aw, ah, list)
  local xs, xe, ys, ye = { ax + GAP }, { ax + aw - GAP }, { ay + GAP }, { ay + ah - GAP }
  local rects = {}
  for i = 1, #list do
    local q = frame(list[i])
    rects[#rects + 1] = q
    xs[#xs + 1], xe[#xe + 1] = q.x + q.w + GAP, q.x - GAP
    ys[#ys + 1], ye[#ye + 1] = q.y + q.h + GAP, q.y - GAP
  end
  local best, area = nil, 0
  for a = 1, #xs do for b = 1, #xe do
    local x0, x1 = xs[a], xe[b]
    if x1 - x0 >= MIN_W and x0 >= ax and x1 <= ax + aw then
      for c = 1, #ys do for d = 1, #ye do
        local y0, y1 = ys[c], ye[d]
        local ar = (x1 - x0) * (y1 - y0)
        if y1 - y0 >= MIN_H and ar > area and y0 >= ay and y1 <= ay + ah then
          local free = true
          for k = 1, #rects do
            local q = rects[k]
            if overlap(q.x, q.x + q.w, x0, x1) > 0 and overlap(q.y, q.y + q.h, y0, y1) > 0 then free = false break end
          end
          if free then best, area = { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }, ar end
        end
      end end
    end
  end end
  return best
end

-- A new window lands in the largest free area of its screen when it would
-- otherwise cover another window and fits there. Dialogs Omarchy centres
-- (tag floating-window) keep their place.
-- Each app's window is remembered when it closes (size and place, relative
-- to the free area of its screen) and reopens the same way. On another
-- screen (laptop vs. monitor) it is scaled to that screen and kept inside
-- it. Only for the app's first window; more windows of an already open app
-- go through place_new. ~/.local/state/omarchy/windowing-geometry
local GEOMETRY_FILE = STATE .. "/windowing-geometry"
local geometry = {}  -- class -> { mon, aw, ah, x, y, w, h } (x, y from the work area's corner)
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

local function is_dialog(w)
  local tags = w.tags or {}
  for i = 1, #tags do
    if tostring(tags[i]):find("floating%-window") then return true end
  end
  return false
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

local function restore_geometry(w)
  local g = w and w.class and geometry[w.class]
  if not g or not w.floating or w.fullscreen ~= 0 or not w.monitor or not w.workspace or w.workspace.id < 0 then return false end
  if is_dialog(w) or #siblings(w) > 0 then return false end
  local ax, ay, aw, ah = work_area(w.monitor)
  local x, y, width, height = g.x, g.y, g.w, g.h
  if g.mon ~= w.monitor.name or math.abs(g.aw - aw) > 2 or math.abs(g.ah - ah) > 2 then
    local sx, sy = aw / g.aw, ah / g.ah   -- another screen: same share of it
    x, y, width, height = x * sx, y * sy, width * sx, height * sy
  end
  width = math.max(math.min(width, aw - GAP * 2), MIN_W)
  height = math.max(math.min(height, ah - GAP * 2), MIN_H)
  x = math.min(math.max(x, GAP), aw - GAP - width)
  y = math.min(math.max(y, GAP), ah - GAP - height)
  -- a moment later, so it lands after Hyprland's own placement rules
  hl.timer(function() place(w, ax + x, ay + y, width, height, "reopen") end, { timeout = 40, type = "oneshot" })
  return true
end

local function place_new(w)
  if not w or not w.floating or w.fullscreen ~= 0 or not w.workspace or not w.monitor then return end
  if w.size.x < 80 or w.size.y < 60 then return end
  local tags = w.tags or {}
  for i = 1, #tags do
    if tostring(tags[i]):find("floating%-window") then return end
  end
  local list = windows_on(w.workspace.id, w.address, w.monitor.name)
  if #list == 0 then return end
  local f = frame(w)
  local covers = false
  for i = 1, #list do
    local q = frame(list[i])
    if overlap(q.x, q.x + q.w, f.x, f.x + f.w) > 0 and overlap(q.y, q.y + q.h, f.y, f.y + f.h) > 0 then covers = true end
  end
  if not covers then return end
  local ax, ay, aw, ah = work_area(w.monitor)
  local r = largest_free(ax, ay, aw, ah, list)
  if not r or r.w < f.w or r.h < f.h then return end
  place(w, r.x + (r.w - f.w) / 2, r.y + (r.h - f.h) / 2, f.w, f.h, "new-window")
end
hl.on("window.open", function(w)
  local ok, restored = pcall(restore_geometry, w)
  if not (ok and restored) then pcall(place_new, w) end
end)

hl.on("window.close", function(w)
  if not w or not w.address then return end
  pcall(remember_geometry, w)
  if minimized[w.address] then minimized[w.address] = nil save_minimized() end
  if tiled[w.address] and w.workspace and w.at and w.size then
    pcall(fill_hole, frame(w), w.workspace.id, w.address)
  end
  forget(w.address)
end)

-- The float rule only reaches windows opened from now on. Windows that were
-- already tiled float too, keeping their place and size, so Super + right
-- drag can resize them freely (a tiled window filling the screen can't grow).
local function float_existing()
  -- Counted loop, not ipairs: see windows_on.
  local windows = hl.get_windows() or {}
  for i = 1, #windows do
    local w = windows[i]
    if w.mapped and not w.floating and w.fullscreen == 0 then
      local x, y, width, height = w.at.x, w.at.y, w.size.x, w.size.y
      hl.dispatch(hl.dsp.window.float({ action = "enable", window = sel(w) }))
      place_raw(w, x, y, width, height)
    end
  end
end
pcall(float_existing)
hl.on("config.reloaded", function() pcall(float_existing) end)

-- Optional (MONITOR_WORKSPACES): each monitor keeps its own workspaces, so
-- switching on one never empties the other. A rule for a monitor that isn't
-- plugged in is ignored, so a laptop alone still gets every workspace.
for monitor, range in pairs(MONITOR_WORKSPACES) do
  for n = range[1], range[2] do
    hl.workspace_rule({ workspace = tostring(n), monitor = monitor, default = n == range[1] })
  end
end
