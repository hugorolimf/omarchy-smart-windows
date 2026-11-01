-- Two workspaces trade their windows (the dock: drag one workspace onto
-- another), so 2 dropped on 1 becomes the new 1. Every window keeps its place
-- and size, and a screen that showed one of the two keeps showing the same
-- windows, now under the other number.

local W = require("windowing.core")

function windowing_swap_workspaces(a, b)
  a, b = tonumber(a), tonumber(b)
  if not a or not b or a == b or a <= 0 or b <= 0 then return end
  local all, moves = hl.get_windows() or {}, {}
  for i = 1, #all do
    local w = all[i]
    local id = w.workspace and w.workspace.id
    if (id == a or id == b) and not w.pinned then
      moves[#moves + 1] = { address = w.address, to = id == a and b or a }
    end
  end
  local shown, ms = {}, hl.get_monitors() or {}
  for i = 1, #ms do
    local id = ms[i].active_workspace and ms[i].active_workspace.id
    if id == a or id == b then shown[#shown + 1] = id == a and b or a end
  end
  W.arranged[a], W.arranged[b] = W.arranged[b], W.arranged[a]
  for i = 1, #moves do
    hl.dispatch(hl.dsp.window.move({ workspace = tostring(moves[i].to), window = "address:" .. moves[i].address, follow = false }))
  end
  for i = 1, #shown do hl.dispatch(hl.dsp.focus({ workspace = tostring(shown[i]) })) end
end
