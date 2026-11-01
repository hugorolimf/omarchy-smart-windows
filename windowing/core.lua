-- Shared state and helpers of the window management (see hypr/windowing.lua).
-- Every module takes this table; functions one module defines for another
-- (W.keep_inside, W.main_window, ...) are looked up on it when called.

local S = require("windowing.settings")
local W = { settings = S }

W.ZONE = S.ZONE       -- px from a monitor border where letting go snaps
W.SHARED = S.SHARED      -- the same, on a border shared with another monitor
W.CORNER = S.CORNER   -- share of a side, next to a corner, that snaps a quarter
W.GAP = S.GAP         -- space between snapped windows and the screen border
W.TOUCH = W.GAP + 8 -- edges this close count as touching (a snap group)
W.MIN_W, W.MIN_H = S.MIN_W, S.MIN_H

W.restore = {}    -- address -> size before the window was snapped
W.saved = {}      -- address -> frame before maximize, for restoring it
W.arranged = {}   -- workspace id -> { frames placed, frames before } of the last Super + A, to undo it
W.maxed = {}      -- address -> true while the window fills its screen
W.minimized = {}  -- address -> { frame relative to the work area, workspace it left }

W.STATE = (os.getenv("XDG_STATE_HOME") or os.getenv("HOME") .. "/.local/state") .. "/omarchy"

function W.sel(w) return "address:" .. w.address end

-- With LOG_MOVES, every automatic move is logged with its reason, to tell which rule moved a
-- window somewhere odd: ~/.local/state/omarchy/windowing.log (last ~400 lines).
local LOG = W.STATE .. "/windowing.log"
local log_lines = 0
function W.log(reason, w, x, y, width, height)
  if not S.LOG_MOVES then return end
  local f = io.open(LOG, log_lines > 400 and "w" or "a")
  if not f then return end
  log_lines = log_lines > 400 and 0 or log_lines + 1
  f:write(string.format("%s %-12s %-18s %s -> %d,%d %dx%d\n", os.date("%H:%M:%S"), reason,
    tostring(w.class):sub(1, 18), tostring(w.title):sub(1, 30), math.floor(x), math.floor(y), math.floor(width), math.floor(height)))
  f:close()
end

-- Height of the title bar drawn above each window (titlebars.lua), so frames
-- below are the whole window: bar plus contents.
function W.bar() return TITLEBAR_HEIGHT or 0 end

function W.frame(w)
  return { x = w.at.x, y = w.at.y - W.bar(), w = w.size.x, h = w.size.y + W.bar() }
end

-- Room a shell plugin publishes as covered on monitor m (a number in
-- ~/.local/state/omarchy/<plugin>/cover-<monitor>), 0 without one. The dock
-- writes two: what it covers right now, then its line (see dock_line).
local function cover(plugin, m, second)
  local f = io.open(W.STATE .. "/" .. plugin .. "/cover-" .. m.name, "r")
  if not f then return 0 end
  local now, line = (f:read("*l") or ""):match("^%s*(%d*)%s*(%d*)")
  f:close()
  now = tonumber(now) or 0
  if second then return tonumber(line) or now end
  return now
end

-- Height the dock (Glass Dock) covers at the bottom of a monitor right now;
-- 0 while it hides (auto-hide, or stepping aside for a maximized window).
local function dock_cover(m) return cover("io.github.hugorolimf.dock", m) end

-- The dock's line: the height ordinary windows stop above, across the whole
-- width (also beside the dock, where it doesn't reach) and also while the
-- dock steps aside for a maximized window. 0 only when the dock auto-hides
-- by choice: then every window may use the full height.
local function dock_line(m) return cover("io.github.hugorolimf.dock", m, true) end

-- Height the notch (Island Notch) hangs from the top of a monitor, below the
-- bar; snapped windows start under it.
local function island_cover(m) return cover("io.github.hugorolimf.island", m) end

function W.monitor_size(m)
  local w, h = m.width / m.scale, m.height / m.scale
  if (m.transform or 0) % 2 == 1 then w, h = h, w end
  return w, h
end

-- Free part of a monitor, in global logical px: below the bar and the notch,
-- above the dock's line. Only maximized windows (max = true) also take the
-- room the dock leaves while it hides for them; fullscreen ignores it all.
function W.work_area(m, max)
  local r = m.reserved or {}
  local w, h = W.monitor_size(m)
  local left, top = r.left or 0, math.max(r.top or 0, island_cover(m))
  local bottom = math.max(r.bottom or 0, max and dock_cover(m) or dock_line(m))
  return m.x + left, m.y + top, w - left - (r.right or 0), h - top - bottom
end

function W.place_raw(w, x, y, width, height)
  hl.dispatch(hl.dsp.window.resize({ x = math.floor(width), y = math.floor(height), window = W.sel(w) }))
  hl.dispatch(hl.dsp.window.move({ x = math.floor(x), y = math.floor(y), window = W.sel(w) }))
end

-- Places a whole window (title bar included) in the given frame.
function W.place(w, x, y, width, height, reason)
  if reason then W.log(reason, w, x, y, width, height) end
  W.place_raw(w, x, y + W.bar(), width, height - W.bar())
end

-- Maximized windows, for the dock (Glass Dock): while one fills the visible
-- workspace of a monitor, that monitor's dock hides like macOS and shows on
-- hover at the bottom edge, then calls windowing_refit so the window grows
-- into the room the dock left. One line per window: address workspace monitor.
local MAXED_FILE = W.STATE .. "/io.github.hugorolimf.dock/maximized"
function W.publish_maxed()
  local f = io.open(MAXED_FILE, "w")
  if not f then return end
  for a in pairs(W.maxed) do
    local w = W.find_window(a)
    if not w then
      W.maxed[a] = nil
    elseif w.workspace and w.workspace.id > 0 and w.monitor then
      f:write(string.format("%s %d %s\n", a, w.workspace.id, w.monitor.name))
    end
  end
  f:close()
end

function W.set_maxed(w)
  W.maxed[w.address] = true
  W.publish_maxed()
end

-- Remembers how a window was before it was snapped or arranged, for dragging
-- it back out (restore) or un-maximizing it (saved).
function W.remember(w, f)
  if not W.saved[w.address] then W.saved[w.address] = f or W.frame(w) end
  if not W.restore[w.address] then W.restore[w.address] = { w = w.size.x, h = w.size.y } end
end

function W.forget(address)
  W.restore[address], W.saved[address] = nil, nil
  if W.maxed[address] then
    W.maxed[address] = nil
    W.publish_maxed()
  end
end

-- Dialogs Omarchy centres (tag floating-window) stay out of layouts.
function W.is_dialog(w)
  local tags = w.tags or {}
  for i = 1, #tags do
    if tostring(tags[i]):find("floating%-window") then return true end
  end
  return false
end

-- Visible floating windows on a workspace (optionally only on one monitor).
-- Counted loop, not ipairs: omarchy-menu-keybindings (and Key Promoter) run
-- this file against a stub where every hl.* call returns an endless proxy,
-- and ipairs over it never ends.
function W.windows_on(wsid, except, monitor)
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

function W.find_window(address)
  local all = hl.get_windows() or {}
  for i = 1, #all do
    if all[i].address == address then return all[i] end
  end
end

function W.monitor_named(name)
  local all = hl.get_monitors() or {}
  for i = 1, #all do
    if all[i].name == name then return all[i] end
  end
end

function W.overlap(a1, a2, b1, b2) return math.min(a2, b2) - math.max(a1, b1) end

function W.same_frame(a, b)
  return math.abs(a.x - b.x) <= 3 and math.abs(a.y - b.y) <= 3 and math.abs(a.w - b.w) <= 3 and math.abs(a.h - b.h) <= 3
end

return W
