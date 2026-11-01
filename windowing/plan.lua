-- Scoring the models for the windows of a screen (see picker.lua for what
-- the scores mean to the user).

local W = require("windowing.core")
local frame, work_area = W.frame, W.work_area

-- How an app likes its room: 1 wide, -1 narrow, 0 either. Known apps by
-- class; the others by the size the user gives them when they float.
local WIDE = { "firefox", "chromium", "chrome", "brave", "vivaldi", "obsidian", "code", "cursor", "zed",
  "sm pro", "libreoffice", "gimp", "krita", "inkscape", "blender", "figma", "artcraft", "darktable", "kdenlive",
  "evince", "zathura" }
local NARROW = { "foot", "kitty", "alacritty", "ghostty", "wezterm", "spotify", "whatsapp", "signal",
  "telegram", "discord", "pavucontrol", "org.gnome", "nautilus", "btop", "calculator", "localsend", "tether" }
local function kind_of(w)
  local c = tostring(w.class or ""):lower()
  for i = 1, #NARROW do if c:find(NARROW[i], 1, true) then return -1 end end
  for i = 1, #WIDE do if c:find(WIDE[i], 1, true) then return 1 end end
  local g = W.geometry[w.class]
  if g and g.aw > 0 then
    if g.w / g.aw >= 0.6 then return 1 end
    if g.w / g.aw <= 0.4 then return -1 end
  end
  return 0
end

-- The window in use: the active one, else the one focused last.
function W.main_window(list)
  local act = hl.get_active_window()
  local best, best_h = nil, math.huge
  for i = 1, #list do
    if act and list[i].address == act.address then return i end
    local h = list[i].focus_history_id
    if h and h >= 0 and h < best_h then best, best_h = i, h end
  end
  return best or 1
end

-- The pairing of windows to spots with the lowest total cost (cost[i][j]:
-- window i in spot j). Every order is tried up to 7 windows, dropping orders
-- already worse than the best; past that, the cheapest pairs go first.
local function assign(cost, n)
  local best, best_cost = {}, math.huge
  if n <= 7 then
    local pick, used = {}, {}
    local function try(i, total)
      if total >= best_cost then return end
      if i > n then
        best_cost = total
        for k = 1, n do best[k] = pick[k] end
        return
      end
      for j = 1, n do
        if not used[j] then
          used[j], pick[i] = true, j
          try(i + 1, total + cost[i][j])
          used[j] = false
        end
      end
    end
    try(1, 0)
  else
    local wfree, sfree = {}, {}
    best_cost = 0
    for _ = 1, n do
      local bi, bj, bc = nil, nil, math.huge
      for i = 1, n do
        if not wfree[i] then
          for j = 1, n do
            if not sfree[j] and cost[i][j] < bc then bi, bj, bc = i, j, cost[i][j] end
          end
        end
      end
      wfree[bi], sfree[bj], best[bi] = true, true, bj
      best_cost = best_cost + bc
    end
  end
  return best, best_cost
end

-- Where each window would go in a model: the cost of a spot is how far the
-- window travels (a share of the screen's diagonal), plus a wide app in a
-- narrow spot or a narrow one in a wide spot, plus the window in use
-- anywhere but the main spot.
local function evaluate(model, info, ax, ay, aw, ah, mirrored)
  local spots, n = W.frames_of(model.cells, ax, ay, aw, ah, mirrored), #info
  local diag, cost = math.sqrt(aw * aw + ah * ah), {}
  for i = 1, n do
    local f = info[i].frame
    local cx, cy = f.x + f.w / 2, f.y + f.h / 2
    cost[i] = {}
    for j = 1, n do
      local s = spots[j]
      local dx, dy = cx - (s.x + s.w / 2), cy - (s.y + s.h / 2)
      local c, share = math.sqrt(dx * dx + dy * dy) / diag, s.w / aw
      if info[i].kind > 0 then c = c + math.max(0, 0.55 - share) * 3
      elseif info[i].kind < 0 then c = c + math.max(0, share - 0.5) * 0.8 end
      if model.main and info[i].main and j ~= 1 then c = c + 2 end
      if info[i].main then c = c + j * 0.01 end  -- a tie goes to the top / left spot
      cost[i][j] = c
    end
  end
  local order, total = assign(cost, n)
  return spots, order, total
end

-- Whether the windows already sit in a model's spots (in any order).
local function already(info, spots)
  local used = {}
  for i = 1, #info do
    local f, found = info[i].frame, false
    for j = 1, #spots do
      local s = spots[j]
      if not used[j] and math.abs(f.x - s.x) <= 12 and math.abs(f.y - s.y) <= 12
        and math.abs(f.w - s.w) <= 12 and math.abs(f.h - s.h) <= 12 then
        used[j], found = true, true
        break
      end
    end
    if not found then return false end
  end
  return true
end

-- Models picked per screen and number of windows: "monitor n id" -> times.
local PICKS_FILE = W.STATE .. "/windowing-layouts"
local picks = {}
do
  local f = io.open(PICKS_FILE, "r")
  if f then
    for line in f:lines() do
      local key, times = line:match("^(.-)\t(%d+)$")
      if key then picks[key] = tonumber(times) end
    end
    f:close()
  end
end
function W.count_pick(key)
  picks[key] = (picks[key] or 0) + 1
  local f = io.open(PICKS_FILE, "w")
  if not f then return end
  for k, t in pairs(picks) do f:write(string.format("%s\t%d\n", k, t)) end
  f:close()
end

-- The models for the windows in list on monitor m, scored: main is the index
-- of the window in use. Returns the models that fit (the first at least,
-- when none does), the index of the suggestion, the windows' info and the
-- work area.
function W.plan(m, list, main)
  local n = #list
  local ax, ay, aw, ah = work_area(m)
  local info = {}
  for i = 1, n do
    info[i] = { frame = frame(list[i]), kind = kind_of(list[i]), main = i == main }
  end
  local cat, models = W.catalog(n, aw, ah), {}
  for k = 1, #cat do
    local md = cat[k]
    local spots, order, total = evaluate(md, info, ax, ay, aw, ah, false)
    local spots_m, order_m, total_m = evaluate(md, info, ax, ay, aw, ah, true)
    if total_m < total - 0.001 then spots, order, total = spots_m, order_m, total_m end
    local fits, shape = true, 0
    for j = 1, n do
      local s = spots[j]
      if s.w < W.SPOT_W or s.h < W.SPOT_H then fits = false end
      local a = s.w / s.h
      shape = shape + (a < 0.5 and (0.5 - a) * 2 or a > 2.8 and (a - 2.8) * 0.4 or 0)
    end
    -- the first model stays even when nothing fits (many windows on the laptop)
    if fits or (k == #cat and #models == 0) then
      local key = m.name .. " " .. n .. " " .. md.id
      models[#models + 1] = {
        id = md.id, name = md.name, note = md.note, spots = spots, order = order,
        current = already(info, spots), max = n == 1 and md.id == "full",
        score = (total + shape) / n + #models * 0.04 - math.min(picks[key] or 0, 6) * 0.06,
      }
    end
  end
  local sug = nil
  for k = 1, #models do
    if not models[k].current and (not sug or models[k].score < models[sug].score) then sug = k end
  end
  return models, sug or 1, info, ax, ay, aw, ah
end
