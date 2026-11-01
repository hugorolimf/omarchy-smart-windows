-- Smart Windows settings. An update keeps this file. Run `hyprctl reload` after a change.
return {
  ZONE = 36,      -- px from a monitor border where letting go snaps
  SHARED = 4,     -- the same, on a border shared with another monitor
  CORNER = 0.22,  -- share of a side, next to a corner, that snaps a quarter
  GAP = 8,        -- space between snapped windows and the screen border
  MIN_W = 160, MIN_H = 100,  -- smallest size a window is arranged to
  MINIMIZE_MS = 230,         -- length of the slide into the dock on minimize
  LOG_MOVES = false,         -- log every move to ~/.local/state/omarchy/windowing.log

  -- Keys. Set one to false to leave that key alone.
  -- Super + W (close the window) is Omarchy's own and stays as it is.
  KEYS = {
    quit = "SUPER + Q",      -- close the window, and the app with its last window
    minimize = "SUPER + M",  -- minimize the active window
    arrange = "SUPER + A",   -- arrange the screen's windows
    arrange_click = true,    -- Super + right click without dragging does the same
    maximize = false,        -- maximize / restore the active window, e.g. "SUPER + CTRL + M"
    swap = true,             -- Super + Shift + arrows: trade places with a neighbour
  },

  -- Optional: pin workspaces to monitors, so switching on one screen never empties
  -- the other. The first workspace of a range is that monitor's default. Names come
  -- from `hyprctl monitors`; a rule for a monitor that isn't plugged in is ignored.
  --   MONITOR_WORKSPACES = { ["DP-1"] = { 1, 5 }, ["eDP-1"] = { 6, 10 } },
  MONITOR_WORKSPACES = {},
}
