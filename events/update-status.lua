---@diagnostic disable: undefined-field
---
---@module "events.update-status"
---@author sravioli
---@license GNU-GPLv3

-- selene: allow(incorrect_standard_library_use)
local tunpack, tinsert = table.unpack or unpack, table.insert
local tostring, tonumber = tostring, tonumber
local floor = math.floor

local wt = require "wezterm"
local timefmt, color_parse = wt.strftime, wt.color.parse

local class, fn = require "utils.class", require "utils.fn"
local icon, sep, sb = class.icon, class.icon.Sep, class.layout:new "StatusBar"
local fs, mt, str, tbl = fn.fs, fn.mt, fn.str, fn.tbl

---@class UpdateStatusEvent
local e = {}

---Agent CLIs (Claude Code, Codex) animate their pane title several times a second, and
---every title change in any tab emits `update-status` on wezterm's GUI thread. Anything
---slow in here therefore runs at that rate, so the expensive inputs are cached. The
---caches live in this lua state, which wezterm replaces on every config reload.
local cache = { config = {}, battery = { at = -math.huge }, best_fit = {}, pane = {} }

---seconds between `wezterm.battery_info()` calls, which enumerate devices on Windows
local BATTERY_TTL = 60

---seconds to reuse per-pane values that come from `pane:get_current_working_dir()` and
---`pane:get_foreground_process_name()`. Both bypass wezterm's process info cache and, on
---Windows, snapshot every process and read the pane's process tree (~20ms per call).
local PANE_TTL = 1

-- {{{1 e.__per_pane(pane, what, compute)

---Returns `compute()` for `pane`, reusing the previous result for `PANE_TTL` seconds.
---
---@param pane wt.Pane Wezterm's pane object
---@param what string name of the cached value
---@param compute function produces the value
---@return any value
e.__per_pane = function(pane, what, compute)
  local now, key = os.time(), pane:pane_id() .. "\31" .. what
  local hit = cache.pane[key]
  if hit and now - hit.at < PANE_TTL then
    return hit.value
  end

  local value = compute()
  cache.pane[key] = { at = now, value = value }
  return value
end -- }}}

-- {{{1 e.__effective_config(window)

---Returns `window:effective_config()`, which marshals the whole config into lua, reusing
---the previous result while the window's config overrides are unchanged.
---
---@param window wt.Window Wezterm's window object
---@return table config effective config
---@return table overrides config overrides
e.__effective_config = function(window)
  local overrides = window:get_config_overrides() or {}
  local ok, key = pcall(wt.json_encode, overrides)
  local id = window:window_id()

  local hit = cache.config[id]
  if ok and hit and hit.key == key then
    return hit.config, overrides
  end

  local config = window:effective_config()
  cache.config[id] = ok and { key = key, config = config } or nil
  return config, overrides
end -- }}}

-- {{{1 e.__battery_info()

---Returns the first battery, refreshed at most every `BATTERY_TTL` seconds.
---
---@return table|nil battery
e.__battery_info = function()
  local now = os.time()
  if now - cache.battery.at >= BATTERY_TTL then
    cache.battery = { at = now, info = wt.battery_info()[1] }
  end
  return cache.battery.info
end -- }}}

-- {{{1 e.__get_modes()

---Retrieves a table of available modes, each represented by a set of properties.
---Each key corresponds to a mode, and the associated value is a table containing
---information about the mode's icon, text, background color, and padding.
---
---@return UpdateStatusEvent.Modes modes mode information.
e.__get_modes = function()
  ---@class UpdateStatusEvent.Modes
  ---
  ---Each mode has the following properties:
  ---* `i` (string): The icon for the mode (eg 󰍉).
  ---* `txt` (string): The label text for the mode (eg "SEARCH").
  ---* `bg` (string): The background color for the mode.
  ---* `pad` (number): The padding value for the mode.
  ---
  ---@field search_mode table "SEARCH" mode.
  ---@field window_mode table "WINDOW" mode.
  ---@field copy_mode table "COPY" mode.
  ---@field font_mode table "FONT" mode.
  ---@field help_mode table "NORMAL" mode.
  ---@field pick_mode table "PICK" mode.
  return {
    search_mode = { i = "󰍉", txt = "SEARCH", bg = e.theme.brights[4], pad = 5 },
    window_mode = { i = "󱂬", txt = "WINDOW", bg = e.theme.ansi[6], pad = 4 },
    copy_mode = { i = "󰆏", txt = "COPY", bg = e.theme.brights[3], pad = 5 },
    font_mode = { i = "󰛖", txt = "FONT", bg = e.theme.ansi[7], pad = 4 },
    help_mode = { i = "󰞋", txt = "NORMAL", bg = e.theme.ansi[5], pad = 5 },
    pick_mode = { i = "󰢷", txt = "PICK", bg = e.theme.ansi[2], pad = 5 },
  }
end -- }}}

-- {{{1 e.__get_width(Config, pane, window)

---Retrieves the width configuration for a given pane and window.
---The function calculates the usable width based on the pane's dimensions and the
---window's width, and returns a table with various width-related properties for use in
---the interface.
---
---@param Config table UI settings.
---@param pane wt.Pane Wezterm's pane object
---@param window wt.Window Wezterm's window object
---@return UpdateStatusEvent.Width width width-related properties.
e.__get_width = function(Config, pane, window)
  local pane_dimensions = pane:get_dimensions()
  local win_width = window:get_dimensions().pixel_width

  ---@class UpdateStatusEvent.Width
  ---@field ws number workspace (0).
  ---@field mode number mode section (0).
  ---@field tabs number tab section (5).
  ---@field prompt number prompt section (0).
  ---@field usable number usable width
  ---@field new_button number new tab button, (8 if present, otherwise 0)
  return {
    ws = 0,
    mode = 0,
    tabs = 5,
    prompt = 0,
    usable = math.floor((win_width * pane_dimensions.cols) / pane_dimensions.pixel_width),
    new_button = Config.show_new_tab_button_in_tab_bar and 8 or 0,
  }
end -- }}}

-- {{{1 e.__compute_combination_width(combination, sep_width, pad_width)

---Computes the total width of a combination of elements, accounting for separators and
---padding.  This function iterates over the elements in the given `combination`,
---calculates the width of each element, and adds the width of separators and padding
---between the elements.
---
---@param combination table elements whose widths are to be calculated.
---@param sep_width number width of the separator to be added between each element.
---@param pad_width number width of the padding to be added around each element.
---@return number width computed width of the combination, including separators and padding.
e.__compute_combination_width = function(combination, sep_width, pad_width)
  local total_width = 0
  for i = 1, #combination do
    total_width = total_width + str.width(combination[i]) + sep_width + pad_width
  end
  return total_width
end -- }}}

-- {{{1 e.__find_best_fit(combinations, max_width, sep_width, pad_width)

---Finds the combination that best fits within the specified maximum width.
---The function iterates over a list of combinations, calculates their total width, and
---selects the combination whose width is less than or equal to the specified `max_width`
---but as large as possible.
---
---@param combinations table multiple combinations of elements to evaluate.
---@param max_width number maximum allowable width for the combination.
---@param sep_width number width of the separator between elements in the combination.
---@param pad_width number padding width around each element in the combination.
---@return table best_fit best fitS within `max_width`, or am empty combination if none fit.
e.__find_best_fit = function(combinations, max_width, sep_width, pad_width)
  local best_fit = nil
  local best_fit_width = 0

  for i = 1, #combinations do
    local total_width =
      e.__compute_combination_width(combinations[i], sep_width, pad_width)
    if total_width <= max_width and total_width > best_fit_width then
      best_fit = combinations[i]
      best_fit_width = total_width
    end
  end

  return best_fit or { "", "", "", "" }
end -- }}}

-- {{{1 e.set_left_status(window)

---Updates and sets the left status bar for the given window.
---The function constructs the left status bar by checking the current mode and workspace,
---appending relevant information such as mode icon, text, workspace name, and width,
---then formats and sets it to the window's left status bar.
---
---@param window wt.Window Wezterm's window object
e.set_left_status = function(window)
  local lsb = sb:new "LeftStatusBar"

  e.mode = window:active_key_table()
  if e.mode and e.modes[e.mode] then
    local mode_fg = e.modes[e.mode].bg
    local txt, ico = e.modes[e.mode].txt or "", e.modes[e.mode].i or ""
    local indicator = str.pad(str.padr(ico) .. txt, 1)

    lsb:append(mode_fg, e.bg, indicator, { "Bold" })

    e.width.mode = str.width(indicator)
  end

  local ws = window:active_workspace()
  if ws ~= "" and not e.mode then
    local ws_bg = e.theme.brights[6]
    ws = str.pad(str.padr(icon.Workspace) .. ws)
    e.width.ws = str.width(ws) + 4

    if e.width.usable >= e.width.ws then
      lsb:append(ws_bg, e.bg, ws, { "Bold" })
    end
  end

  window:set_left_status(lsb:format())
end -- }}}

-- {{{1 e.set_modal_prompts(window)

---Constructs and sets the right status bar to display modal prompts for the given window.
---The function creates a series of prompts based on the current mode's key bindings
---and descriptions, adjusting the layout according to the available width. The status bar
---is then updated in the window.
---
---@param window wt.Window Wezterm's window object
e.set_modal_prompts = function(window)
  local rsb = sb:new "RightStatusBar"
  local prompt_bg, map_fg, txt_fg =
    e.theme.tab_bar.background, e.modes[e.mode].bg, e.theme.foreground
  local msep = sep.sb.modal

  local key_tbl = require("mappings.modes")[2][e.mode]
  for idx = 1, #key_tbl do
    local map, _, desc = tunpack(key_tbl[idx])

    if map:find "%b<>" then
      map = map:gsub("(%b<>)", function(s)
        return s:sub(2, -2)
      end)
    end

    e.width.prompt = str.width(map .. str.pad(desc)) + e.modes[e.mode].pad
    e.width.usable = e.width.usable - e.width.prompt
    if e.width.usable > 0 and desc ~= "" then
      rsb:append(prompt_bg, txt_fg, "<", { "Bold" })
      rsb:append(prompt_bg, map_fg, map)
      rsb:append(prompt_bg, txt_fg, ">")
      rsb:append(prompt_bg, txt_fg, str.pad(desc), { "Normal", "Italic" })

      local next_map, _, next_desc = tunpack(key_tbl[idx + 1] or { "", "", "" })
      local next_prompt_len = str.width(next_map .. str.pad(next_desc))
      if idx < #key_tbl and next_prompt_len < e.width.usable then
        rsb:append(prompt_bg, e.theme.brights[1], str.padr(msep, 1), { "NoItalic" })
      end
    end
  end

  window:set_right_status(rsb:format())
end -- }}}

-- {{{1 e.update_width(Config, window, pane)

---Updates the width calculations for the window and pane, factoring in various UI elements.
---The function computes the width of tabs, mode, new button, and workspace, then returns
---the remaining usable width.
---
---@param Config table The configuration settings used for formatting the tab titles.
---@param window wt.Window Wezterm's window object
---@param pane wt.Pane Wezterm's pane object
---@return number usable_width remaining usable width
e.update_width = function(Config, window, pane)
  ---every tab is measured with the active pane's title, so format it once
  local tab_width = e.__per_pane(pane, "tab_width", function()
    return str.width(str.format_tab_title(pane, pane:get_title(), Config, 25))
  end)
  e.width.tabs = e.width.tabs + tab_width * #window:mux_window():tabs()

  return e.width.usable - (e.width.tabs + e.width.mode + e.width.new_button + e.width.ws)
end -- }}}

-- {{{1 e.set_right_status(Config, window, pane)

---Updates and sets the right status bar for the given window.
---The function constructs the right status bar by gathering information on battery
---status, time, current working directory (cwd), and hostname, then formats and appends
---these pieces of information as cells to the status bar.
---The status bar is then updated in the window.
---
---@param Config table configuration settings
---@param window wt.Window Wezterm's window object
---@param pane wt.Pane Wezterm's pane object
e.set_right_status = function(Config, window, pane)
  local rsb = sb:new "RightStatusBar"

  e.fg = color_parse(tostring(e.fg))
  local palette = { e.fg:darken(0.15), e.fg, e.fg:lighten(0.15), e.fg:lighten(0.25) }
  local cwd, hostname = tunpack(e.__per_pane(pane, "cwd", function()
    return { fs.get_cwd_hostname(pane, true) }
  end))

  --~ {{{2: battery cells

  local battery = e.__battery_info()
  if battery then
    battery.charge_lvl = battery.state_of_charge * 100
    battery.charge_lvl_round = mt.toint(mt.mround(battery.charge_lvl, 10))
    battery.ico = icon.Bat[battery.state][tostring(battery.charge_lvl_round)]
    battery.lvl = tonumber(floor(battery.charge_lvl + 0.5)) .. "%"
    battery.full = ("%s %s"):format(battery.lvl, battery.ico)
    battery.cells = { battery.full, battery.lvl, battery.ico }
  end --~ }}}

  --~ {{{2: datime cells

  local time_ico = str.padl(icon.Clock[timefmt "%I"])
  local time_cells = {
    timefmt "%a %b %-d %I:%M %p" .. time_ico,
    timefmt "%d/%m %I:%M %p" .. time_ico,
    timefmt "%I:%M %p" .. time_ico,
    time_ico,
  } --~ }}}

  --~ {{{2: cwd cells
  local cwd_ico = str.padl(icon.Folder)
  local cwd_cells = {
    cwd .. cwd_ico,
    fs.pathshortener(cwd, 4) .. cwd_ico,
    fs.pathshortener(cwd, 2) .. cwd_ico,
    fs.pathshortener(cwd, 1) .. cwd_ico,
  } --~ }}}

  --~ {{{2: hostname cells
  local hostname_ico = str.padl(icon.Hostname)
  local hostname_cells =
    { hostname .. hostname_ico, hostname:sub(1, 1) .. hostname_ico, hostname_ico }
  --~ }}}

  local fancy_bg = Config.window_frame.active_titlebar_bg
  local last_fg = Config.use_fancy_tab_bar and fancy_bg or e.theme.tab_bar.background

  local sets = { cwd_cells, hostname_cells, time_cells }
  if battery then
    tinsert(sets, battery.cells)
  end

  ---the best fit only changes with the cell texts and the usable width; keep the latest
  local key = {}
  for i = 1, #sets do
    key[i] = table.concat(sets[i], "\31")
  end
  key = table.concat(key, "\30") .. "\30" .. e.width.usable

  local cells = cache.best_fit[key]
  if not cells then
    cells = tbl.reverse(
      e.__find_best_fit(tbl.cartesian(sets), e.width.usable, str.width(sep.sb.right), 5)
    )
    cache.best_fit = { [key] = cells }
  end

  -- Render the best fit, ensuring correct colors
  for i = 1, #cells do
    local cell_bg, cell_fg = palette[i], i == 1 and last_fg or palette[i - 1]
    local rsep = sep.sb.right

    rsb:append(cell_fg, cell_bg, rsep)
    rsb:append(cell_bg, e.theme.tab_bar.background, str.pad(cells[i]), { "Bold" })
  end

  window:set_right_status(rsb:format())
end -- }}}

---Update status event
---@param window wt.Window Wezterm's window object
---@param pane   wt.Pane   Wezterm's pane object
wt.on("update-status", function(window, pane)
  local Config, Overrides = e.__effective_config(window)
  e.theme = Config.color_schemes[Overrides.color_scheme or Config.color_scheme]
  e.bg, e.fg = e.theme.background, e.theme.ansi[5]

  e.modes = e.__get_modes()
  e.width = e.__get_width(Config, pane, window)

  e.set_left_status(window)

  e.width.usable = e.update_width(Config, window, pane)

  if e.mode and e.modes[e.mode] then
    e.set_modal_prompts(window)
    return -- return early to not render the status-bar
  end

  e.set_right_status(Config, window, pane)
end)

-- vim: fdm=marker fdl=1
