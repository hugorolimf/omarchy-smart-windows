#!/usr/bin/env bash
# Installs Smart Windows for the current user. Your hyprland.lua is not edited:
# the module goes to ~/.config/omarchy-smart-windows/ and a one-line loader to
# Omarchy's toggles folder, which Hyprland reads on every reload.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
config="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy-smart-windows"
toggles="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/toggles/hypr"

if [ ! -f "${XDG_CONFIG_HOME:-$HOME/.config}/hypr/hyprland.lua" ]; then
  echo "No ~/.config/hypr/hyprland.lua found. Smart Windows needs Omarchy with Hyprland's Lua config." >&2
  exit 1
fi

mkdir -p "$config" "$toggles"

# An update keeps your old copy (and the settings you changed in it).
if [ -f "$config/windowing.lua" ] && ! cmp -s "$here/windowing.lua" "$config/windowing.lua"; then
  backup="$config/windowing.lua.bak.$(date +%s)"
  cp "$config/windowing.lua" "$backup"
  echo "Your previous windowing.lua was saved as $backup"
  echo "Copy your settings from its configuration block into the new one if you had changed any."
fi

install -m 644 "$here/windowing.lua" "$config/windowing.lua"
install -m 644 "$here/loader/hugorolimf-windows.lua" "$toggles/hugorolimf-windows.lua"

echo "Installed:"
echo "  $config/windowing.lua  (settings at the top)"
echo "  $toggles/hugorolimf-windows.lua  (loader)"

if [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] && command -v hyprctl >/dev/null; then
  hyprctl reload >/dev/null && echo "Hyprland reloaded. Drag a window to a screen edge to try it."
else
  echo "Run 'hyprctl reload' inside your Hyprland session to turn it on."
fi
