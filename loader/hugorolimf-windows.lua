-- Smart Windows (github.com/hugorolimf/omarchy-smart-windows): Windows-style window management.
-- Omarchy runs every .lua in this folder on each Hyprland reload. This only loads the module
-- while it is still installed, so removing it can never break the config.
-- Delete this file and run `hyprctl reload` to turn it off.
local f = (os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")) .. "/omarchy-smart-windows/windowing.lua"
local h = io.open(f, "r")
if h then h:close(); dofile(f) end
