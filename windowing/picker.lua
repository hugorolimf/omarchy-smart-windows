-- Super + A: choose how to arrange the windows of the screen under the
-- pointer. A panel (shell plugin Island Arrange) shows the models that suit
-- this screen and this many windows, each drawn with the windows where they
-- would land, and previews the highlighted one on the screen itself: 1-9
-- apply a model, Enter (or Super + A again) the highlighted one, 0 puts the
-- windows back as they were before the last arrangement (while nothing has
-- moved since), Esc leaves. Super + right click without dragging opens it too.
--
-- The models are worked out for the moment, not fixed:
--   * only the ones that leave every window usable room on this screen (the
--     big monitor gets four or five columns, the laptop fewer);
--   * the window in use takes the main spot, where a model has one;
--   * wide apps (browsers, editors, notes) take the wide spots, terminals and
--     chats the narrow ones (an app the user keeps wide or narrow when it
--     floats counts the same way);
--   * every window takes the spot nearest to where it is, and lopsided
--     models put their big spot on the side that moves less;
--   * the suggestion (★) is the model that suits these windows best, leaning
--     on the one picked most often for this screen and this many windows;
--     the arrangement already on screen reads ATUAL.
-- An arrangement happens once, when it is picked: the windows go to their
-- spots and stay there. Windows that open, close, hide or come back later
-- never move the others. Dialogs Omarchy centres (tag floating-window) stay
-- out of it.

local W = require("windowing.core")
local frame, place, find_window, windows_on, is_dialog, same_frame = W.frame, W.place, W.find_window, W.windows_on, W.is_dialog, W.same_frame
local arranged, maxed = W.arranged, W.maxed

-- The models (window titles too) never go in a command line, which other
-- accounts can read: they are written to a file in a 0700 folder under
-- $XDG_RUNTIME_DIR and only its path goes to the shell.
local RUNTIME = os.getenv("XDG_RUNTIME_DIR")
local LAYOUT_DIR = RUNTIME and RUNTIME ~= "" and (RUNTIME .. "/island-arrange") or nil
local LAYOUT_FILE = LAYOUT_DIR and (LAYOUT_DIR .. "/models.json") or nil
local function quote(path) return "'" .. path:gsub("'", "'\\''") .. "'" end
if LAYOUT_DIR then os.execute("mkdir -p -m 700 " .. quote(LAYOUT_DIR) .. " && chmod 700 " .. quote(LAYOUT_DIR)) end

local function json_string(value)
  local escaped = tostring(value or ""):gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"' end
    if c == "\\" then return "\\\\" end
    return string.format("\\u%04x", c:byte())
  end)
  return '"' .. escaped .. '"'
end

-- The panel being shown: { session, wsid, monitor, all = every window's
-- address, out = the ones left out (address -> true), list = the others',
-- main, models }.
local picker, picker_session = nil, 0

-- Island Arrange draws the models. Without it the suggested one is applied at once.
local PANEL = (os.getenv("XDG_CONFIG_HOME") or os.getenv("HOME") .. "/.config") .. "/omarchy/plugins/io.github.hugorolimf.arrange/manifest.json"
local function has_panel()
  if rawget(_G, "SMART_WINDOWS_PANEL") ~= nil then return SMART_WINDOWS_PANEL end
  local f = io.open(PANEL, "r")
  if f then f:close() end
  return f ~= nil
end

-- Puts each window of list in its spot (spots[i] for list[i]) and keeps where
-- they were and where they went, to undo it. max: the model maximizes (one
-- window).
local function apply_spots(list, spots, max, id, wsid, reason)
  local state = { placed = {}, before = {} }
  local unmaxed = false
  for i = 1, #list do
    local w, s = list[i], spots[i]
    if w and s and w.fullscreen == 0 then
      state.before[w.address] = frame(w)
      state.placed[w.address] = s
      W.remember(w)
      if max then W.set_maxed(w)
      elseif maxed[w.address] then maxed[w.address], unmaxed = nil, true end
      place(w, s.x, s.y, s.w, s.h, reason .. "-" .. id)
    end
  end
  if unmaxed then W.publish_maxed() end
  arranged[wsid] = state
end

-- The last arrangement of a workspace can be undone while every window is
-- still where it put them.
local function untouched(prev, list)
  for i = 1, #list do
    local want = prev.placed[list[i].address]
    if not want or not same_frame(frame(list[i]), want) then return false end
  end
  return true
end

-- Works out the models for the windows of all on monitor m but the ones in
-- out (right click on one in the panel), and hands them to the panel; again
-- (refresh) when a window was taken out or put back, the panel staying up.
local function show_picker(m, wsid, all, out, refresh)
  local list, at = {}, {}
  for i = 1, #all do
    if not out[all[i].address] then
      list[#list + 1] = all[i]
      at[#list] = i - 1
    end
  end
  local n = #list
  if n == 0 then return end
  local mi = W.main_window(list)
  local models, sug, _, ax, ay, aw, ah = W.plan(m, list, mi)
  if #models == 0 then return end

  picker_session = picker_session + 1
  local addresses, included = {}, {}
  for i = 1, #all do addresses[i] = all[i].address end
  for i = 1, n do included[i] = list[i].address end
  picker = { session = picker_session, wsid = wsid, monitor = m.name, all = addresses, out = out, list = included,
    models = models }
  if not has_panel() then return windowing_layout_pick(picker_session, sug) end

  local ox, oy = m.x, m.y
  local wins, ms = {}, {}
  for i = 1, #all do
    local w = all[i]
    local f = frame(w)
    wins[i] = string.format('{"a":%s,"c":%s,"t":%s,"main":%s,"out":%s,"x":%d,"y":%d,"w":%d,"h":%d}',
      json_string(w.address), json_string(w.class), json_string(w.title), w.address == list[mi].address and "true" or "false",
      out[w.address] and "true" or "false", f.x - ox, f.y - oy, f.w, f.h)
  end
  for k = 1, #models do
    local md, of, sp = models[k], {}, {}
    for i = 1, n do of[md.order[i]] = at[i] end
    for j = 1, n do
      local s = md.spots[j]
      sp[j] = string.format('{"x":%d,"y":%d,"w":%d,"h":%d,"i":%d}', s.x - ox, s.y - oy, s.w, s.h, of[j])
    end
    ms[k] = string.format('{"id":%s,"name":%s,"note":%s,"cur":%s,"sug":%s,"spots":[%s]}',
      json_string(md.id), json_string(md.name), json_string(md.note), md.current and "true" or "false",
      k == sug and "true" or "false", table.concat(sp, ","))
  end
  local prev = arranged[wsid]
  local json = string.format('{"s":%d,"mon":%s,"r":%s,"area":{"x":%d,"y":%d,"w":%d,"h":%d},"undo":%s,"sel":%d,"w":[%s],"m":[%s]}',
    picker_session, json_string(m.name), refresh and "true" or "false", ax - ox, ay - oy, aw, ah,
    prev and untouched(prev, list) and "true" or "false", sug - 1, table.concat(wins, ","), table.concat(ms, ","))

  local tmp = LAYOUT_FILE .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return end
  f:write(json)
  f:close()
  if os.rename(tmp, LAYOUT_FILE) then hl.exec_cmd("omarchy-shell -q io.github.hugorolimf.arrange showFile " .. quote(LAYOUT_FILE)) end
end

function windowing_arrange()
  local m = hl.get_monitor_at_cursor()
  if not m or not m.active_workspace or not LAYOUT_FILE then return end
  local wsid = m.active_workspace.id
  local all, list = windows_on(wsid, nil, m.name), {}
  for i = 1, #all do
    if not is_dialog(all[i]) then list[#list + 1] = all[i] end
  end
  -- Super + A again while the panel is up keeps what was left out
  local p = picker
  show_picker(m, wsid, list, p and p.wsid == wsid and p.monitor == m.name and p.out or {}, false)
end
local ARRANGE_KEY = W.settings.KEYS.arrange
if ARRANGE_KEY then hl.unbind(ARRANGE_KEY) hl.bind(ARRANGE_KEY, windowing_arrange, { description = "Arrange windows: pick a layout (1-9, Enter; 0 undoes)" }) end

-- The panel's answer: model k (1-based) of that session.
function windowing_layout_pick(session, k)
  local p = picker
  if not p or p.session ~= session or not p.models[k] then return end
  picker = nil
  local md, list, spots = p.models[k], {}, {}
  for i = 1, #p.list do
    local w = find_window(p.list[i])
    if w and w.workspace and w.workspace.id == p.wsid then
      list[#list + 1] = w
      spots[#list] = md.spots[md.order[i]]
    end
  end
  apply_spots(list, spots, md.max, md.id, p.wsid, "layout")
  W.count_pick(p.monitor .. " " .. #p.list .. " " .. md.id)
end

-- The panel's right click on a window: leaves it out of the arrangement
-- (it stays where it is), or puts it back; the models are worked out again
-- for the others. The last window can't be left out.
function windowing_layout_exclude(session, address)
  local p = picker
  if not p or p.session ~= session then return end
  local m = W.monitor_named(p.monitor)
  if not m then return end
  local out = {}
  for a in pairs(p.out) do out[a] = true end
  out[address] = not out[address] or nil
  local all = {}
  for i = 1, #p.all do
    local w = find_window(p.all[i])
    if w and w.workspace and w.workspace.id == p.wsid then all[#all + 1] = w end
  end
  show_picker(m, p.wsid, all, out, true)
end

-- Back to how the windows were before the last arrangement.
function windowing_layout_undo(session)
  local p = picker
  if not p or p.session ~= session then return end
  picker = nil
  local prev = arranged[p.wsid]
  if not prev then return end
  arranged[p.wsid] = nil
  for address, f in pairs(prev.before) do
    local w = find_window(address)
    if w then
      W.forget(address)
      place(w, f.x, f.y, f.w, f.h, "layout-undo")
    end
  end
end

function windowing_layout_cancel(session)
  if picker and (session == nil or picker.session == session) then picker = nil end
end

-- Tests: hyprctl eval 'windowing_layout_test(7, "columns")' arranges the
-- windows of workspace 7 (on the monitor under the cursor) with that model,
-- without the panel.
function windowing_layout_test(wsid, id)
  local m = hl.get_monitor_at_cursor()
  if not m then return end
  local all, list = windows_on(wsid, nil, m.name), {}
  for i = 1, #all do
    if not is_dialog(all[i]) then list[#list + 1] = all[i] end
  end
  if #list == 0 then return end
  local mi = W.main_window(list)
  local models = W.plan(m, list, mi)
  for k = 1, #models do
    local md = models[k]
    if md.id == id then
      local spots = {}
      for i = 1, #list do spots[i] = md.spots[md.order[i]] end
      apply_spots(list, spots, false, md.id, wsid, "test")
    end
  end
end
