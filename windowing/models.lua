-- The models Super + A offers (see picker.lua), as cells in fractions of
-- the work area, and how they turn into window frames.

local W = require("windowing.core")
local GAP = W.GAP

W.SPOT_W, W.SPOT_H = 360, 230   -- usable room for a window in a model

-- A model is a list of cells in fractions of the work area.
local function cell(x, y, w, h) return { x = x, y = y, w = w, h = h } end
W.cell = cell

-- k cells over x, y, w, h in cols columns; the last row may be short: its
-- cells widen. Appended to out.
local function grid_cells(k, cols, x, y, w, h, out)
  out = out or {}
  local rows = math.ceil(k / cols)
  for r = 0, rows - 1 do
    local in_row = math.min(cols, k - r * cols)
    for c = 0, in_row - 1 do
      out[#out + 1] = cell(x + c * w / in_row, y + r * h / rows, w / in_row, h / rows)
    end
  end
  return out
end

-- k full-height columns, equal unless widths are given.
local function columns(k, widths)
  local out, x = {}, 0
  for i = 1, k do
    local cw = widths and widths[i] or 1 / k
    out[i] = cell(x, 0, cw, 1)
    x = x + cw
  end
  return out
end

-- The main window in a column mw wide on the left, k more beside it.
local function main_and(mw, k, cols)
  return grid_cells(k, cols or 1, mw, 0, 1 - mw, 1, { cell(0, 0, mw, 1) })
end

-- The main window across the top (mh high), k more side by side below it.
local function main_top(mh, k)
  return grid_cells(k, k, 0, mh, 1, 1 - mh, { cell(0, 0, 1, mh) })
end

-- The main window in the middle (mw wide), l stacked on its left, r on its right.
local function centre(mw, l, r)
  local sw = (1 - mw) / 2
  local out = grid_cells(l, 1, 0, 0, sw, 1, { cell(sw, 0, mw, 1) })
  return grid_cells(r, 1, sw + mw, 0, sw, 1, out)
end

local function two_rows(top, bottom)
  return grid_cells(bottom, bottom, 0, 0.5, 1, 0.5, grid_cells(top, top, 0, 0, 1, 0.5))
end

-- Columns for k cells over w x h whose cells come closest to 3:2.
local function grid_cols(k, w, h)
  local best, best_d = 1, math.huge
  for cols = 1, k do
    local d = math.abs(math.log((w / cols) / (h / math.ceil(k / cols)) / 1.5))
    if d < best_d then best, best_d = cols, d end
  end
  return best
end

-- The models for n windows, in the order of their number keys. main: the
-- first cell is the main spot.
function W.catalog(n, aw, ah)
  local list = {}
  local function add(id, name, note, cells, main)
    list[#list + 1] = { id = id, name = name, note = note, cells = cells, main = main }
  end
  if n == 1 then
    add("full", "Tela toda", "MAXIMIZA", { cell(0, 0, 1, 1) })
    add("centre", "Centro", "64% NO MEIO", { cell(0.18, 0, 0.64, 1) })
  elseif n == 2 then
    add("halves", "Lado a lado", "50 · 50", columns(2))
    add("main", "Principal", "62 · 38", columns(2, { 0.62, 0.38 }), true)
    add("rows", "Em cima e embaixo", "50 / 50", grid_cells(2, 1, 0, 0, 1, 1))
  elseif n == 3 then
    add("columns", "Três colunas", "33 · 33 · 33", columns(3))
    add("main", "Principal + 2", "50 · 2 EMPILHADAS", main_and(0.5, 2), true)
    add("centre", "Centro largo", "25 · 50 · 25", centre(0.5, 1, 1), true)
    add("main-top", "Principal em cima", "60 / 2 EMBAIXO", main_top(0.6, 2), true)
  elseif n == 4 then
    add("grid", "Grade", "2 × 2", grid_cells(4, 2, 0, 0, 1, 1))
    add("columns", "Quatro colunas", "25 CADA", columns(4))
    add("main", "Principal + 3", "50 · 3 EMPILHADAS", main_and(0.5, 3), true)
    add("centre", "Centro largo", "1 · CENTRO · 2", centre(0.5, 1, 2), true)
    add("main-top", "Principal em cima", "60 / 3 EMBAIXO", main_top(0.6, 3), true)
  elseif n == 5 then
    add("rows", "Três e duas", "3 / 2", two_rows(3, 2))
    add("main", "Principal + grade", "50 · 2 × 2", main_and(0.5, 4, 2), true)
    add("centre", "Centro largo", "2 · CENTRO · 2", centre(0.44, 2, 2), true)
    add("columns", "Cinco colunas", "20 CADA", columns(5))
  elseif n == 6 then
    add("grid", "Grade", "3 × 2", grid_cells(6, 3, 0, 0, 1, 1))
    add("main", "Principal + grade", "40 · 3 + 2", main_and(0.4, 5, 3), true)
    add("centre", "Centro largo", "2 · CENTRO · 3", centre(0.4, 2, 3), true)
    add("columns", "Seis colunas", "1/6 CADA", columns(6))
  else
    local cols = grid_cols(n, aw, ah)
    add("grid", "Grade", cols .. " × " .. math.ceil(n / cols), grid_cells(n, cols, 0, 0, 1, 1))
    local w = 0.4
    add("main", "Principal + grade", "40 · " .. (n - 1), main_and(w, n - 1, grid_cols(n - 1, aw * (1 - w), ah)), true)
    local top = math.ceil(n / 2)
    add("rows", "Duas fileiras", top .. " / " .. (n - top), two_rows(top, n - top))
  end
  return list
end

-- Cells to frames on a work area (optionally mirrored left to right): GAP
-- from the area's border and between cells.
function W.frames_of(cells, ax, ay, aw, ah, mirrored)
  local out, e = {}, 0.001
  for i = 1, #cells do
    local c = cells[i]
    local cx = mirrored and 1 - c.x - c.w or c.x
    local l = cx < e and GAP or GAP / 2
    local t = c.y < e and GAP or GAP / 2
    local r = cx + c.w > 1 - e and GAP or GAP / 2
    local b = c.y + c.h > 1 - e and GAP or GAP / 2
    local x0, y0 = math.floor(ax + cx * aw + l + 0.5), math.floor(ay + c.y * ah + t + 0.5)
    out[i] = { x = x0, y = y0,
      w = math.floor(ax + (cx + c.w) * aw - r + 0.5) - x0,
      h = math.floor(ay + (c.y + c.h) * ah - b + 0.5) - y0 }
  end
  return out
end
