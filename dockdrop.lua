-- Drag a window onto a workspace tile of Glass Dock and it goes to that
-- workspace. When a drag starts the dock shows itself and lists its tiles in
-- <dock state>/tiles-<monitor> ("id x y w h", global px); this follows the
-- pointer and tells the dock what happens in <dock state>/drag
-- ("seq phase address ws cx cy fx fy fw fh", the window's frame where it is
-- now): start, hover (over a tile: the dock draws the window going into it
-- while the window itself fades out), leave, drop and end. A dropped window
-- takes its place from before the drag on the new workspace; the screen stays
-- where it is. Without the dock there are no tiles, so nothing here happens.
local TICK = 30          -- ms between looks at the pointer
local START = 8          -- px the window must move before it counts as a drag

-- W: find_window, frame, place (from windowing.lua) and dir (the dock's state folder).
return function(W)
  -- Faded out while over a tile: removing the tag gives the window back the
  -- opacity its own rules give it.
  hl.window_rule({ match = { tag = "dock-drop" }, opacity = "0 override 0 override" })

  local drag = nil       -- { address, frame, x, y, started, ws, timer }
  local seq = os.time() * 100

  local function tell(phase, d, ws, c, r)
    seq = seq + 1
    local f = io.open(W.dir .. "/drag", "w")
    if not f then return end
    r = r or d.frame
    f:write(string.format("%d %s %s %d %d %d %d %d %d %d\n", seq, phase, d.address, ws or -1,
      math.floor(c and c.x or 0), math.floor(c and c.y or 0), math.floor(r.x), math.floor(r.y), math.floor(r.w), math.floor(r.h)))
    f:close()
  end

  local function fade(address, out)
    hl.dispatch(hl.dsp.window.tag({ window = "address:" .. address, tag = (out and "+" or "-") .. "dock-drop" }))
  end

  -- The workspace whose tile is under c, from every dock's list.
  local function tile_at(c)
    local ms = hl.get_monitors() or {}
    for i = 1, #ms do
      local f = io.open(W.dir .. "/tiles-" .. ms[i].name, "r")
      if f then
        for line in f:lines() do
          local id, x, y, w, h = line:match("^(%-?%d+) (%-?[%d.]+) (%-?[%d.]+) ([%d.]+) ([%d.]+)")
          x, y, w, h = tonumber(x), tonumber(y), tonumber(w), tonumber(h)
          if id and c.x >= x - 4 and c.x <= x + w + 4 and c.y >= y - 6 and c.y <= y + h + 6 then
            f:close()
            return tonumber(id)
          end
        end
        f:close()
      end
    end
  end

  local function stop()
    if drag and drag.timer then drag.timer:set_enabled(false) end
    local d = drag
    drag = nil
    return d
  end

  local function tick()
    local d = drag
    if not d then return end
    local w = W.find_window(d.address)
    local c = hl.get_cursor_pos()
    if not w or not c then stop() return end
    if not d.started then
      -- a click that never became a drag (or whose release got lost)
      d.ticks = (d.ticks or 0) + 1
      if d.ticks * TICK > 3000 then stop() return end
      if math.abs(w.at.x - d.x) + math.abs(w.at.y - d.y) < START then return end
      d.started = true
      tell("start", d, -1, c)
      return
    end
    local ws = tile_at(c)
    -- its own workspace's tile: nowhere to go
    if w.workspace and ws == w.workspace.id then ws = nil end
    if ws == d.ws then return end
    d.ws = ws
    fade(d.address, ws ~= nil)
    tell(ws and "hover" or "leave", d, ws, c, W.frame(w))
  end

  local M = {}

  -- A left button went down on a floating window: watch whether it gets dragged.
  function M.press(p)
    stop()
    drag = { address = p.address, frame = p.frame, x = p.x, y = p.y, started = false }
    drag.timer = hl.timer(tick, { timeout = TICK, type = "repeat" })
  end

  -- The button came up: true when the window went into a workspace (the
  -- usual snapping is skipped then).
  function M.release()
    local d = stop()
    if not d or not d.started then return false end
    local c = hl.get_cursor_pos()
    local w = W.find_window(d.address)
    if not d.ws or not w or not w.workspace or w.workspace.id == d.ws then
      if d.ws then fade(d.address, false) end
      tell("end", d, -1, c)
      return false
    end
    tell("drop", d, d.ws, c)
    -- Unseen (still faded, no animation): back where it was before the drag,
    -- then over to the workspace, then visible again there.
    local f, sel = d.frame, "address:" .. d.address
    hl.dispatch(hl.dsp.window.set_prop({ prop = "no_anim", value = "1", window = sel }))
    W.place(w, f.x, f.y, f.w, f.h, "dock-drop")
    hl.dispatch(hl.dsp.window.move({ workspace = tostring(d.ws), window = sel, follow = false }))
    hl.timer(function()
      fade(d.address, false)
      hl.dispatch(hl.dsp.window.set_prop({ prop = "no_anim", value = "0", window = sel }))
    end, { timeout = 120, type = "oneshot" })
    return true
  end

  return M
end
