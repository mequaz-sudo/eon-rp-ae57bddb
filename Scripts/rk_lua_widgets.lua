-- ReaKit Lua Widgets — Shared ImGui UI Components
-- (c) EON Studios — All Rights Reserved
--
-- Theme system, waveform display, pad grid, and reusable UI widgets
-- for all EON ImGui-based scripts.
--
-- Usage:
--   local core    = dofile(script_dir .. sep .. "rk_lua_core.lua")
--   local widgets = dofile(script_dir .. sep .. "rk_lua_widgets.lua")
--   widgets.init(ImGui, core)

local w = {}
local ImGui, core  -- set by init()

function w.init(_ImGui, _core)
  ImGui = _ImGui
  core  = _core
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- NAMED COLORS
-- ═══════════════════════════════════════════════════════════════════════════════

w.colors = {
  accent         = 0xFF8C32FF,
  accent_fill    = 0x40C8FFBB,
  accent_edge    = 0x40C8FFDD,
  -- TK Media Browser-matched waveform color: deeper saturated blue at
  -- full opacity. Avoids the soft "bleed-through" look our older cyan
  -- @ 0xBB alpha had vs TK's solid waveform render.
  waveform_blue  = 0x32A0E1FF,
  swing_red      = 0xD9331DFF,
  text_gold      = 0xFFCC44FF,
  status_ok      = 0x50C878FF,
  status_err     = 0xCC4444FF,
  text_info      = 0xBBBBC0FF,
  text_dim       = 0x8C8C96FF,
  text_muted     = 0x6C6C76FF,
  pad_empty      = 0x38383FFF,
  border_default = 0x414148FF,
  white          = 0xFFFFFFFF,
  position_line  = 0xFFFFFFFF,
}

-- ═══════════════════════════════════════════════════════════════════════════════
-- THEME
-- ═══════════════════════════════════════════════════════════════════════════════

local THEME_COLOR_COUNT = 27
local THEME_VAR_COUNT   = 5

function w.push_theme(ctx, theme)
  local is_light = theme == "light"

  if is_light then
    ImGui.PushStyleColor(ctx, ImGui.Col_WindowBg,         0xF0F0F2FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg,          0xF0F0F2FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_PopupBg,          0xE8E8ECFF)
    ImGui.PushStyleColor(ctx, ImGui.Col_Border,           0xC0C0C8FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg,          0xE0E0E5FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgHovered,   0xD0D0D8FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgActive,    0xC0C0CCFF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TitleBg,          0xDCDCE2FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TitleBgActive,    0xD0D0D8FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_Header,           0xD8D8E0FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_HeaderHovered,    0xC8C8D4FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_HeaderActive,     0xB8B8C8FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_Button,           0xD5D5DCFF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered,    0xC5C5D0FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,     0xFF8C32FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text,             0x222228FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TextDisabled,     0x888890FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ScrollbarBg,      0xE8E8ECFF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ScrollbarGrab,    0xB8B8C0FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ScrollbarGrabHovered, 0xA0A0AAFF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ScrollbarGrabActive,  0xFF8C32FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TableHeaderBg,    0xDCDCE2FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TableBorderStrong, 0xC0C0C8FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TableBorderLight,  0xD0D0D8FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TableRowBg,        0xF0F0F2FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TableRowBgAlt,     0xE8E8ECFF)
    ImGui.PushStyleColor(ctx, ImGui.Col_Separator,         0xC0C0C8FF)
  else
    ImGui.PushStyleColor(ctx, ImGui.Col_WindowBg,         0x1E1E22FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg,          0x1E1E22FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_PopupBg,          0x2A2A30FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_Border,           0x414148FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg,          0x2A2A30FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgHovered,   0x3A3A42FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgActive,    0x4A4A55FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TitleBg,          0x1A1A1EFF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TitleBgActive,    0x28282FFF)
    ImGui.PushStyleColor(ctx, ImGui.Col_Header,           0x3C3C45FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_HeaderHovered,    0x4C4C58FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_HeaderActive,     0x5C5C6AFF)
    ImGui.PushStyleColor(ctx, ImGui.Col_Button,           0x3A3A42FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered,    0x4F4F5AFF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,     0xFF8C32FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text,             0xDDDDE0FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TextDisabled,     0x8C8C96FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ScrollbarBg,      0x1E1E22FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ScrollbarGrab,    0x4A4A55FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ScrollbarGrabHovered, 0x5A5A68FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ScrollbarGrabActive,  0xFF8C32FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TableHeaderBg,    0x28282FFF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TableBorderStrong, 0x414148FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TableBorderLight,  0x333338FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TableRowBg,        0x1E1E22FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TableRowBgAlt,     0x232328FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_Separator,         0x414148FF)
  end

  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowRounding,  4)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameRounding,   3)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding,   8, 8)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing,     6, 4)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ScrollbarSize,   12)
end

function w.pop_theme(ctx)
  ImGui.PopStyleColor(ctx, THEME_COLOR_COUNT)
  ImGui.PopStyleVar(ctx, THEME_VAR_COUNT)
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- WAVEFORM DISPLAY
-- ═══════════════════════════════════════════════════════════════════════════════

--- Draw a waveform from peak data.
--- @param ctx    ImGui context
--- @param x      number  screen X
--- @param y      number  screen Y
--- @param width  number  pixel width
--- @param height number  pixel height
--- @param peaks  table   array of {min, max} pairs (or empty)
--- @param playback_ratio number|nil  0-1 playback position (nil = no line)
-- TK Media Browser spectral colormap. Input s in 0..1 returns packed
-- u32 RGBA. Reproduces TK's exact gradient (zcr_value branches at
-- 0.25 / 0.50 / 0.75 — see TK_MEDIA_BROWSER(SA).lua:10511).
--   0.00..0.25  red     (255, 51..170,  0)         — sub-bass
--   0.25..0.50  orange  (255..51, 170..204, 0..51) — bass
--   0.50..0.75  green   (51, 204..153, 51..255)    — mids
--   0.75..1.00  blue    (51..170, 153..51, 255)    — highs/cymbals
local function tk_spectral_color(s)
  s = math.max(0, math.min(1, s or 0.5))
  local R, G, B
  if s < 0.25 then
    local t = s / 0.25
    R = 255
    G = 51 + 119 * t
    B = 0
  elseif s < 0.50 then
    local t = (s - 0.25) / 0.25
    R = 255 - 204 * t
    G = 170 + 34 * t
    B = 0 + 51 * t
  elseif s < 0.75 then
    local t = (s - 0.50) / 0.25
    R = 51
    G = 204 - 51 * t
    B = 51 + 204 * t
  else
    local t = (s - 0.75) / 0.25
    R = 51 + 119 * t
    G = 153 - 102 * t
    B = 255
  end
  return math.floor(R + 0.5) * 0x1000000
       + math.floor(G + 0.5) * 0x10000
       + math.floor(B + 0.5) * 0x100
       + 0xFF
end

function w.draw_waveform(ctx, x, y, width, height, peaks, playback_ratio, opts)
  opts = opts or {}
  local spectral     = opts.spectral
  local grid_overlay = opts.grid_overlay
  local draw_list = ImGui.GetWindowDrawList(ctx)

  -- Background
  ImGui.DrawList_AddRectFilled(draw_list, x, y, x + width, y + height, 0x2A2A30FF)

  -- Detect stereo entries (4-tuple {mnL, mxL, mnR, mxR}) vs mono (2-tuple
  -- {mn, mx}). Stereo renders top half = L, bottom half = R as two
  -- separate waveforms (Tukan-style); mono renders classic single
  -- centered waveform.
  local peak_count = peaks and #peaks or 0
  local is_stereo  = peak_count > 0 and peaks[1] and #peaks[1] >= 4

  -- Centerline(s)
  if is_stereo then
    local mid_top = y + height * 0.25
    local mid_bot = y + height * 0.75
    ImGui.DrawList_AddLine(draw_list, x, mid_top, x + width, mid_top, 0x3A3A42FF)
    ImGui.DrawList_AddLine(draw_list, x, mid_bot, x + width, mid_bot, 0x3A3A42FF)
    -- Subtle horizontal divider between L and R
    local mid_y = y + height * 0.5
    ImGui.DrawList_AddLine(draw_list, x, mid_y, x + width, mid_y, 0x44444AFF)
  else
    local mid_y = y + height * 0.5
    ImGui.DrawList_AddLine(draw_list, x, mid_y, x + width, mid_y, 0x3A3A42FF)
  end

  if peak_count > 0 and width > 0 then
    local step = peak_count / width
    local default_col = w.colors.waveform_blue
    local line_thick  = 1.5  -- match TK's default waveform_thickness
    local spectral_n  = spectral and #spectral or 0
    local spec_step   = spectral_n > 0 and (spectral_n / width) or 0
    -- Window aggregation: when we have more peaks than pixels (TK-style
    -- high peakrate), take max-of-window per pixel so high-frequency
    -- detail isn't lost. When peaks ≈ pixels, behaves like the prior
    -- 1-peak-per-pixel render.
    local win = math.max(1, math.floor(step))

    -- Render uses absolute peak amplitude rendered SYMMETRICALLY around
    -- each centerline (matching TK / Sitala / Battery convention). This
    -- means the line always spans both halves of its lane regardless of
    -- whether the audio content is bipolar, all-positive, all-negative,
    -- or DC-offset. Eliminates the "top-half-only" render that happens
    -- when REAPER's min/max for a window are both same-sign.
    if is_stereo then
      -- Stereo: two separate waveforms, each centered in its half
      local mid_top  = y + height * 0.25
      local mid_bot  = y + height * 0.75
      local half_sc  = height * 0.20
      for px = 0, math.floor(width) - 1 do
        local i0 = math.floor(px * step) + 1
        local i1 = math.min(peak_count, i0 + win - 1)
        local ampL, ampR = 0, 0
        for ii = i0, i1 do
          local pk = peaks[ii]
          if pk then
            local aL = math.max(math.abs(pk[1]), math.abs(pk[2]))
            local aR = math.max(math.abs(pk[3]), math.abs(pk[4]))
            if aL > ampL then ampL = aL end
            if aR > ampR then ampR = aR end
          end
        end
        local col = default_col
        if spec_step > 0 then
          local si = math.min(spectral_n, math.floor(px * spec_step) + 1)
          col = tk_spectral_color(spectral[si] or 0.5)
        end
        local yL = ampL * half_sc
        if yL < 0.5 then yL = 0.5 end
        ImGui.DrawList_AddLine(draw_list, x + px + 0.5, mid_top - yL, x + px + 0.5, mid_top + yL, col, line_thick)
        local yR = ampR * half_sc
        if yR < 0.5 then yR = 0.5 end
        ImGui.DrawList_AddLine(draw_list, x + px + 0.5, mid_bot - yR, x + px + 0.5, mid_bot + yR, col, line_thick)
      end
    else
      -- Mono: single waveform centered on mid_y
      local mid_y = y + height * 0.5
      local scale = height * 0.45
      for px = 0, math.floor(width) - 1 do
        local i0 = math.floor(px * step) + 1
        local i1 = math.min(peak_count, i0 + win - 1)
        local amp = 0
        for ii = i0, i1 do
          local pk = peaks[ii]
          if pk then
            local a = math.max(math.abs(pk[1]), math.abs(pk[2]))
            if a > amp then amp = a end
          end
        end
        local col = default_col
        if spec_step > 0 then
          local si = math.min(spectral_n, math.floor(px * spec_step) + 1)
          col = tk_spectral_color(spectral[si] or 0.5)
        end
        local yh = amp * scale
        if yh < 0.5 then yh = 0.5 end
        ImGui.DrawList_AddLine(draw_list, x + px + 0.5, mid_y - yh, x + px + 0.5, mid_y + yh, col, line_thick)
      end
    end
  end

  -- TK-style proportional time-grid overlay (vertical ticks every
  -- ~80px, plus 4 sub-ticks per main interval; main alpha 0.27, sub
  -- alpha 0.13). Drawn over the waveform when grid_overlay is true.
  -- Time labels at each main tick when src_length is provided.
  if grid_overlay then
    local main_count = math.max(4, math.floor(width / 80))
    local main_col = 0xFFFFFF44  -- white @ ~0.27 alpha
    local sub_col  = 0xFFFFFF22  -- white @ ~0.13 alpha
    local label_col = 0xFFFFFF88
    local src_len = opts.src_length or 0
    for i = 0, main_count do
      local mx = x + (i / main_count) * width
      ImGui.DrawList_AddLine(draw_list, mx, y, mx, y + height, main_col, 1)
      if src_len > 0 and i < main_count then
        -- Format: m:ss:ms (TK style — see screenshot 0:00:015)
        local t = (i / main_count) * src_len
        local mins = math.floor(t / 60)
        local secs = math.floor(t) % 60
        local ms   = math.floor((t * 1000) % 1000)
        local label = string.format("%d:%02d:%03d", mins, secs, ms)
        ImGui.DrawList_AddText(draw_list, mx + 2, y + 2, label_col, label)
      end
    end
    for i = 0, main_count - 1 do
      local sx0 = x + (i       * width) / main_count
      local sx1 = x + ((i + 1) * width) / main_count
      local interval = sx1 - sx0
      for j = 1, 4 do
        local sx = sx0 + (j * interval / 5)
        ImGui.DrawList_AddLine(draw_list, sx, y, sx, y + height, sub_col, 1)
      end
    end
  end

  -- Playback position line
  if playback_ratio and playback_ratio > 0 then
    local px = x + playback_ratio * width
    ImGui.DrawList_AddLine(draw_list, px, y, px, y + height, w.colors.position_line)
  end

  -- Border
  ImGui.DrawList_AddRect(draw_list, x, y, x + width, y + height, w.colors.border_default)
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- PAD GRID
-- ═══════════════════════════════════════════════════════════════════════════════

--- Draw a 4x4 pad grid.
--- @param ctx  ImGui context
--- @param opts table with fields:
---   target_pad       number   0-15, currently selected pad
---   on_pad_click     function(pad_idx)  called on click
---   on_pad_drop      function(pad_idx, payload)  called on drag-drop accept
---   read_pad_name    function(pad_idx) -> string
---   pad_has_audio    function(pad_idx) -> bool
---   get_pad_color    function(pad_idx) -> uint32 RGBA
---   get_folder_name  function(path) -> string  (for tooltip)
function w.draw_pad_grid(ctx, opts)
  local avail_w = ImGui.GetContentRegionAvail(ctx)
  local spacing = 4
  local pad_w = math.floor((avail_w - 3 * spacing) / 4)
  local pad_h = pad_w

  for row = 0, 3 do
    for col = 0, 3 do
      local p = (3 - row) * 4 + col
      if col > 0 then ImGui.SameLine(ctx, nil, spacing) end

      local has_audio = opts.pad_has_audio(p)
      local name = opts.read_pad_name(p)
      local is_target = (p == opts.target_pad)
      local is_muted = opts.is_pad_muted and opts.is_pad_muted(p) or false

      -- Color — mirror the JSFX GUI's pad-face math exactly so the browser
      -- looks the same as the plugin face:
      --   loaded, not muted: pr * 0.75 + 0.12  (matte mix toward off-white)
      --   loaded, muted:     pr * 0.35 + 0.15  (deeper desaturation)
      --   empty:             pad_empty (dark gray)
      local col_val
      if has_audio then
        col_val = opts.get_pad_color(p)
        local r = (col_val >> 24) & 0xFF
        local g = (col_val >> 16) & 0xFF
        local b = (col_val >>  8) & 0xFF
        local a =  col_val        & 0xFF
        if is_muted then
          local mix = math.floor(0.15 * 255)
          r = math.floor(r * 0.35) + mix
          g = math.floor(g * 0.35) + mix
          b = math.floor(b * 0.35) + mix
        else
          local mix = math.floor(0.12 * 255)
          r = math.floor(r * 0.75) + mix
          g = math.floor(g * 0.75) + mix
          b = math.floor(b * 0.75) + mix
        end
        col_val = (r << 24) | (g << 16) | (b << 8) | a
      else
        col_val = w.colors.pad_empty
      end

      -- Selected: orange border
      if is_target then
        ImGui.PushStyleColor(ctx, ImGui.Col_Border, w.colors.accent)
        ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameBorderSize, 3.0)
      end

      ImGui.PushStyleColor(ctx, ImGui.Col_Button, col_val)
      ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, col_val + 0x1A1A1A00)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x000000FF)

      -- Label
      -- Show the pad name whether or not the pad has audio loaded.
      -- Previously gated on `has_audio` — meaning renaming an empty pad
      -- in the JSFX would update gmem and the JSFX grid, but the browser
      -- pad button would silently keep showing just the pad number.
      -- Visually identical to "rename didn't propagate."
      -- Now: name displays as soon as it's set. Empty pads stay dark gray
      -- (color block above keeps its has_audio gate) but the name shows
      -- in dim text so the user can see they reserved the slot.
      local pad_label
      if name ~= "" then
        local short = #name > 6 and name:sub(1, 6) or name
        pad_label = tostring(p + 1) .. "\n" .. short .. "##pad" .. p
      else
        pad_label = tostring(p + 1) .. "##pad" .. p
      end

      if ImGui.Button(ctx, pad_label, pad_w, pad_h) then
        if opts.on_pad_click then opts.on_pad_click(p) end
      end
      -- Tooltip on hover shows the full pad name. The button label is
      -- truncated to 6 chars to fit the cell; users can see the full
      -- name (e.g. "808_kick_punchy" instead of "808_ki") by hovering.
      if name ~= "" and ImGui.IsItemHovered(ctx) then
        ImGui.SetTooltip(ctx, name)
      end
      ImGui.PopStyleColor(ctx, 3)

      if is_target then
        ImGui.PopStyleVar(ctx)
        ImGui.PopStyleColor(ctx)
      end

      -- Drop target (accepts single file or multi-select)
      if opts.on_pad_drop then
        if ImGui.BeginDragDropTarget(ctx) then
          -- Try multi-file payload first, then single-file
          local rv, payload = ImGui.AcceptDragDropPayload(ctx, "SWING_MULTI")
          if rv and payload then
            opts.on_pad_drop(p, payload, "SWING_MULTI")
          else
            rv, payload = ImGui.AcceptDragDropPayload(ctx, "SWING_FILE")
            if rv and payload then
              opts.on_pad_drop(p, payload, "SWING_FILE")
            end
          end
          ImGui.EndDragDropTarget(ctx)
        end
      end

      -- Right-click context menu. The widget owns the popup lifecycle
      -- (BeginPopup/EndPopup) so positioning + click-to-open work
      -- correctly; the caller's on_pad_right_click renders menu items.
      if opts.on_pad_right_click then
        local popup_id = "##pad_ctx_" .. p
        ImGui.OpenPopupOnItemClick(ctx, popup_id, ImGui.MouseButton_Right)
        if ImGui.BeginPopup(ctx, popup_id) then
          opts.on_pad_right_click(ctx, p)
          ImGui.EndPopup(ctx)
        end
      end

      -- Tooltip
      if ImGui.IsItemHovered(ctx) then
        local tip = "Pad " .. (p + 1)
        if has_audio and name ~= "" then
          tip = tip .. ": " .. name
        else
          tip = tip .. ": (empty)"
        end
        ImGui.SetTooltip(ctx, tip)
      end
    end
  end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- BUTTON HELPERS
-- ═══════════════════════════════════════════════════════════════════════════════

--- Button that can be disabled. Returns true if clicked (and was enabled).
function w.button(ctx, label, width, height, enabled)
  if enabled == false then ImGui.BeginDisabled(ctx) end
  local clicked = ImGui.Button(ctx, label, width or 0, height or 0)
  if enabled == false then ImGui.EndDisabled(ctx) end
  return clicked
end

--- Button with a custom background color. Returns true if clicked.
function w.colored_button(ctx, label, color, width, height)
  ImGui.PushStyleColor(ctx, ImGui.Col_Button, color)
  local clicked = ImGui.Button(ctx, label, width or 0, height or 0)
  ImGui.PopStyleColor(ctx)
  return clicked
end

return w
