-- Smart Windows: Windows-style window management for Omarchy (Hyprland Lua).
-- https://github.com/hugorolimf/omarchy-smart-windows · MIT © Hugo Rolim Filho
--
-- Every window floats. Drag a window and let go with the pointer near a screen
-- edge to snap it: the top edge maximizes, a side takes half, a corner a quarter.
--
-- The rule behind all of it: a window moves only because you moved it (drag, snap,
-- maximize, arrange, swap) or because it is itself opening or coming back. Opening,
-- closing, minimizing or restoring a window never moves the others, and a window
-- always returns to where and how big it was.
--
-- Super + A arranges the screen once: with Island Arrange installed it shows the
-- models to pick from; without it, the suggested model is applied right away.
--
-- Loaded by a one-line loader in ~/.local/state/omarchy/toggles/hypr/.
-- Settings are in windowing/settings.lua.

local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")
if here and not package.path:find(here .. "/?.lua", 1, true) then
  package.path = here .. "/?.lua;" .. package.path
end

o.window(".*", { float = true })
-- Omarchy tiles Chromium-based browsers (default/hypr/apps/browser.lua) and
-- that rule beats the one above: a tiled window sits under every floating one
-- and Super + A skips it. Browsers float like everything else.
o.window({ tag = "chromium-based-browser" }, { float = true })

local W = require("windowing.core")
require("windowing.minimize")
require("windowing.snap")
require("windowing.placement")
require("windowing.models")
require("windowing.plan")
require("windowing.swap")
require("windowing.picker")
require("windowing.workspaces")
require("windowing.dockdrop")

-- The float rule only reaches windows opened from now on. Windows that were
-- already tiled float too, keeping their place and size, so Super + right
-- drag can resize them freely (a tiled window filling the screen can't grow).
local function float_existing()
  -- Counted loop, not ipairs: see windows_on in windowing/core.lua.
  local windows = hl.get_windows() or {}
  for i = 1, #windows do
    local w = windows[i]
    if w.mapped and not w.floating and w.fullscreen == 0 then
      local x, y, width, height = w.at.x, w.at.y, w.size.x, w.size.y
      hl.dispatch(hl.dsp.window.float({ action = "enable", window = W.sel(w) }))
      W.place_raw(w, x, y, width, height)
    end
  end
end
pcall(float_existing)
hl.on("config.reloaded", function() pcall(float_existing) end)

-- Optional: workspaces pinned to monitors (settings.lua).
for monitor, range in pairs(W.settings.MONITOR_WORKSPACES) do
  for n = range[1], range[2] do
    hl.workspace_rule({ workspace = tostring(n), monitor = monitor, default = n == range[1] })
  end
end
