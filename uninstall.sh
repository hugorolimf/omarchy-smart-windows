#!/usr/bin/env bash
# Removes Smart Windows: the loader, the module (with your settings in it) and
# the state it keeps (per-app sizes, minimized windows, the optional log).
set -euo pipefail

config="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy-smart-windows"
state="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy"

rm -f "$state/toggles/hypr/hugorolimf-windows.lua"
rm -rf "$config"
rm -f "$state/windowing-geometry" "$state/windowing-minimized" "$state/windowing-layouts" "$state/windowing.log"
# An old list of maximized windows would keep a dock hidden on that screen.
for dock in io.github.hugorolimf.dock hugo.dock; do
  if [ -f "$state/$dock/maximized" ]; then : > "$state/$dock/maximized"; fi
done

echo "Smart Windows removed."
if [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] && command -v hyprctl >/dev/null; then
  hyprctl reload >/dev/null && echo "Hyprland reloaded. New windows tile again; open ones stay floating until you toggle them (Super + T) or log in again."
else
  echo "Run 'hyprctl reload' inside your Hyprland session."
fi
