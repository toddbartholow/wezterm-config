---@diagnostic disable: undefined-field

local wt = require "wezterm"
local fs = require("utils.fn").fs

local Config = {}

Config.adjust_window_size_when_changing_font_size = false
Config.allow_square_glyphs_to_overflow_width = "WhenFollowedBySpace"
Config.anti_alias_custom_block_glyphs = true

Config.font = wt.font_with_fallback {
  { family = "JetBrains Mono", weight = "Regular" },
  { family = "Symbols Nerd Font Mono" }, ---provides icon / powerline glyphs
}

if fs.platform().is_win then
  Config.font_size = 14
else
  Config.font_size = 10.5
end

Config.underline_position = -2.5
Config.underline_thickness = "2px"
Config.warn_about_missing_glyphs = false

-- No custom font_rules: WezTerm auto-derives bold / italic / bold-italic from
-- the base "JetBrains Mono" family above.

return Config
